#!/usr/bin/env bash
# First start on the server. Order matters: Postgres serves TLS with the
# Let's Encrypt certificate Caddy obtains for DB_DOMAIN, so Caddy must get
# that certificate before Postgres can start.
#
#   1. start Caddy, wait for the DB certificate
#   2. hand the certificate to Postgres, start Postgres + Redis
#   3. migrate + seed the database
#   4. start app, portal, api
#   5. install cron jobs (daily cert sync, nightly backup)
#
# Run from anywhere as the ubuntu user (uses sudo for the cert/cron steps).

set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

for f in .env comp.env; do
  [ -f "$f" ] || { echo "Missing $DIR/$f — run scripts/init-env.sh first." >&2; exit 1; }
  if grep -qE '=__GENERATE__$' "$f"; then
    echo "$f still has __GENERATE__ placeholders — run scripts/init-env.sh." >&2; exit 1
  fi
done
env_get() { grep -E "^$1=" .env | tail -1 | cut -d= -f2-; }
for k in APP_DOMAIN PORTAL_DOMAIN API_DOMAIN DB_DOMAIN COOKIE_DOMAIN ACME_EMAIL IMAGE_PREFIX TRIGGER_APP_SECRET_KEY TRIGGER_API_SECRET_KEY; do
  v="$(env_get "$k")"
  if [ -z "$v" ] || [[ "$v" == *example.com* ]] || [[ "$v" == *your-github-user* ]]; then
    echo ".env: set $k (currently '${v}')." >&2; exit 1
  fi
done
DB_DOMAIN="$(env_get DB_DOMAIN)"

mkdir -p data/caddy data/caddy-config data/postgres data/postgres-certs data/redis
chmod +x scripts/*.sh

echo "==> Pulling images"
docker compose --profile ops pull

echo "==> Starting Caddy and waiting for the $DB_DOMAIN certificate"
docker compose up -d caddy
for i in $(seq 1 36); do
  if sudo find data/caddy/certificates -mindepth 2 -maxdepth 2 -type d -name "$DB_DOMAIN" 2>/dev/null | grep -q .; then
    break
  fi
  if [ "$i" = 36 ]; then
    echo "No certificate after 3 minutes. Check that DNS for $DB_DOMAIN points at this server" >&2
    echo "and port 80 is open, then look at: docker compose logs caddy" >&2
    exit 1
  fi
  sleep 5
done
sudo "$DIR/scripts/sync-db-cert.sh"

echo "==> Starting Postgres and Redis"
docker compose up -d --wait postgres redis redis-http

echo "==> Migrating and seeding the database"
docker compose run --rm migrate
docker compose run --rm seed

echo "==> Starting app, portal, api"
docker compose up -d --remove-orphans

echo "==> Installing cron jobs"
sudo tee /etc/cron.d/comp >/dev/null <<EOF
# Comp AI maintenance (installed by deploy/aws/scripts/bootstrap.sh)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
40 4 * * * root $DIR/scripts/sync-db-cert.sh >>/var/log/comp-cert.log 2>&1
17 3 * * * $(id -un) $DIR/scripts/backup-db.sh >>/var/log/comp-backup.log 2>&1
EOF
sudo touch /var/log/comp-backup.log /var/log/comp-cert.log
sudo chown "$(id -un)" /var/log/comp-backup.log

docker compose ps
cat <<EOF

Comp is starting at https://$(env_get APP_DOMAIN)
Logs: docker compose logs -f app api portal
EOF
