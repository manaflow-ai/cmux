#!/usr/bin/env bash
# Running VM time with no assigned CI job, from a capture on the worker.
# cmux-ci run --class exclusive --ref SHA --script scripts/measure/ci-vm-idle.sh --arg /path/to/capture
set -euo pipefail
exec python3 "$(dirname "$0")/ci-vm-idle.py" "$@"
