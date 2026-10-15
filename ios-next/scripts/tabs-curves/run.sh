#!/usr/bin/env bash
# run.sh [--slot S] [--runs N] [--app tabs|kit] [MOTION...]: drive the Tabs app
# (mock host) or the CmuxTabsKit demo on the remote simulator through each
# motion, record it, and compare it with Safari's curve (check.py). Exit 1 if
# any run of any motion fails.
#
#   CMUX_NEXT_IOS_HOST=mini-cmux15 ios-next/scripts/tabs-curves/run.sh --slot base
#
# Needs a slot with a built Tabs app (remote-ios.sh build --slot S --scheme Tabs)
# and a simulator without a hardware keyboard. --app kit needs the kit demo
# (dev.cmux.tabskit.demo) installed on the slot's simulator; it has no fling
# (only its active card has a snapshot).
set -uo pipefail
slot="tabs"; runs=3; app="tabs"; motions=()
while [[ $# -gt 0 ]]; do case "$1" in --slot) slot="$2"; shift 2 ;; --runs) runs="$2"; shift 2 ;; --app) app="$2"; shift 2 ;; *) motions+=("$1"); shift ;; esac; done
if [[ ${#motions[@]} -eq 0 ]]; then
  if [[ $app == kit ]]; then motions=(reflow zoomOut zoomIn swipeUp snapBack); else motions=(reflow zoomOut zoomIn swipeUp snapBack fling twoToOne tapZoomOut drag lastTab); fi
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$HERE/../remote-ios.sh"
HOST="${CMUX_NEXT_IOS_HOST:-aziz-other-macbook}"
OUT="${TMPDIR:-/tmp}/tabs-curves"; mkdir -p "$OUT"
U=$(ssh "$HOST" "cat ~/nx-ios/$slot/sim.udid")
axe() { ssh "$HOST" "axe $* --udid $U >/dev/null 2>&1 || ~/nx-ios/axe/axe $* --udid $U >/dev/null 2>&1"; }
fail=0
for m in "${motions[@]}"; do
  for i in $(seq 1 "$runs"); do
    if [[ $app == kit ]]; then
      ssh "$HOST" "xcrun simctl terminate $U dev.cmux.tabskit.demo >/dev/null 2>&1; xcrun simctl launch $U dev.cmux.tabskit.demo >/dev/null"
      sleep 4                                            # launch (test script only)
    else
      "$R" launch --slot "$slot" --scheme Tabs --env CMUX_NEXT_DEV_SCREEN=tabs-combined --env CMUX_NEXT_TABS_RESET_PINS=1 >/dev/null
      sleep 6                                            # launch and mock connect (test script only)
    fi
    case "$m" in
      zoomOut|swipeUp|tapZoomOut) ;;
      *) axe tap -x 344 -y 816; sleep 1.5 ;;               # open the grid
    esac
    if [[ $m == lastTab ]]; then
      # Down to cmux alone: close top, zsh, Hacker News and GitHub.
      axe tap -x 178 -y 714; sleep 1.2; axe tap -x 371 -y 426; sleep 1.2; axe tap -x 178 -y 426; sleep 1.2; axe tap -x 371 -y 137; sleep 1.5
    fi
    if [[ $m == twoToOne ]]; then
      # Down to cmux and GitHub: close top, zsh and Hacker News.
      axe tap -x 178 -y 714; sleep 1.2; axe tap -x 371 -y 426; sleep 1.2; axe tap -x 178 -y 426; sleep 1.5
    fi
    case "$m" in
      reflow)   g="tap -x 178 -y 137" ;;
      zoomOut)  g="tap -x 344 -y 816" ;;
      zoomIn)   g="tap -x 297 -y 250" ;;
      swipeUp)  g="swipe --start-x 200 --start-y 816 --end-x 200 --end-y 566 --duration 0.25" ;;
      snapBack|drag) g="drag --start-x 330 --start-y 250 --end-x 230 --end-y 250 --duration 1.0 --steps 60" ;;
      fling)    g="swipe --start-x 330 --start-y 250 --end-x 230 --end-y 250 --duration 0.12" ;;
      twoToOne) g="tap -x 178 -y 137" ;;
      lastTab)  g="tap -x 320 -y 137" ;;
      # Tabs, then GitHub's card inside the zoom-out (one AXe session: a
      # second process starts about 230 ms later, after the zoom-out). The
      # zoom-out starts 250-370 ms after the first tap, so 0.3 s lands the
      # second tap in it; when the card opens does not depend on it.
      tapZoomOut)
        ssh "$HOST" "printf 'tap -x 344 -y 816\\nsleep 0.3\\ntap -x 297 -y 250\\n' > /tmp/tc-tapzoomout.steps"
        g="batch --file /tmp/tc-tapzoomout.steps" ;;
    esac
    name="$m"
    if [[ $app == kit ]]; then
      name="kit-$m"
      # The kit's active card (Springs) is the left one in row 1.
      case "$m" in
        zoomIn)   g="tap -x 104 -y 250" ;;
        snapBack) g="drag --start-x 140 --start-y 250 --end-x 40 --end-y 250 --duration 1.0 --steps 60" ;;
      esac
    fi
    ssh "$HOST" "rm -f /tmp/tc.mp4; (xcrun simctl io $U recordVideo --codec=h264 --force /tmp/tc.mp4 >/dev/null 2>&1 & echo \$! > /tmp/tc.pid); sleep 1.5; (axe $g --udid $U || ~/nx-ios/axe/axe $g --udid $U) >/dev/null 2>&1; sleep 1.8; kill -INT \$(cat /tmp/tc.pid); while kill -0 \$(cat /tmp/tc.pid) 2>/dev/null; do sleep 0.2; done"
    rm -f "$OUT/$name-$i.mp4"
    if ! scp -q "$HOST:/tmp/tc.mp4" "$OUT/$name-$i.mp4"; then
      # No recording (another simctl recording holds the simulator): fail,
      # never re-check an older video.
      printf 'run %d %s: no recording  FAIL\n' "$i" "$name"; fail=1; continue
    fi
    printf 'run %d ' "$i"; python3 "$HERE/check.py" "$name" "$OUT/$name-$i.mp4" || fail=1
  done
done
exit $fail
