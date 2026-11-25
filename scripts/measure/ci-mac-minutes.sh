#!/usr/bin/env bash
# Completed CI job and step minutes by runner OS; see ci-mac-minutes.py for limits.
# cmux-ci run --class light --ref SHA --script scripts/measure/ci-mac-minutes.sh --arg=/path/to/timing.jsonl --arg=SINCE --arg=UNTIL
set -euo pipefail
exec python3 "$(dirname "$0")/ci-mac-minutes.py" "$@"
