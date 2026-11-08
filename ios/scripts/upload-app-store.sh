#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for arg in "$@"; do
  case "$arg" in
    --lane|--lane=*)
      echo "error: upload-app-store.sh always uses --lane appstore; do not pass --lane" >&2
      exit 2
      ;;
  esac
done
exec "$SCRIPT_DIR/upload-testflight.sh" --lane appstore "$@"
