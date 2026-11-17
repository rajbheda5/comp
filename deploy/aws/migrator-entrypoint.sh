#!/bin/sh
set -eu

case "${1:-migrate}" in
  migrate)
    exec bunx prisma migrate deploy
    ;;
  seed)
    exec bun prisma/seed/seed.ts
    ;;
  *)
    exec "$@"
    ;;
esac
