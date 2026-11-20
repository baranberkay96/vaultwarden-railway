#!/bin/bash
# Encrypted backups of Vaultwarden (Postgres database + /data volume) to a Railway Bucket.
#
#   railway-backup schedule         daily at BACKUP_TIME (UTC), plus once ~1 min after boot
#                                   when BACKUP_ON_START=true; never exits on errors
#   railway-backup run              one backup now (exit 1 on failure)
#   railway-backup restore-on-boot  one-shot restore before Vaultwarden starts, when
#                                   BACKUP_RESTORE_RUN and BACKUP_RESTORE_CONFIRM are set
#
# Bucket layout, one folder per run (UTC timestamp):
#   {BACKUP_PREFIX}/20261120T031500Z/vaultwarden.tar.gpg   tar of db.dump (pg_dump custom format)
#                                                          and data/ (the volume without icon_cache),
#                                                          encrypted with gpg (AES-256, passphrase
#                                                          BACKUP_ENCRYPTION_PASSPHRASE)
#   {BACKUP_PREFIX}/20261120T031500Z/MANIFEST.txt          written last; a run without it is incomplete
#
# Decrypt on any machine with GnuPG:  gpg -d vaultwarden.tar.gpg | tar -x
# Retention: complete runs older than BACKUP_RETENTION_DAYS are deleted, but the newest
# BACKUP_KEEP_MIN complete runs are always kept; incomplete runs older than 2 days are deleted.
set -Eeuo pipefail

PREFIX="${BACKUP_PREFIX:-vaultwarden}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
KEEP_MIN="${BACKUP_KEEP_MIN:-3}"
BACKUP_TIME="${BACKUP_TIME:-03:15}"
WAIT_SECONDS=600
MIN_PASSPHRASE=16
DATA_DIR=/data
OBJECT=vaultwarden.tar.gpg
RUN_RE='^[0-9]{8}T[0-9]{6}Z$'
RESTORE_MARKER="${DATA_DIR}/.railway-restored-run"
LOCK_DIR=/tmp/railway-backup.lock
REMOTE=""
WORK_DIR=""

log() { printf '[backup] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
cleanup() { if [ -n "${WORK_DIR}" ] && [ -d "${WORK_DIR}" ]; then rm -rf "${WORK_DIR}"; fi; }
trap cleanup EXIT

truthy() { case "${1,,}" in true|1|yes|on) return 0 ;; *) return 1 ;; esac; }

# Why backups cannot run, or nothing when they can.
disabled_reason() {
  local var
  truthy "${BACKUP_ENABLED:-true}" || { echo "BACKUP_ENABLED is not true"; return; }
  for var in BACKUP_S3_BUCKET BACKUP_S3_ENDPOINT BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY; do
    [ -n "${!var:-}" ] || { echo "${var} is empty (no Railway Bucket attached)"; return; }
  done
  [ -n "${DATABASE_URL:-}" ] || { echo "DATABASE_URL is empty"; return; }
  local passphrase="${BACKUP_ENCRYPTION_PASSPHRASE:-}"
  [ "${#passphrase}" -ge "${MIN_PASSPHRASE}" ] \
    || { echo "BACKUP_ENCRYPTION_PASSPHRASE is missing or shorter than ${MIN_PASSPHRASE} characters (backups are never written unencrypted)"; return; }
  [[ "${PREFIX}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] && [[ "/${PREFIX}/" != */./* ]] && [[ "/${PREFIX}/" != */../* ]] \
    || { echo "BACKUP_PREFIX must be a folder path of letters, digits, '.', '_' and '-'"; return; }
}

settings() {
  [[ "${RETENTION_DAYS}" =~ ^[0-9]+$ ]] && [ "${RETENTION_DAYS}" -ge 1 ] || { log "WARNING: BACKUP_RETENTION_DAYS '${RETENTION_DAYS}' invalid; using 30"; RETENTION_DAYS=30; }
  [[ "${KEEP_MIN}" =~ ^[0-9]+$ ]] && [ "${KEEP_MIN}" -ge 1 ] || { log "WARNING: BACKUP_KEEP_MIN '${KEEP_MIN}' invalid; using 3"; KEEP_MIN=3; }
  [[ "${BACKUP_TIME}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { log "WARNING: BACKUP_TIME '${BACKUP_TIME}' is not HH:MM (UTC); using 03:15"; BACKUP_TIME=03:15; }
}

configure_remote() {
  # rclone remote "bucket", configured only through the environment. Railway Buckets use
  # virtual-hosted-style URLs (path style is rejected).
  export RCLONE_CONFIG=/tmp/rclone.conf
  : > "${RCLONE_CONFIG}"
  export RCLONE_CONFIG_BUCKET_TYPE=s3
  export RCLONE_CONFIG_BUCKET_PROVIDER=Other
  export RCLONE_CONFIG_BUCKET_ENDPOINT="${BACKUP_S3_ENDPOINT}"
  export RCLONE_CONFIG_BUCKET_REGION="${BACKUP_S3_REGION:-auto}"
  export RCLONE_CONFIG_BUCKET_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID}"
  export RCLONE_CONFIG_BUCKET_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY}"
  export RCLONE_CONFIG_BUCKET_FORCE_PATH_STYLE="${BACKUP_S3_FORCE_PATH_STYLE:-false}"
  export RCLONE_CONFIG_BUCKET_NO_CHECK_BUCKET=true
  export RCLONE_CONFIG_BUCKET_CHUNK_SIZE=16M
  REMOTE="bucket:${BACKUP_S3_BUCKET}/${PREFIX}"
}

# gpg with a private home and the passphrase from a 0600 file (never on the command line).
gpg_setup() {
  WORK_DIR="$(mktemp -d /tmp/railway-backup.XXXXXX)"
  export GNUPGHOME="${WORK_DIR}/gnupg"
  mkdir -m 700 "${GNUPGHOME}"
  ( umask 077; printf '%s' "${BACKUP_ENCRYPTION_PASSPHRASE}" > "${WORK_DIR}/passphrase" )
}
gpg_batch() {
  gpg --batch --yes --quiet --no-tty --pinentry-mode loopback --passphrase-file "${WORK_DIR}/passphrase" "$@"
}

wait_for_postgres() {
  local waited=0
  until pg_isready -q -t 5 -d "${DATABASE_URL}"; do
    [ "${waited}" -ge "${WAIT_SECONDS}" ] && die "Postgres not ready after ${WAIT_SECONDS}s"
    sleep 5
    waited=$((waited + 5))
  done
}

list_runs() {
  rclone lsf --dirs-only "${REMOTE}/" 2>/dev/null | sed 's#/$##' | grep -E "${RUN_RE}" | sort || true
}
list_complete_runs() {
  rclone lsf -R --files-only --max-depth 2 --include 'MANIFEST.txt' "${REMOTE}/" 2>/dev/null \
    | sed 's#/MANIFEST.txt$##' | grep -E "${RUN_RE}" | sort || true
}

run_backup() {
  local run_id dest size vw_version server_version
  trap cleanup EXIT  # runs in a subshell, which does not inherit the trap
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="${REMOTE}/${run_id}"
  gpg_setup
  wait_for_postgres
  server_version="$(psql -XAtq -d "${DATABASE_URL}" -c 'SHOW server_version')"
  vw_version="$(/vaultwarden --version 2>/dev/null | head -n1)"
  log "run ${run_id}: dumping the database (PostgreSQL ${server_version})"
  pg_dump --format=custom --lock-wait-timeout=10min --dbname="${DATABASE_URL}" --file="${WORK_DIR}/db.dump"
  pg_restore --list "${WORK_DIR}/db.dump" > /dev/null

  log "run ${run_id}: uploading db.dump + ${DATA_DIR} (without icon_cache) to ${PREFIX}/${run_id}/${OBJECT}"
  tar -C "${WORK_DIR}" -cf - db.dump -C / \
      --exclude="${DATA_DIR#/}/icon_cache" --exclude="${DATA_DIR#/}/tmp" --exclude="${DATA_DIR#/}/lost+found" \
      "${DATA_DIR#/}" \
    | gpg_batch --symmetric --cipher-algo AES256 --s2k-digest-algo SHA512 --compress-algo none --output - \
    | rclone rcat --retries 1 "${dest}/${OBJECT}"

  # Verify: download, decrypt (gpg checks integrity) and list the tar.
  if ! rclone cat "${dest}/${OBJECT}" | gpg_batch --decrypt --output - | tar -tf - > "${WORK_DIR}/contents"; then
    die "run ${run_id}: verification failed (decrypt or tar); no MANIFEST.txt written"
  fi
  grep -qx 'db.dump' "${WORK_DIR}/contents" || die "run ${run_id}: db.dump missing from the archive"
  size="$(rclone size --json "${dest}/${OBJECT}" 2>/dev/null | sed -nE 's/.*"bytes":[[:space:]]*([0-9]+).*/\1/p')"
  printf 'run=%s\nobject=%s\nbytes=%s\nfiles=%s\nvaultwarden=%s\npostgres=%s\nencryption=gpg symmetric AES-256 (BACKUP_ENCRYPTION_PASSPHRASE)\n' \
    "${run_id}" "${OBJECT}" "${size:-?}" "$(grep -c . "${WORK_DIR}/contents")" "${vw_version}" "${server_version}" \
    | rclone rcat "${dest}/MANIFEST.txt"
  log "run ${run_id} complete (${size:-?} bytes, verified by decrypting and listing it)"
  CURRENT_RUN="${run_id}"
  prune
}

prune() {
  local now cutoff incomplete_cutoff complete=() run keep protected=" " total
  now="$(date -u +%s)"
  cutoff="$(date -u -d "@$((now - RETENTION_DAYS * 86400))" +%Y%m%dT%H%M%SZ)"
  incomplete_cutoff="$(date -u -d "@$((now - 2 * 86400))" +%Y%m%dT%H%M%SZ)"
  while IFS= read -r run; do [ -n "${run}" ] && complete+=("${run}"); done < <(list_complete_runs)
  total="${#complete[@]}"
  keep=$((total - KEEP_MIN))
  for run in ${complete[@]+"${complete[@]}"}; do
    if [ "${keep}" -le 0 ]; then protected="${protected}${run} "; fi
    keep=$((keep - 1))
  done
  log "retention: ${total} complete run(s); deleting runs older than ${RETENTION_DAYS} days, keeping at least ${KEEP_MIN}"
  while IFS= read -r run; do
    [ -n "${run}" ] || continue
    [ "${run}" = "${CURRENT_RUN:-}" ] && continue
    case "${protected}" in *" ${run} "*) continue ;; esac
    if printf '%s\n' ${complete[@]+"${complete[@]}"} | grep -qx "${run}"; then
      [[ "${run}" < "${cutoff}" ]] || continue
      log "deleting expired run ${run}"
    else
      [[ "${run}" < "${incomplete_cutoff}" ]] || continue
      log "deleting incomplete run ${run}"
    fi
    rclone purge "${REMOTE}/${run}" || log "WARNING: could not delete ${run}"
  done < <(list_runs)
}

# One backup at a time (the scheduler and BACKUP_ON_START may overlap).
locked_backup() {
  mkdir "${LOCK_DIR}" 2>/dev/null || { log "another backup is running; skipped"; return 1; }
  local rc=0
  ( run_backup ) || rc=$?
  rmdir "${LOCK_DIR}" 2>/dev/null || true
  [ "${rc}" -eq 0 ] || log "ERROR: backup failed (exit ${rc}); older backups were left untouched. Next attempt at the next scheduled time."
  return "${rc}"
}

seconds_until() {
  local now target
  now="$(date -u +%s)"
  target="$(date -u -d "$(date -u +%Y-%m-%d) $1" +%s)"
  [ "${target}" -gt "$((now + 30))" ] || target=$((target + 86400))
  echo $((target - now))
}

schedule() {
  local reason
  settings
  reason="$(disabled_reason)"
  if [ -n "${reason}" ]; then
    log "backups are OFF: ${reason}."
    return 0
  fi
  configure_remote
  log "daily encrypted backup at ${BACKUP_TIME} UTC to bucket ${BACKUP_S3_BUCKET}, folder ${PREFIX}/ (retention ${RETENTION_DAYS} days, keep at least ${KEEP_MIN})"
  if truthy "${BACKUP_ON_START:-false}"; then
    sleep 60
    log "BACKUP_ON_START=true: running a backup now"
    locked_backup || true
  fi
  while true; do
    sleep "$(seconds_until "${BACKUP_TIME}")"
    locked_backup || true
    sleep 61
  done
}

# SQL for the restore, in one transaction: reset the public schema, replay the dump, and
# COMMIT only if pg_restore finished. If anything fails, nothing changes.
restore_sql() {
  printf 'BEGIN;\nSET client_min_messages = warning;\nDROP SCHEMA IF EXISTS public CASCADE;\nCREATE SCHEMA public AUTHORIZATION pg_database_owner;\nGRANT USAGE ON SCHEMA public TO PUBLIC;\n'
  pg_restore --no-owner --no-privileges --file=- "$1" || exit 1
  printf 'COMMIT;\n'
}

restore_on_boot() {
  local want="${BACKUP_RESTORE_RUN:-}" confirm="${BACKUP_RESTORE_CONFIRM:-}" run reason
  [ -n "${want}" ] || return 0
  settings
  reason="$(BACKUP_ENABLED=true disabled_reason)"
  if [ -n "${reason}" ]; then
    log "restore requested but not possible: ${reason}."
    return 0
  fi
  if [ "${confirm}" != "${want}" ]; then
    log "restore of '${want}' requested: set BACKUP_RESTORE_CONFIRM=${want} as well to confirm that the database and ${DATA_DIR} are replaced. Nothing was restored."
    return 0
  fi
  configure_remote
  run="${want}"
  if [ "${run}" = "latest" ]; then
    run="$(list_complete_runs | tail -n 1)"
    [ -n "${run}" ] || { log "restore: no complete backup under ${PREFIX}/ in bucket ${BACKUP_S3_BUCKET}"; return 0; }
  fi
  if ! [[ "${run}" =~ ${RUN_RE} ]] || ! list_complete_runs | grep -qx "${run}"; then
    log "restore: '${run}' is not a complete backup run under ${PREFIX}/ (expected latest or a folder like 20261120T031500Z)."
    return 0
  fi
  if [ "$(cat "${RESTORE_MARKER}" 2>/dev/null)" = "${run}" ]; then
    log "restore: run ${run} was already restored; clear BACKUP_RESTORE_RUN and BACKUP_RESTORE_CONFIRM."
    return 0
  fi

  gpg_setup
  mkdir -p "${WORK_DIR}/restore"
  log "restore: downloading and decrypting ${PREFIX}/${run}/${OBJECT}"
  if ! rclone cat "${REMOTE}/${run}/${OBJECT}" | gpg_batch --decrypt --output - | tar -C "${WORK_DIR}/restore" -xf -; then
    log "ERROR: restore: could not decrypt or unpack run ${run} (wrong BACKUP_ENCRYPTION_PASSPHRASE?). Nothing was changed."
    return 1
  fi
  [ -f "${WORK_DIR}/restore/db.dump" ] && [ -d "${WORK_DIR}/restore/${DATA_DIR#/}" ] \
    || { log "ERROR: restore: archive of run ${run} has no db.dump or data/. Nothing was changed."; return 1; }
  wait_for_postgres
  log "restore: replacing the database (one transaction: all or nothing)"
  if ! ( restore_sql "${WORK_DIR}/restore/db.dump" ) | psql -X -q --set ON_ERROR_STOP=1 -d "${DATABASE_URL}" > /dev/null; then
    log "ERROR: restore: database restore failed; database and ${DATA_DIR} left unchanged."
    return 1
  fi
  log "restore: replacing the files in ${DATA_DIR}"
  find "${DATA_DIR}" -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf {} +
  cp -a "${WORK_DIR}/restore/${DATA_DIR#/}/." "${DATA_DIR}/"
  printf '%s' "${run}" > "${RESTORE_MARKER}"
  log "restore of run ${run} complete. Clear BACKUP_RESTORE_RUN and BACKUP_RESTORE_CONFIRM (a redeploy with the same values does nothing)."
}

main() {
  case "${1:-}" in
    schedule) schedule ;;
    run)
      settings
      reason="$(disabled_reason)"
      [ -z "${reason}" ] || die "backups are OFF: ${reason}"
      configure_remote
      locked_backup
      ;;
    restore-on-boot) restore_on_boot ;;
    *) die "usage: railway-backup schedule|run|restore-on-boot" ;;
  esac
}

main "$@"
