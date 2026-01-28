#!/usr/bin/env bash
set -euo pipefail

pkill -x cmux || true
sleep 0.2
open /Users/lawrencechen/Library/Developer/Xcode/DerivedData/GhosttyTabs-cbjivvtpirygxbbgqlpdpiiyjnwh/Build/Products/Release/cmux.app
