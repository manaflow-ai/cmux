#!/usr/bin/env bash
set -euo pipefail

APP_PATH="/Users/lawrencechen/Library/Developer/Xcode/DerivedData/GhosttyTabs-cbjivvtpirygxbbgqlpdpiiyjnwh/Build/Products/Debug/cmuxterm DEV.app"

xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' build
pkill -x "cmuxterm DEV" || true
sleep 0.2
open "$APP_PATH"
osascript -e 'tell application "cmuxterm DEV" to activate' || true
