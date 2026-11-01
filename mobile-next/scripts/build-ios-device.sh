#!/usr/bin/env bash
# Runs on the build mini: an unsigned device build of the app.
set -euo pipefail
cd "$(dirname "$0")/../ios"
xcodegen generate --quiet
xcodebuild -project CmuxNextMobile.xcodeproj -scheme CmuxNext -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$HOME/cnm/dd-device" \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build 2>&1 \
  | grep -E 'error:|BUILD (SUCCEEDED|FAILED)' | sort -u
APP="$HOME/cnm/dd-device/Build/Products/Release-iphoneos/CmuxNext.app"
rm -rf "$HOME/cnm/out" && mkdir -p "$HOME/cnm/out"
ditto -c -k --keepParent "$APP" "$HOME/cnm/out/CmuxNext-unsigned.zip"
echo "OUT=$HOME/cnm/out/CmuxNext-unsigned.zip"
