#!/usr/bin/env bash
# scroll-ab.sh <scrollSync mode 0-3> <out dir>: launch the app on the build Mac's simulator with
# terminal.scrollSync=<mode>, record three flings over the open terminal, pull the video, split it
# into real frames (variable frame rate kept), then score it with scroll-reversals.py.
# Fill the terminal with rows of varied length first (identical rows alias the correlation).
set -euo pipefail
MODE=$1; OUT=$2
HOST="${CMUX_NATIVE_BUILD_HOST:-mini-cmux12s-mac-mini}"
SIM="${CMUX_NATIVE_SIM_ID:?set CMUX_NATIVE_SIM_ID}"
AXE="${CMUX_NATIVE_AXE:-~/cmux-native-aziz/axe/axe}"
ssh "$HOST" "U=$SIM; A=$AXE; xcrun simctl launch --terminate-running-process \$U dev.cmux.next.native.dev -push.prePromptAnswered YES -terminal.scrollSync $MODE >/dev/null
  for i in \$(seq 1 60); do \$A describe-ui --udid \$U 2>/dev/null | grep -q composer.text && break; [ \$i = 60 ] && { echo 'no terminal open after 60s' >&2; exit 1; }; sleep 1; done
  rm -f /tmp/cmux-native-ab.mp4; xcrun simctl io \$U recordVideo --codec h264 --force /tmp/cmux-native-ab.mp4 >/dev/null 2>&1 & R=\$!; sleep 2
  \$A swipe --start-x 200 --start-y 250 --end-x 200 --end-y 650 --duration 0.25 --udid \$U >/dev/null; sleep 1.5
  \$A swipe --start-x 200 --start-y 300 --end-x 200 --end-y 500 --duration 0.6 --udid \$U >/dev/null; sleep 1.5
  \$A swipe --start-x 200 --start-y 650 --end-x 200 --end-y 250 --duration 0.2 --udid \$U >/dev/null; sleep 2.5
  kill -INT \$R; wait \$R 2>/dev/null || true"
rm -rf "$OUT"; mkdir -p "$OUT"
scp -q "$HOST:/tmp/cmux-native-ab.mp4" "$OUT/v.mp4"
ffmpeg -v quiet -i "$OUT/v.mp4" -fps_mode passthrough -vf "crop=600:1700:20:450,scale=300:850,format=gray" "$OUT/f_%04d.png"
python3 "$(dirname "$0")/scroll-reversals.py" "$OUT"
