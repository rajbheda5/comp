#!/usr/bin/env bash
# Creates deploy/aws/.env and deploy/aws/comp.env from the examples:
#   - fills every __GENERATE__ placeholder with a random 64-char hex secret
#   - copies matching values (buckets, access keys) from provision-output.env
# Existing files are never overwritten; re-running only fills values that are
# still placeholders or missing.
#
# Usage: scripts/init-env.sh [path/to/provision-output.env]

set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROVISION="${1:-$DIR/provision-output.env}"

set_kv() {
  local file="$1" key="$2" value="$3"
  K="$key" V="$value" awk 'BEGIN{k=ENVIRON["K"]; v=ENVIRON["V"]}
    index($0, k"=")==1 {print k"="v; next} {print}' "$file" >"$file.tmp"
  mv "$file.tmp" "$file"
}

for name in .env comp.env; do
  src="$DIR/${name}.example"
  dst="$DIR/$name"
  if [ ! -f "$dst" ]; then
    cp "$src" "$dst"
    echo "Created $dst"
  fi
  chmod 600 "$dst"

  while IFS= read -r key; do
    set_kv "$dst" "$key" "$(openssl rand -hex 32)"
  done < <(grep -E '^[A-Z0-9_]+=__GENERATE__$' "$dst" | cut -d= -f1)

  if [ -f "$PROVISION" ]; then
    while IFS='=' read -r key value; do
      [ -n "$key" ] || continue
      if grep -qE "^${key}=" "$dst"; then
        set_kv "$dst" "$key" "$value"
      fi
    done < <(grep -E '^[A-Z0-9_]+=' "$PROVISION")
  fi
done

# Keep the three auth secrets identical (the API signs, app/portal verify).
auth_secret="$(grep -E '^SECRET_KEY=' "$DIR/comp.env" | cut -d= -f2-)"
set_kv "$DIR/comp.env" AUTH_SECRET "$auth_secret"
set_kv "$DIR/comp.env" BETTER_AUTH_SECRET "$auth_secret"

echo
echo "Now edit by hand:"
echo "  $DIR/.env      -> domains, ACME_EMAIL, IMAGE_PREFIX, TRIGGER_*_SECRET_KEY"
echo "  $DIR/comp.env  -> RESEND_*, AI_GATEWAY_API_KEY, OPENAI_API_KEY, ANTHROPIC_API_KEY, optional keys"
