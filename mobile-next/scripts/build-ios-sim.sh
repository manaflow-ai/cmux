#!/usr/bin/env bash
# Runs on the build mini: generate the project and build the simulator app.
set -euo pipefail
cd "$(dirname "$0")/../ios"
xcodegen generate --quiet
xcodebuild -project CmuxNextMobile.xcodeproj -scheme CmuxNext \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$HOME/cnm/dd" \
  -skipPackagePluginValidation CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=YES build 2>&1 \
  | grep -E 'error:|warning: .*(deprecated|unused)|BUILD (SUCCEEDED|FAILED)' | sort -u | head -80
