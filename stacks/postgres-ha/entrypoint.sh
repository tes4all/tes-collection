#!/bin/sh
set -e

# ─── Docker Secrets Support ───────────────────────────────────────────────────
# If Docker secrets are mounted (Swarm mode), read them and export as env vars.
# Secret file names map to env var names:
#   /run/secrets/postgres_password  →  POSTGRES_PASSWORD
#   /run/secrets/replicator_password →  REPLICATOR_PASSWORD
#   /run/secrets/admin_password     →  ADMIN_PASSWORD
if [ -d "/run/secrets" ]; then
    for secret_file in /run/secrets/*; do
        if [ -f "$secret_file" ]; then
            secret_name=$(basename "$secret_file")
            env_name=$(echo "$secret_name" | tr '[:lower:]' '[:upper:]')
            export "$env_name"="$(cat "$secret_file")"
        fi
    done
fi

# ─── Defaults (for local development only — override in production!) ──────────
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
export REPLICATOR_PASSWORD="${REPLICATOR_PASSWORD:-replicator}"
export ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

# ─── Render Patroni config template ──────────────────────────────────────────
# envsubst replaces ${VAR} placeholders in the template with actual values.
# Only substitute known variables to avoid breaking YAML syntax.
envsubst '$HOSTNAME $POSTGRES_PASSWORD $REPLICATOR_PASSWORD $ADMIN_PASSWORD' \
    < /etc/patroni/patroni.yml.tpl > /tmp/patroni.yml

# ─── Fix permissions ─────────────────────────────────────────────────────────
if [ -d "/var/lib/postgresql/data" ]; then
    chmod 700 /var/lib/postgresql/data
fi

exec "$@"
