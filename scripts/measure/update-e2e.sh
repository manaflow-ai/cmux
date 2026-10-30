#!/usr/bin/env bash
# Fleet entry for the cmux-next NIGHTLY auto-update proof (R114). It runs as a
# controller "measure" step (class exclusive: alone on the worker) because it
# installs and launches a real nightly and must not share the host.
#   cmux-ci run --class exclusive --label measure --script scripts/measure/update-e2e.sh --ref <sha> [--arg=--click]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
exec python3 scripts/cmux-next/update-e2e.py "$@"
