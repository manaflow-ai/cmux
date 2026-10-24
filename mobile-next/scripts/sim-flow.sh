#!/usr/bin/env bash
# Runs on the build mini: build for testing once, then run the named UI test
# methods on our own simulator while recording the screen.
#   sim-flow.sh <sim-name> <out-dir> <TestMethod>...
set -euo pipefail
cd "$(dirname "$0")/../ios"
SIM_NAME="$1"; OUT="$2"; shift 2
mkdir -p "$OUT"
UDID=$(xcrun simctl list devices | awk -v n="$SIM_NAME" -F'[()]' '$0 ~ "    "n" " {print $2; exit}')
if [[ -z "$UDID" ]]; then
  UDID=$(xcrun simctl create "$SIM_NAME" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-26-5)
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true
xcodegen generate --quiet
xcodebuild -project CmuxNextMobile.xcodeproj -scheme CmuxNext -destination "id=$UDID" -derivedDataPath "$HOME/cnm/dd-test" \
  -skipPackagePluginValidation CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=YES build-for-testing 2>&1 | grep -E 'error:|TEST BUILD|BUILD (SUCCEEDED|FAILED)' | sort -u
for test in "$@"; do
  rm -rf "$OUT/$test.xcresult"
  xcrun simctl io "$UDID" recordVideo --codec h264 --force "$OUT/$test.mp4" > /dev/null 2>&1 &
  REC=$!
  sleep 1
  TEST_RUNNER_CNM_TEST_EMAIL="${CNM_TEST_EMAIL:-}" TEST_RUNNER_CNM_TEST_CODE="${CNM_TEST_CODE:-}" TEST_RUNNER_CNM_PAIR_CODE="${CNM_PAIR_CODE:-}" \
  xcodebuild -project CmuxNextMobile.xcodeproj -scheme CmuxNext -destination "id=$UDID" -derivedDataPath "$HOME/cnm/dd-test" \
    -resultBundlePath "$OUT/$test.xcresult" -only-testing:"CmuxNextUITests/FlowTests/$test" test-without-building 2>&1 \
    | grep -E "Test Case|error|failed|passed" | head -20 || true
  kill -INT $REC; wait $REC 2>/dev/null || true
  mkdir -p "$OUT/$test-shots"
  xcrun xcresulttool export attachments --path "$OUT/$test.xcresult" --output-path "$OUT/$test-shots" >/dev/null 2>&1 || true
done
echo "UDID=$UDID"
