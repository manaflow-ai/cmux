#!/bin/bash
# Fleet entry for cmux#64880's host encode A/B (gap 0 vs 150 ms, MaximizePowerEfficiency unset/0/1).
# Measurement only: runs at a --ref that carries cmux#64880's encode-selftest --gap-ms and
# cmux-tui/crates/cmux-rd-host/scripts/encode-gap-ab.sh; on other refs it says so and exits 2.
# No screen grant needed: encode-selftest feeds synthetic frames to VideoToolbox.
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/encode-gap-ab.sh \
#     --ref SHA --artifact artifacts/encode-gap-ab/encode-gap-ab.jsonl --timeout 3600
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
inner="$root/cmux-tui/crates/cmux-rd-host/scripts/encode-gap-ab.sh"
[ -f "$inner" ] || { echo "encode-gap-ab: $inner is missing at this ref; run at a ref carrying cmux#64880" >&2; exit 2; }
mkdir -p "$root/artifacts/encode-gap-ab"
FAST_CHECKS_OUT="$root/artifacts/encode-gap-ab" exec bash "$inner"
