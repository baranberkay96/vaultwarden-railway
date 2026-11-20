# Vaultwarden for Railway: the official Alpine image plus
#   - an argon2 hash of ADMIN_TOKEN made at boot (the plain token never reaches Vaultwarden),
#   - a daily, encrypted backup of the Postgres database and the /data volume to a Railway
#     Bucket, and a guarded restore, both running inside this container (Railway volumes
#     cannot be shared with a separate backup service).
#
# Pinned by tag and digest. To upgrade, change both to a newer release:
# https://hub.docker.com/r/vaultwarden/server/tags
FROM vaultwarden/server:1.37.5-alpine@sha256:bbe684a02d6b0db54256ff88eac9754f4519284a7b26314afc241fd7d0918191

# Alpine packages of the image's release branch (3.24). The Postgres client major must be
# >= the server's (Postgres runs postgres-ssl:18): bump postgresql18-client with it.
RUN apk add --no-cache bash coreutils argon2 gnupg postgresql18-client rclone tar gzip

ENV PATH="/usr/libexec/postgresql18:${PATH}"

COPY --chmod=755 railway-vaultwarden.sh /usr/local/bin/railway-vaultwarden
COPY --chmod=755 railway-backup.sh /usr/local/bin/railway-backup

# Fail the build early if a tool is missing or the client is not 18.
RUN pg_dump --version | grep -q ' 18\.' \
 && pg_restore --version >/dev/null && psql --version >/dev/null && pg_isready --version >/dev/null \
 && rclone version >/dev/null && gpg --version >/dev/null \
 && echo -n check | argon2 "$(head -c 16 /dev/urandom | base64)" -e -id -k 1024 -t 1 -p 1 | grep -q '^\$argon2id\$' \
 && bash -n /usr/local/bin/railway-vaultwarden && bash -n /usr/local/bin/railway-backup \
 && /vaultwarden --version

CMD ["/usr/local/bin/railway-vaultwarden"]
