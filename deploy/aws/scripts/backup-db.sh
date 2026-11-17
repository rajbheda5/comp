#!/usr/bin/env bash
# Streams a compressed pg_dump straight to S3 (nothing written to local disk).
# Runs nightly from /etc/cron.d/comp. The backup IAM user can only PutObject;
# the bucket is versioned and expires dumps after 30 days.
#
# Restore (stop app/api/portal first):
#   aws s3 cp s3://$BACKUP_BUCKET/postgres/<file>.dump - \
#     | docker compose exec -T postgres pg_restore -U comp -d comp --clean --if-exists --no-owner

set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
env_get() { grep -E "^$1=" "$DIR/.env" | tail -1 | cut -d= -f2-; }

BUCKET="$(env_get BACKUP_BUCKET)"
if [ -z "$BUCKET" ]; then
  echo "BACKUP_BUCKET is not set in .env; skipping backup." >&2
  exit 1
fi
POSTGRES_USER="$(env_get POSTGRES_USER)"; POSTGRES_USER="${POSTGRES_USER:-comp}"
POSTGRES_DB="$(env_get POSTGRES_DB)"; POSTGRES_DB="${POSTGRES_DB:-comp}"
KEY="postgres/${POSTGRES_DB}-$(date -u +%Y%m%dT%H%M%SZ).dump"

cd "$DIR"
docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --compress=6 \
  | docker run --rm -i \
      -e AWS_ACCESS_KEY_ID="$(env_get BACKUP_AWS_ACCESS_KEY_ID)" \
      -e AWS_SECRET_ACCESS_KEY="$(env_get BACKUP_AWS_SECRET_ACCESS_KEY)" \
      -e AWS_DEFAULT_REGION="$(env_get BACKUP_AWS_REGION)" \
      amazon/aws-cli:2.40.4 s3 cp - "s3://$BUCKET/$KEY" --only-show-errors

echo "$(date -u +%FT%TZ) backup uploaded to s3://$BUCKET/$KEY"
