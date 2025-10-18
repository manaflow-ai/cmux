#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/cli"
ENV_FILE="$ROOT_DIR/.env"

cd "$APP_DIR"
if [ "$#" -gt 0 ]; then
  exec bun run --env-file "$ENV_FILE" src/index.tsx -- "$@"
else
  exec bun run --env-file "$ENV_FILE" src/index.tsx
fi
