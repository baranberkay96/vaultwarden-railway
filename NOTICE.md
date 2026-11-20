# Notice

## Upstream software

This repository contains Railway configuration and two shell scripts only. Vaultwarden is pulled at build time from its official image; it is not stored in this repository.

| Software | License | Source (publisher) |
|---|---|---|
| Vaultwarden 1.37.5 (server and the bundled web vault) | AGPL-3.0-only (server); GPL-3.0 (web vault, built from Bitwarden's clients) | `vaultwarden/server:1.37.5-alpine@sha256:bbe684a02d6b0db54256ff88eac9754f4519284a7b26314afc241fd7d0918191` (Vaultwarden project) |
| PostgreSQL 18 client, rclone, GnuPG, argon2, bash, GNU tar and coreutils | PostgreSQL License, MIT, GPL-3.0-or-later, CC0/Apache-2.0, GPL-3.0-or-later | Alpine Linux 3.24 packages, installed at build time |
| PostgreSQL 18 | PostgreSQL License | `ghcr.io/railwayapp-templates/postgres-ssl:18.6@sha256:4fc833b43d2aaf6ecc9b18615f5533602b723a32d0e2efe2dae8ca0f7217c863` (Railway; MIT-licensed image repository) |

Vaultwarden's license: https://github.com/dani-garcia/vaultwarden/blob/1.37.5/LICENSE.txt. Source code of the pinned release: https://github.com/dani-garcia/vaultwarden/tree/1.37.5.

## Verified against

| What | Upstream file | Ref | Checked |
|---|---|---|---|
| Latest release | GitHub release `1.37.5` (2026-11-01) | `1.37.5` | 2026-11-20 |
| Alpine image (base `alpine:3.24`, `/start.sh`, `/vaultwarden`, `ROCKET_PORT`, `/data`), database features `sqlite,mysql,postgresql` | `docker/Dockerfile.alpine`, `docker/start.sh` | `1.37.5` | 2026-11-20 |
| Admin token as argon2 PHC string, recommended `argon2 -id -k 65540 -t 3 -p 4` parameters | Vaultwarden wiki "Enabling admin page" | 2026-11 | 2026-11-20 |
| Registration flow (`/identity/accounts/register/send-verification-email` + `/finish`; invited e-mails may register when mail is disabled) | `src/api/identity.rs`, `src/api/core/accounts.rs` | `1.37.5` | 2026-11-20 |
| Settings (`SIGNUPS_ALLOWED`, `INVITATIONS_ALLOWED`, `DB_CONNECTION_RETRIES`, `SMTP_*`, `PUSH_*`, `/alive`) | `.env.template`, `src/config.rs` | `1.37.5` | 2026-11-20 |
| Alpine 3.24 packages (`postgresql18-client` 18.7, `rclone` 1.75.2, `gnupg` 2.4.9, `argon2`) | pkgs.alpinelinux.org | v3.24 | 2026-11-20 |

## Adapted code

| Our file | Source | Changes |
|---|---|---|
| `services/vaultwarden/railway-backup.sh` | Our own Postgres backup script from the n8n Production template (rclone remote from the environment, run folders with `MANIFEST.txt`, retention, one-transaction restore) | Adds `/data`, GnuPG encryption and decrypt-verify, in-container daily schedule and boot-time restore |
| `services/vaultwarden/railway-vaultwarden.sh` | Written for this template; ends in the image's `/start.sh` | — |

## Trademarks

Bitwarden is a trademark of Bitwarden, Inc. Vaultwarden is an unofficial, Bitwarden-compatible server, not associated with Bitwarden, Inc.; neither is this community template. "Railway" and "PostgreSQL" belong to their respective owners.
