#!/usr/bin/env bash
# run.sh [--slot S] [--runs N] [MOTION...]: drive the Tabs app (mock host) on the
# remote simulator through each motion, record it, and compare it with
# Safari's curve (check.py). Exit 1 if any run of any motion fails.
#
#   CMUX_NEXT_IOS_HOST=mini-cmux15 ios-next/scripts/tabs-curves/run.sh --slot base
#
# Needs a slot with a built Tabs app (remote-ios.sh build --slot S --scheme Tabs)
# and a simulator without a hardware keyboard.
set -uo pipefail
slot="tabs"; runs=3; motions=()
while [[ $# -gt 0 ]]; do case "$1" in --slot) slot="$2"; shift 2 ;; --runs) runs="$2"; shift 2 ;; *) motions+=("$1"); shift ;; esac; done
[[ ${#motions[@]} -eq 0 ]] && motions=(reflow zoomOut zoomIn swipeUp snapBack fling)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$HERE/../remote-ios.sh"
HOST="${CMUX_NEXT_IOS_HOST:-aziz-other-macbook}"
OUT="${TMPDIR:-/tmp}/tabs-curves"; mkdir -p "$OUT"
U=$(ssh "$HOST" "cat ~/nx-ios/$slot/sim.udid")
axe() { ssh "$HOST" "axe $* --udid $U >/dev/null 2>&1 || ~/nx-ios/axe/axe $* --udid $U >/dev/null 2>&1"; }
fail=0
for m in "${motions[@]}"; do
  for i in $(seq 1 "$runs"); do
    "$R" launch --slot "$slot" --scheme Tabs --env CMUX_NEXT_DEV_SCREEN=tabs-combined --env CMUX_NEXT_TABS_RESET_PINS=1 >/dev/null
    sleep 6                                              # launch and mock connect (test script only)
    case "$m" in
      zoomOut|swipeUp) pre=() ;;
      *) axe tap -x 344 -y 816; sleep 1.5; pre=() ;;      # open the grid
    esac
    case "$m" in
      reflow)   g="tap -x 178 -y 137" ;;
      zoomOut)  g="tap -x 344 -y 816" ;;
      zoomIn)   g="tap -x 297 -y 250" ;;
      swipeUp)  g="swipe --start-x 200 --start-y 816 --end-x 200 --end-y 566 --duration 0.25" ;;
      snapBack) g="drag --start-x 330 --start-y 250 --end-x 230 --end-y 250 --duration 1.0 --steps 60" ;;
      fling)    g="swipe --start-x 330 --start-y 250 --end-x 230 --end-y 250 --duration 0.12" ;;
    esac
    ssh "$HOST" "rm -f /tmp/tc.mp4; (xcrun simctl io $U recordVideo --codec=h264 --force /tmp/tc.mp4 >/dev/null 2>&1 & echo \$! > /tmp/tc.pid); sleep 1.5; (axe $g --udid $U || ~/nx-ios/axe/axe $g --udid $U) >/dev/null 2>&1; sleep 1.8; kill -INT \$(cat /tmp/tc.pid); while kill -0 \$(cat /tmp/tc.pid) 2>/dev/null; do sleep 0.2; done"
    scp -q "$HOST:/tmp/tc.mp4" "$OUT/$m-$i.mp4"
    printf 'run %d ' "$i"; python3 "$HERE/check.py" "$m" "$OUT/$m-$i.mp4" || fail=1
  done
done
exit $fail
