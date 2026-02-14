#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "error: reload2 requires a tag (example: ./scripts/reload2.sh --tag smoke)" >&2
  exit 1
fi

./scripts/reload.sh "$@"
./scripts/reloadp.sh
