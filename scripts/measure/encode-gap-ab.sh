#!/bin/bash
# Fleet entry for cmux#64880's host encode A/B (gap 0 vs 150 ms, MaximizePowerEfficiency unset/0/1).
# No screen grant needed: encode-selftest feeds synthetic frames to VideoToolbox.
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/encode-gap-ab.sh \
#     --ref SHA --artifact artifacts/encode-gap-ab/encode-gap-ab.jsonl --timeout 3600
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$root/artifacts/encode-gap-ab"
FAST_CHECKS_OUT="$root/artifacts/encode-gap-ab" exec bash "$root/cmux-tui/crates/cmux-rd-host/scripts/encode-gap-ab.sh"
