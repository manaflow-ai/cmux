#!/usr/bin/env bash
# Terminal throughput (CMUX-571 goal terminal-throughput): a 200 MB burst through a cmux NEXT terminal and through
# standalone Ghostty on the same Mac, MB/s each and NEXT/Ghostty (scripts/cmux-next/terminal-throughput-bench.py).
# The perf cron runs the same bench as its `throughput` part (perf-cron.py PARTS, through split-spring.sh); this entry
# is for a one-off measurement. It builds (or reuses from the app cache) the tagged app, then runs both terminals in
# this one step. Needs a logged-in console (an owned mini):
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/terminal-throughput.sh \
#     --ref <sha> --artifact artifacts/split-spring/report.json [--arg=--mb=200] [--arg=--runs=3]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
exec "$here/split-spring.sh" --app-cache --vdisplay=120 --vdisplay-hold=1500 --suite=terminal-throughput "$@"
