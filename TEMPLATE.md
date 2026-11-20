# Vaultwarden 1.37 Password Manager: composer spec

Listing name: **Vaultwarden 1.37 Password Manager**
Description (71 chars): Bitwarden-compatible password vault with Postgres and encrypted backups
Category: Authentication. Icon: `https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/vaultwarden.svg`
Repository: `baranberkay96/vaultwarden-railway` (this folder is the repo root).

## Services

| Service | Source | Public | Volume | Healthcheck |
|---|---|---|---|---|
| Vaultwarden | repo `/services/vaultwarden` (`FROM vaultwarden/server:1.37.5-alpine@sha256:bbe6…8191` + Alpine `postgresql18-client rclone gnupg argon2`) | domain → 8080 | `/data` | `/alive`, 600 s |
| Postgres | image `ghcr.io/railwayapp-templates/postgres-ssl:18.6@sha256:4fc8…c863` (= `:18`, checked 2026-11-20) | no | `/var/lib/postgresql/data` | — |
| Bucket | Railway Bucket `Bucket` | no | — | — |

Pinned 2026-11-20: Vaultwarden 1.37.5 (released 2026-11-01).

## Boot sequence (Vaultwarden)

`railway-vaultwarden.sh`:

1. `ROCKET_PORT` check (invalid → 8080). Malformed booleans (`SIGNUPS_ALLOWED`, `SIGNUPS_VERIFY`, `INVITATIONS_ALLOWED`, `SHOW_PASSWORD_HINT`, `PUSH_ENABLED`) and numbers (`SMTP_PORT`, `DATABASE_MAX_CONNS`) fall back to Vaultwarden's defaults with a warning; Vaultwarden itself would refuse to start.
2. `ADMIN_TOKEN`: `$argon2…` → used as is; plain ≥ 12 chars → argon2id hash (`-k 65540 -t 3 -p 4`, random salt) exported in its place; empty / < 12 → unset, `/admin` disabled (fail closed). Note when `/data/config.json` holds an `admin_token`.
3. `railway-backup restore-on-boot` (only with `BACKUP_RESTORE_RUN` = `BACKUP_RESTORE_CONFIRM`; marker `/data/.railway-restored-run` prevents repeats).
4. `railway-backup schedule &`, then `exec /start.sh` (the image's start script).

`DB_CONNECTION_RETRIES=0` makes Vaultwarden wait for Postgres on a cold start.

## Backup design

Railway volumes belong to one service, so a separate cron service cannot read `/data`; the backup runs in the Vaultwarden container on a daily `BACKUP_TIME` (UTC) loop. Each run: `pg_dump -Fc` → `tar` (db.dump + `data/` without `icon_cache`, `tmp`) → `gpg --symmetric --cipher-algo AES256` (passphrase from a 0600 file) → `rclone rcat` to `{prefix}/{run}/vaultwarden.tar.gpg` → download + decrypt + `tar -t` verify → `MANIFEST.txt` last → retention (30 days, keep ≥ 3, incomplete > 2 days deleted). A passphrase shorter than 16 characters or a missing Bucket turns backups off with a log line; never unencrypted. Restore: one transaction for the database (drop/recreate `public`, replay dump, COMMIT), then the files in `/data`.

## Improvements over market templates

Market (2026-11): Vaultwarden (Railway starter repo) ≈215 active, a SQLite variant ≈84 active, "Vaultwarden | Open Source Bitwarden Alternative" ≈40 active.

- Pinned image (market: `latest` or an old starter repo).
- Sign-up closed by default (the most-deployed market variants leave `SIGNUPS_ALLOWED` at its default `true` or set it to `true`).
- Admin token stored as argon2id hash in Vaultwarden (market: plain token, which Vaultwarden warns about, or no token).
- Postgres 18 with retries, plus a volume for attachments (the Postgres market template has no volume, so attachments and the RSA key are lost on redeploy).
- Daily encrypted, verified backups to a Railway Bucket with retention and a tested restore (none in the market).
- Deploy-form values never fail the deploy (8.29).

## Resources

Measured on Railway, test project, 2026-11-20 (Vaultwarden 1.37.5, Postgres 18.6):

| Service | Idle RAM | CPU idle |
|---|---|---|
| Vaultwarden | 0.03-0.04 GB (+ short spikes during a backup) | ~0.01 vCPU |
| Postgres | 0.09-0.10 GB | ~0 vCPU |

Estimate: ~0.15 GB RAM ≈ $1.5/month + CPU, volumes and bucket ≈ **$2-3/month**. Fits every plan, Free included.

Railway prices: RAM $10/GB-month, vCPU $20/vCPU-month, volume $0.15/GB-month.

## Verification checklist

1. Both services SUCCESS; `GET /alive` 200; log `ADMIN_TOKEN hashed with argon2id` and `daily encrypted backup at 03:15 UTC`.
2. `/admin` with a wrong token → 401; with `ADMIN_TOKEN` → 200 and session cookie.
3. Uninvited `send-verification-email` → 400 "Registration not allowed"; invite in `/admin` → register (`/finish`) → login → create a cipher → upload an attachment.
4. `BACKUP_ON_START=true` → log `run … complete (… verified …)`.
5. Add a second cipher, set `BACKUP_RESTORE_RUN=latest` + `BACKUP_RESTORE_CONFIRM=latest` → redeploy → vault back to 1 cipher + 1 attachment.
6. `ADMIN_TOKEN=abc`, `BACKUP_ENCRYPTION_PASSPHRASE=short`, `SIGNUPS_ALLOWED=maybe`, `SMTP_PORT=x25`, `BACKUP_TIME=25:99` → service stays healthy, warnings in the log, /admin disabled, backups off.

## Open questions

- Backups run inside the Vaultwarden service; if that service is down at `BACKUP_TIME`, the run is skipped until the next day (logged).
- Restores replace the whole vault; per-user restore is not offered.
