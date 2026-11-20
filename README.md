# Deploy and Host Vaultwarden with Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/vaultwarden-137-password-manager?referralCode=20H68q)

Vaultwarden is a lightweight, self-hosted password manager server written in Rust that works with the Bitwarden apps, browser extensions and CLI. This community template runs Vaultwarden 1.37.5 with PostgreSQL 18, invitation-only sign-up, a hashed admin token, and a daily encrypted backup of the whole vault to a Railway Bucket.

## About Hosting Vaultwarden

A password vault needs a reliable database, persistent file storage for attachments, HTTPS, and backups you can actually restore. This template runs Vaultwarden on Railway with Postgres on the private network and a volume for attachments, Sends and the server's signing key. Public sign-up is off: you invite people from the admin panel. The admin token from the Railway variables is turned into an argon2id hash before Vaultwarden starts. Every night the service dumps the database, packs it with the volume, encrypts the archive with GnuPG (AES-256) and uploads it to a Railway Bucket, verifies it, and prunes old runs. A restore is one variable away. Measured on Railway: about 0.04 GB of RAM for Vaultwarden and 0.1 GB for Postgres.

## Common Use Cases

- A private password manager for a family, using the Bitwarden apps and browser extensions
- Shared vaults for a small team or company with organizations, collections and groups
- Storing passkeys, TOTP codes, secure notes and file attachments
- Sharing secrets with Bitwarden Send
- Replacing a hosted password manager while keeping data on infrastructure you control

## Dependencies for Vaultwarden Hosting

- Vaultwarden 1.37.5 (`vaultwarden/server`, official Alpine image, pinned by digest)
- PostgreSQL 18 (Railway's `postgres-ssl` image)
- A Railway Bucket (S3-compatible) for the encrypted backups

### Deployment Dependencies

- Vaultwarden source and releases: https://github.com/dani-garcia/vaultwarden
- Vaultwarden wiki (configuration, admin page, clients): https://github.com/dani-garcia/vaultwarden/wiki
- Bitwarden clients: https://bitwarden.com/download/
- Railway Buckets: https://docs.railway.com/guides/storage-buckets

### Implementation Details

| Service | Role | Public |
|---|---|---|
| Vaultwarden | Web vault, API for the Bitwarden clients, `/admin` panel, nightly encrypted backup; volume at `/data` for attachments, Sends and keys | **yes** |
| Postgres | Users, organizations and the encrypted vault items; private only, with a volume | no |
| Bucket | Encrypted backups (`vaultwarden/{timestamp}/vaultwarden.tar.gpg`) | no |

**First login**

1. Wait until the Vaultwarden service is healthy (the first deploy builds a thin image on top of the official one).
2. Copy `ADMIN_TOKEN` from the Vaultwarden service's Variables, open `https://{your-domain}/admin` and sign in with it.
3. In Users, invite your e-mail address. Without SMTP no e-mail is sent: open `https://{your-domain}`, choose Create account and register with the invited address.
4. In the Bitwarden app or extension, choose the self-hosted region and enter `https://{your-domain}` as the server URL.

Your master password never leaves your devices; Vaultwarden only stores encrypted data. There is no way to recover a forgotten master password.

**Sign-up and invitations.** `SIGNUPS_ALLOWED=false` keeps registration closed to everyone who was not invited. `SIGNUPS_DOMAINS_WHITELIST` can open it to your company's e-mail domain. Organization owners can invite people too.

**Admin token.** The plain `ADMIN_TOKEN` is hashed with argon2id at every boot, so Vaultwarden never sees it in plain text. You can also paste an argon2 PHC string (`$argon2id$...`) instead. An empty token, or one shorter than 12 characters, disables the admin page; the deploy keeps running and the log says why. Settings saved in the admin panel are stored in `/data/config.json` and override variables, including the token.

**Backups.** The backup runs inside the Vaultwarden service at `BACKUP_TIME` (03:15 UTC), because Railway volumes cannot be shared with another service. Each run dumps Postgres, packs the dump with `/data` (without the icon cache), encrypts it with `BACKUP_ENCRYPTION_PASSPHRASE`, uploads it, downloads and decrypts it again to verify, and only then writes `MANIFEST.txt`. Runs older than 30 days are deleted, but the newest 3 are always kept. Set `BACKUP_ON_START=true` to take a backup about a minute after each boot. **Store a copy of `BACKUP_ENCRYPTION_PASSPHRASE` outside Railway**: without it the backups cannot be decrypted. To decrypt a downloaded run on your computer: `gpg -d vaultwarden.tar.gpg | tar -x`.

**Restore.** Set `BACKUP_RESTORE_RUN` to `latest` (or a run folder such as `20261120T031500Z`) and `BACKUP_RESTORE_CONFIRM` to the same value, then redeploy. Before Vaultwarden starts, the database is replaced in one transaction and the files in `/data` are replaced. Clear both variables afterwards; a redeploy with the same values does not restore twice.

**E-mail.** Set `SMTP_HOST`, `SMTP_FROM` and the other `SMTP_*` variables for invitation mails, e-mail 2FA and new-device alerts. Railway allows outbound SMTP only on the Pro plan.

**Mobile push.** For instant sync on iOS and Android, request an installation id and key at https://bitwarden.com/host, set them in `PUSH_INSTALLATION_ID` and `PUSH_INSTALLATION_KEY`, and set `PUSH_ENABLED=true`.

**Custom domain.** Add it in the service's Settings → Networking and set `DOMAIN` to `https://{your-domain}`. Passkey logins are tied to the domain, so choose it before enrolling passkeys.

**Resources and plans.** Measured on Railway (Vaultwarden 1.37.5, 2026-11-20): Vaultwarden uses about 0.04 GB of RAM and Postgres about 0.1 GB; a backup run takes seconds for a typical vault. That is roughly $2-3 a month at Railway's usage prices, so every plan works, Free included. Bucket storage is billed separately and is small for a typical vault.

**Scaling.** Vaultwarden runs as one replica because attachments live on the volume; one small instance serves hundreds of users.

**Upgrading Vaultwarden.** The version is pinned in `services/vaultwarden/Dockerfile` (tag and digest). When this template is updated, Railway offers the update. To pick a version yourself, eject the service to your own GitHub repository and change the `FROM` line. Database migrations run automatically on start; take a backup first (`BACKUP_ON_START=true`).

**License.** Vaultwarden is licensed under AGPL-3.0. Vaultwarden is an unofficial, community-built Bitwarden-compatible server; neither Vaultwarden nor this template is affiliated with Bitwarden, Inc. Bitwarden is a trademark of Bitwarden, Inc.

### Why Deploy Vaultwarden on Railway?

Railway runs Vaultwarden, Postgres and a storage bucket in one project with a private network, an HTTPS domain, logs and usage-based pricing. This template gives you a locked-down password vault in a few minutes, with closed sign-up, a hashed admin token and nightly encrypted backups you can restore with two variables.
