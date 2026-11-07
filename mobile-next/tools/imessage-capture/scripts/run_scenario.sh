#!/bin/bash
# Run one UI-test scenario against the Messages app while recording the simulator screen.
# Usage: run_scenario.sh <TestName> <out-basename> [extra env KEY=VAL ...]
# Expects: $ROOT/udid (simulator UDID), project built with build-for-testing into $ROOT/dd.
set -u
ROOT="${CNM_ROOT:-$HOME/cnm/imessage}"
U="$(cat "$ROOT/udid")"
TEST="$1"; NAME="$2"; shift 2
mkdir -p "$ROOT/videos" "$ROOT/logs" "$ROOT/stills"
VID="$ROOT/videos/$NAME.mp4"
xcrun simctl io "$U" recordVideo --codec h264 --force "$VID" > "$ROOT/logs/$NAME.rec.log" 2>&1 &
REC=$!
# recordVideo prints "Recording started" once frames flow.
until grep -q "Recording started" "$ROOT/logs/$NAME.rec.log" 2>/dev/null; do
  kill -0 $REC 2>/dev/null || { echo "recorder died"; cat "$ROOT/logs/$NAME.rec.log"; exit 1; }
  sleep 0.2
done
date +%s.%N > "$ROOT/logs/$NAME.rec.start"
cd "$ROOT/proj"
env "$@" TEST_RUNNER_CNM_STILLS="$ROOT/stills" xcodebuild -project IMsgCapture.xcodeproj -scheme IMsgUITests \
  -destination "id=$U" -derivedDataPath "$ROOT/dd" test-without-building \
  -only-testing:"IMsgUITests/Scenarios/$TEST" > "$ROOT/logs/$NAME.xcb.log" 2>&1
RC=$?
kill -INT $REC; wait $REC
echo "$NAME rc=$RC $(grep -c CNM-MARK "$ROOT/logs/$NAME.xcb.log") marks"
grep -E "error:|XCTAssert|failed" "$ROOT/logs/$NAME.xcb.log" | grep -v "CA Event" | head -5
