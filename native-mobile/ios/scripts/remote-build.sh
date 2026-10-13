#!/usr/bin/env bash
# remote-build.sh [sim|device|test] — sync native-mobile to the build Mac and build there.
# The laptop has no Xcode; the build Mac (default: cmux mini mini-cmux12s-mac-mini, Xcode 26.6) does.
# Concurrent agents: set CMUX_NATIVE_REMOTE_DIR and CMUX_NATIVE_DD to private paths.
set -euo pipefail
HOST="${CMUX_NATIVE_BUILD_HOST:-mini-cmux12s-mac-mini}"
MODE="${1:-sim}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
REMOTE="${CMUX_NATIVE_REMOTE_DIR:-cmux-native-aziz/work}"
DD="${CMUX_NATIVE_DD:-~/cmux-native-aziz/dd-ios}"
cd "$ROOT/native-mobile/ios" && xcodegen generate --quiet
rsync -az --delete --exclude .build --exclude 'node_modules' --exclude '*.xcuserstate' \
  "$ROOT/native-mobile/" "$HOST:$REMOTE/native-mobile/"
rsync -az --delete "$ROOT/Packages/Shared/CmuxGhosttyKit/" "$HOST:$REMOTE/Packages/Shared/CmuxGhosttyKit/"
SIM="name=${CMUX_NATIVE_SIM:-iPhone 17 Pro}"
[ -n "${CMUX_NATIVE_SIM_ID:-}" ] && SIM="id=$CMUX_NATIVE_SIM_ID"
case "$MODE" in
  sim) DEST='generic/platform=iOS Simulator'; ACTION=build; EXTRA=(CODE_SIGNING_ALLOWED=NO ARCHS=arm64) ;;
  device) DEST='generic/platform=iOS'; ACTION=build; EXTRA=(-allowProvisioningUpdates) ;;
  test) DEST="platform=iOS Simulator,$SIM"; ACTION=test; EXTRA=(CODE_SIGNING_ALLOWED=NO ARCHS=arm64) ;;
esac
ssh "$HOST" "cd $REMOTE/native-mobile/ios && xcodebuild -project CmuxNative.xcodeproj -scheme CmuxNative \
  -destination '$DEST' -derivedDataPath $DD ${EXTRA[*]} $ACTION 2>&1 \
  | grep -E 'error:|warning: .*(Sources|App)/|BUILD SUCCEEDED|BUILD FAILED|TEST SUCCEEDED|TEST FAILED|Test Case.*failed' | grep -v 'appintentsmetadataprocessor' | sort -u | head -${CMUX_NATIVE_LINES:-80}"
