#!/bin/bash
# Boot wrapper for Vaultwarden on Railway.
#
#  1. ROCKET_PORT check (invalid -> 8080 with a warning).
#  2. ADMIN_TOKEN: a plain token from the Railway variables is replaced by an argon2id hash
#     (PHC string) before Vaultwarden starts, so Vaultwarden never sees the plain value.
#     A value that already is an argon2 PHC string is used as is. Empty or shorter than
#     12 characters: the /admin page is disabled (fail closed) and the log says why.
#  3. One-shot restore from the Bucket when BACKUP_RESTORE_RUN is set (railway-backup).
#  4. The daily backup scheduler in the background (railway-backup schedule).
#  5. exec the image's own /start.sh (Vaultwarden becomes the main process).
#
# No variable value ever stops the boot (STANDARD 8.29).
set -uo pipefail

log() { printf '[railway] %s\n' "$*"; }

port="${ROCKET_PORT:-${PORT:-8080}}"
if ! [[ "${port}" =~ ^[0-9]{1,5}$ ]] || [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
  log "WARNING: ROCKET_PORT '${port}' is not a port number; using 8080."
  port=8080
fi
export ROCKET_PORT="${port}"

# Vaultwarden refuses to start on a malformed boolean or number; fall back to its default.
for var in SIGNUPS_ALLOWED SIGNUPS_VERIFY INVITATIONS_ALLOWED SHOW_PASSWORD_HINT PUSH_ENABLED; do
  value="${!var-}"
  [ -n "${value}" ] || continue
  case "${value,,}" in
    true|1|yes|on) export "${var}=true" ;;
    false|0|no|off) export "${var}=false" ;;
    *) log "WARNING: ${var} '${value}' is not true/false; using Vaultwarden's default."; unset "${var}" ;;
  esac
done
for var in SMTP_PORT DATABASE_MAX_CONNS; do
  value="${!var-}"
  [ -n "${value}" ] || continue
  [[ "${value}" =~ ^[0-9]{1,5}$ ]] || { log "WARNING: ${var} '${value}' is not a number; using Vaultwarden's default."; unset "${var}"; }
done
unset var value

token="${ADMIN_TOKEN:-}"
if [[ "${token}" == '$argon2'* ]]; then
  log "ADMIN_TOKEN is an argon2 hash; /admin is enabled."
elif [ -z "${token}" ]; then
  unset ADMIN_TOKEN
  log "ADMIN_TOKEN is empty: the /admin page is disabled."
elif [ "${#token}" -lt 12 ]; then
  unset ADMIN_TOKEN
  log "WARNING: ADMIN_TOKEN is shorter than 12 characters, so the /admin page is disabled. Set a longer ADMIN_TOKEN (or an argon2 hash) and redeploy."
else
  # Bitwarden's argon2id defaults (64 MiB, 3 iterations, 4 lanes), as the Vaultwarden wiki recommends.
  if hash="$(printf '%s' "${token}" | argon2 "$(head -c 32 /dev/urandom | base64)" -e -id -k 65540 -t 3 -p 4)" && [[ "${hash}" == '$argon2id$'* ]]; then
    export ADMIN_TOKEN="${hash}"
    log "ADMIN_TOKEN hashed with argon2id; sign in to /admin with the plain value from the Railway variables."
  else
    unset ADMIN_TOKEN
    log "WARNING: hashing ADMIN_TOKEN failed; the /admin page is disabled on this boot."
  fi
fi
unset token hash
if [ -f /data/config.json ] && grep -q '"admin_token"' /data/config.json 2>/dev/null; then
  log "NOTE: /data/config.json (settings saved in /admin) contains an admin_token; it overrides the ADMIN_TOKEN variable."
fi

/usr/local/bin/railway-backup restore-on-boot || log "WARNING: restore step ended with an error; starting Vaultwarden with the current data."

/usr/local/bin/railway-backup schedule &

exec /start.sh "$@"
