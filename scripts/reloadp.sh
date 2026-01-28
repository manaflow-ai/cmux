#!/usr/bin/env bash
set -euo pipefail

xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Release -destination 'platform=macOS' build
pkill -x cmuxterm || true
sleep 0.2
open /Users/lawrencechen/Library/Developer/Xcode/DerivedData/GhosttyTabs-cbjivvtpirygxbbgqlpdpiiyjnwh/Build/Products/Release/cmuxterm.app
