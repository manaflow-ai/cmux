#!/usr/bin/env bash
# Runs the DEBUG ACP parity demo driver (`-CnxDemo acp-parity`: Feed swipe
# actions, artifacts browser, subagents, checkpoints, handoff) on a headless
# simulator with mock auth, records it and splits frames.
# Usage: verify/record-acp.sh <sim-udid> <label> <dark|light> [seconds] [phases]
# Expects a Debug simulator build (APP=<path to CnxApp.app>, default
# /tmp/cnx-acp/dd/Build/Products/Debug-iphonesimulator/CnxApp.app).
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
UDID=$1; LABEL=$2; APPEARANCE=$3; SECONDS_TO_RECORD=${4:-110}; PHASES=${5:-swipe,artifacts,subagents,checkpoints,handoff}
APP=${APP:-/tmp/cnx-acp/dd/Build/Products/Debug-iphonesimulator/CnxApp.app}
OUT="$ROOT/verify/evidence/$(date +%Y-%m-%d)/acp/$LABEL-$APPEARANCE"
rm -rf "$OUT"; mkdir -p "$OUT/frames"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance "$APPEARANCE"
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
xcrun simctl terminate "$UDID" dev.cmux.cnx >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
# Past onboarding (the simulator's app defaults, as verify/record-ws.sh does).
xcrun simctl spawn "$UDID" defaults write dev.cmux.cnx cnx.setupComplete -bool true
xcrun simctl io "$UDID" recordVideo --codec h264 --force "$OUT/demo.mp4" &
REC=$!
until ls "$OUT"/demo.mp4.sb-* >/dev/null 2>&1 || [[ -s "$OUT/demo.mp4" ]]; do sleep 0.2; done; sleep 1
SIMCTL_CHILD_CNX_MOCK_AUTH=1 xcrun simctl launch --console-pty "$UDID" dev.cmux.cnx -CnxDemo acp-parity -CnxDemoPhases "$PHASES" \
  > "$OUT/console.log" 2>&1 &
LAUNCH=$!
sleep "$SECONDS_TO_RECORD"
kill -INT $REC; wait $REC || true
kill $LAUNCH 2>/dev/null || true
ffmpeg -loglevel error -y -i "$OUT/demo.mp4" -vf fps=2,scale=402:-1 "$OUT/frames/f%04d.png"
echo "$OUT"
