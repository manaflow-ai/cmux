#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLIENT_DIR="$ROOT_DIR/apps/client"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script must be run on a Linux host" >&2
  exit 1
fi

ENV_FILE="$ROOT_DIR/.env.production"
if [[ ! -f "$ENV_FILE" ]]; then
  ENV_FILE="$ROOT_DIR/.env"
fi

(cd "$CLIENT_DIR" && bun run --env-file "$ENV_FILE" build:linux)
