#!/usr/bin/env bash
# How interactive this machine is right now, as one JSON line (RFD 0072 "The measurement"): timer lateness (a
# user-interactive thread sleeping 10 ms, p50/p95/p99/max and the share over 5 and 16 ms), CPU busy over the window,
# load, memory pressure, swap size and growth, thermal pressure and HID idle. Read-only; macOS and Linux.
#
#   scripts/measure/interactive-lateness.sh [seconds=60] [label=run]
#   scripts/measure/interactive-lateness.sh 60 before      # positional works too
#
# Run it on the Mac before and after one move (an agent moved to the cloud) with the same seconds, and compare the two
# lines. The probe is scripts/measure/latency_probe.py; this wrapper only reads the arguments.
set -euo pipefail

seconds=60
label=run
pos=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    seconds=*) seconds="${arg#seconds=}" ;;
    label=*) label="${arg#label=}" ;;
    *=*) echo "interactive-lateness.sh: unknown argument $arg (seconds=, label=)" >&2; exit 2 ;;
    *)
      case "$pos" in
        0) seconds="$arg" ;;
        1) label="$arg" ;;
        *) echo "interactive-lateness.sh: too many arguments" >&2; exit 2 ;;
      esac
      pos=$((pos + 1)) ;;
  esac
done

exec python3 -I "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/latency_probe.py" "$seconds" "$label"
