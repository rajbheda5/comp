#!/usr/bin/env bash
# Rolls out a new release on the server: pull images, migrate, seed
# (idempotent upserts of the framework library), restart changed services.
#
# Usage: scripts/deploy.sh [image-tag]     (default: keep IMAGE_TAG from .env)

set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

if [ -n "${1:-}" ]; then
  if grep -qE '^IMAGE_TAG=' .env; then
    K=IMAGE_TAG V="$1" awk 'BEGIN{k=ENVIRON["K"]; v=ENVIRON["V"]}
      index($0, k"=")==1 {print k"="v; next} {print}' .env >.env.tmp && mv .env.tmp .env
    chmod 600 .env
  else
    echo "IMAGE_TAG=$1" >>.env
  fi
fi

echo "==> Pulling images ($(grep -E '^IMAGE_TAG=' .env | cut -d= -f2-))"
# --profile ops so the migrator image is refreshed too.
docker compose --profile ops pull

echo "==> Migrating"
docker compose run --rm migrate

echo "==> Seeding framework library"
docker compose run --rm seed

echo "==> Restarting services"
docker compose up -d --remove-orphans

docker image prune -f >/dev/null
docker compose ps
