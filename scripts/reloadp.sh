#!/usr/bin/env bash
set -euo pipefail

APP_PATH="/Users/lawrencechen/Library/Developer/Xcode/DerivedData/GhosttyTabs-cbjivvtpirygxbbgqlpdpiiyjnwh/Build/Products/Release/cmuxterm.app"

xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Release -destination 'platform=macOS' build
pkill -x cmuxterm || true
sleep 0.2
open "$APP_PATH"
osascript -e 'tell application "cmuxterm" to activate' || true
