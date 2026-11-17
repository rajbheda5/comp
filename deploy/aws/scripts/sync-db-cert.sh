#!/usr/bin/env bash
# Copies the Let's Encrypt certificate Caddy manages for DB_DOMAIN into the
# directory Postgres reads its TLS cert from, then reloads Postgres.
# Runs daily from /etc/cron.d/comp (as root: the key must be owned by the
# postgres user, uid 70 in the alpine image, with mode 0600).

set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
env_get() { grep -E "^$1=" "$DIR/.env" | tail -1 | cut -d= -f2-; }

DB_DOMAIN="$(env_get DB_DOMAIN)"
POSTGRES_USER="$(env_get POSTGRES_USER)"; POSTGRES_USER="${POSTGRES_USER:-comp}"
POSTGRES_DB="$(env_get POSTGRES_DB)"; POSTGRES_DB="${POSTGRES_DB:-comp}"
PG_UID=70

src_dir="$(find "$DIR/data/caddy/certificates" -mindepth 2 -maxdepth 2 -type d -name "$DB_DOMAIN" 2>/dev/null | head -1 || true)"
if [ -z "$src_dir" ] || [ ! -f "$src_dir/$DB_DOMAIN.crt" ] || [ ! -f "$src_dir/$DB_DOMAIN.key" ]; then
  echo "$(date -u +%FT%TZ) no certificate for $DB_DOMAIN yet under data/caddy/certificates" >&2
  exit 1
fi

dest="$DIR/data/postgres-certs"
mkdir -p "$dest"
if cmp -s "$src_dir/$DB_DOMAIN.crt" "$dest/server.crt" && cmp -s "$src_dir/$DB_DOMAIN.key" "$dest/server.key"; then
  echo "$(date -u +%FT%TZ) certificate unchanged"
  exit 0
fi

install -o "$PG_UID" -g "$PG_UID" -m 0644 "$src_dir/$DB_DOMAIN.crt" "$dest/server.crt"
install -o "$PG_UID" -g "$PG_UID" -m 0600 "$src_dir/$DB_DOMAIN.key" "$dest/server.key"
echo "$(date -u +%FT%TZ) installed certificate for $DB_DOMAIN"

cd "$DIR"
if docker compose ps --status running --services 2>/dev/null | grep -qx postgres; then
  docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -qAt -c 'SELECT pg_reload_conf();' >/dev/null
  echo "$(date -u +%FT%TZ) postgres reloaded"
fi
