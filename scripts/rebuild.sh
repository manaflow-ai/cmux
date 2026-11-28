#!/bin/bash
# Rebuild and restart GhosttyTabs app

set -e

cd "$(dirname "$0")/.."

# Kill existing app if running
pkill -9 -f "GhosttyTabs" 2>/dev/null || true

# Build
swift build

# Copy to app bundle
cp .build/debug/GhosttyTabs .build/debug/GhosttyTabs.app/Contents/MacOS/

# Open the app
open .build/debug/GhosttyTabs.app
