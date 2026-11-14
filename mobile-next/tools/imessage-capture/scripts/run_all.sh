#!/bin/bash
# Full capture pass. Run on the capture Mac after creating/booting the simulator
# (UDID in $ROOT/udid) and running build-for-testing.
set -u
ROOT="${CNM_ROOT:-$HOME/cnm/imessage}"
U="$(cat "$ROOT/udid")"
S="$(dirname "$0")/run_scenario.sh"
xcb() { (cd "$ROOT/proj" && xcodebuild -project IMsgCapture.xcodeproj -scheme IMsgUITests -destination "id=$U" \
  -derivedDataPath "$ROOT/dd" test-without-building -only-testing:"IMsgUITests/$1" > "$ROOT/logs/${1//\//_}.log" 2>&1; echo "$1 rc=$?"); }
mkdir -p "$ROOT/logs"
xcrun simctl ui "$U" appearance light
xcrun simctl status_bar "$U" override --time 9:41 --batteryLevel 100 --batteryState discharging --cellularBars 4 --wifiBars 3 --dataNetwork wifi --operatorName ""
"$S" testS0Launch s0-launch
xcb Seed/testSeedConversation
"$S" testS1List s1-list
"$S" testS2PushPop s2-push-pop
"$S" testS3Composer s3-composer
"$S" testS3bTimestampHold s3b-timestamp-hold
"$S" testS4Tapback s4-tapback
"$S" testS5KeyboardDismiss s5-keyboard-dismiss
"$S" testS6Scroll s6-scroll
"$S" testS7Stills s7-light TEST_RUNNER_CNM_MODE=light
xcrun simctl ui "$U" appearance dark
"$S" testS7Stills s7-dark TEST_RUNNER_CNM_MODE=dark
"$S" testS2PushPop s2-push-pop-dark
xcrun simctl ui "$U" appearance light
"$S" testS8Pin s8-pin
"$S" testS1bUnpin s1b-unpin
