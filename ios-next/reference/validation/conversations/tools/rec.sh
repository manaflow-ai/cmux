#!/usr/bin/env bash
# rec.sh NAME POST_SECONDS 'remote axe script (use $U for udid)'  -> /tmp/nxios/conv/vid/NAME.mp4
# relaunch.sh semantics: if RELAUNCH=1, restart the app first.
set -euo pipefail
HOST=aziz-other-macbook; R=nx-ios/conv
name=$1; post=$2; script=$3
mkdir -p /tmp/nxios/conv/vid
ssh "$HOST" "bash -lc $(printf '%q' "
U=\$(cat ~/$R/sim.udid)
if [ \"${RELAUNCH:-0}\" = 1 ]; then
  xcrun simctl terminate \$U dev.cmux.next.drawer 2>/dev/null || true
  SIMCTL_CHILD_CMUX_CONV_TRACE=1 SIMCTL_CHILD_CMUX_NEXT_DEV_SCREEN=conversations xcrun simctl launch \$U dev.cmux.next.drawer >/dev/null
  sleep 3
fi
${PRE:-}
rm -f ~/$R/$name.mp4 ~/$R/$name.log
xcrun simctl io \$U recordVideo --codec=h264 --force ~/$R/$name.mp4 > ~/$R/$name.log 2>&1 &
p=\$!
until grep -q 'Recording started' ~/$R/$name.log; do sleep 0.1; done
sleep 0.8
$script
sleep $post
kill -INT \$p; wait \$p 2>/dev/null || true
")"
scp -q "$HOST:$R/$name.mp4" /tmp/nxios/conv/vid/$name.mp4 && echo /tmp/nxios/conv/vid/$name.mp4
