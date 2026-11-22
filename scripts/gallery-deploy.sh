#!/usr/bin/env bash
# Publish an already captured matrix using the runner's shared tailnet deploy path.
set -euo pipefail
if [[ $# != 3 || "$1" != "--matrix" ]]; then
  echo "Usage: scripts/gallery-deploy.sh --matrix RUN OUTPUT_DIR" >&2
  exit 2
fi
script_dir="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$3/index.html" && -f "$3/results.json" ]] || {
  echo "Matrix output must contain index.html and results.json" >&2
  exit 1
}
exec bun --eval 'const { publishRun } = await import(process.argv[1]); console.log(publishRun(process.argv[2], process.argv[3]));' \
  "$script_dir/gallery-matrix/runner.ts" "$3" "$2"
