#!/usr/bin/env bash
# Fleet entry for the cmux-next NIGHTLY auto-update proof (R114). It runs as a
# controller "measure" step (class exclusive: alone on the worker) because it
# installs and launches a real nightly and must not share the host.
#   cmux-ci run --class exclusive --label measure --script scripts/measure/update-e2e.sh --ref <sha> [--arg=--click]
# --migration runs the filmed Restart to Update check from an older build instead
# (scripts/cmux-next/restart-to-update-migration.py; its own flags follow):
#   ... --arg=--migration --arg=--from=BUILD
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
if [ "${1:-}" = "--migration" ]; then
  shift
  exec python3 scripts/cmux-next/restart-to-update-migration.py "$@"
fi
exec python3 scripts/cmux-next/update-e2e.py "$@"
