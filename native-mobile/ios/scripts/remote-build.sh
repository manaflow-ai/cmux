#!/usr/bin/env bash
# remote-build.sh [sim|device|test] — sync native-mobile to the build Mac and build there.
# The laptop has no Xcode; the build Mac (default: aziz-other-macbook, Xcode 27) does.
set -euo pipefail
HOST="${CMUX_NATIVE_BUILD_HOST:-aziz-other-macbook}"
MODE="${1:-sim}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
REMOTE=cmux-native/work
cd "$ROOT/native-mobile/ios" && xcodegen generate --quiet
rsync -az --delete --exclude .build --exclude 'node_modules' --exclude '*.xcuserstate' \
  "$ROOT/native-mobile/" "$HOST:$REMOTE/native-mobile/"
rsync -az --delete "$ROOT/Packages/Shared/CmuxGhosttyKit/" "$HOST:$REMOTE/Packages/Shared/CmuxGhosttyKit/"
case "$MODE" in
  sim) DEST='generic/platform=iOS Simulator'; ACTION=build; EXTRA=(CODE_SIGNING_ALLOWED=NO ARCHS=arm64) ;;
  device) DEST='generic/platform=iOS'; ACTION=build; EXTRA=(-allowProvisioningUpdates) ;;
  test) DEST="platform=iOS Simulator,name=${CMUX_NATIVE_SIM:-iPhone 17 Pro}"; ACTION=test; EXTRA=(CODE_SIGNING_ALLOWED=NO ARCHS=arm64) ;;
esac
ssh "$HOST" "cd $REMOTE/native-mobile/ios && xcodebuild -project CmuxNative.xcodeproj -scheme CmuxNative \
  -destination '$DEST' -derivedDataPath ~/cmux-native/dd-ios ${EXTRA[*]} $ACTION 2>&1 \
  | grep -E 'error:|warning: .*(Sources|App)/|BUILD SUCCEEDED|BUILD FAILED|TEST SUCCEEDED|TEST FAILED|Test Case.*failed' | grep -v 'appintentsmetadataprocessor' | sort -u | head -${CMUX_NATIVE_LINES:-80}"
