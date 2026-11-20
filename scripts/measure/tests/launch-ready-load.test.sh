#!/usr/bin/env bash
# launch-ready.sh's wait_load holds each launch until the Mac's 1-minute load is under 8, at most LR_LOAD_WAIT_S. On
# 2026-11-17 three A/Bs came back NOT VALID because the step's own two builds left the load at 12-21 for the first
# pairs and launch-ready only recorded it.
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/launch-ready.sh"
# shellcheck source=/dev/null
source "$script"
set +e

slept=0
sleep() { slept=$((slept + $1)); }
fail() { echo "FAIL: $*"; exit 1; }

# A load that falls under 8 after three reads: waits 15 s, says so, and returns.
loads=(14.2 11.0 8.3 6.1)
load_1m() { echo "${loads[$(( slept / 5 ))]:-6.1}"; }
out="$(wait_load base run1)"
[[ "$out" == "LR-LOAD-WAIT base run1 waited_s=15 load_1m=6.1" ]] || fail "falling load: $out"

# Already under 8: no wait, no line.
slept=0
load_1m() { echo 3.2; }
out="$(wait_load head run2)"
[[ -z "$out" && "$slept" == 0 ]] || fail "quiet Mac: '$out' slept=$slept"

# Never under 8: gives up at the limit and the launch runs.
slept=0
load_1m() { echo 12.5; }
out="$(LR_LOAD_WAIT_S=20 wait_load base run3)"
[[ "$out" == "LR-LOAD-WAIT base run3 waited_s=20 load_1m=12.5 still over 8" ]] || fail "busy Mac: $out"

# An unreadable load (empty) does not hold the launch.
slept=0
load_1m() { echo ""; }
out="$(wait_load head run4)"
[[ -z "$out" ]] || fail "unread load: $out"

# Exactly 8 is not under 8.
slept=0
loads=(8 7.99)
load_1m() { echo "${loads[$(( slept / 5 ))]:-7.99}"; }
out="$(wait_load base run5)"
[[ "$out" == "LR-LOAD-WAIT base run5 waited_s=5 load_1m=7.99" ]] || fail "boundary: $out"

echo "launch-ready-load: ok"
