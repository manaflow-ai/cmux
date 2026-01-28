#!/usr/bin/env bash
set -euo pipefail

xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' build
pkill -x "cmuxterm DEV" || true
sleep 0.2
open /Users/lawrencechen/Library/Developer/Xcode/DerivedData/GhosttyTabs-cbjivvtpirygxbbgqlpdpiiyjnwh/Build/Products/Debug/cmuxterm\ DEV.app
