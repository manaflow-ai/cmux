#!/usr/bin/env bash
# Fleet entry for scripts/measure/mac-screen-replay-nightly.py (see its docstring): the controller runs
# scripts/measure/<name>.sh only. Prints `MAC_SCREEN_REPLAY {json}` as its last line.
#   cmux-ci run --class exclusive --label measure --display \
#     --script scripts/measure/mac-screen-replay-nightly.sh --ref <sha> [--arg=build=N] [--arg=frames=120]
set -euo pipefail
cd "$(dirname "$0")/../.."
exec python3 scripts/measure/mac-screen-replay-nightly.py "$@"
