#!/bin/bash
# Rebuild and restart cmux app

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/cmux-paths.sh"
cmux_paths_init "${BASH_SOURCE[0]}"

cd "$CMUX_REPO_ROOT"

# Kill existing app if running
pkill -9 -f "cmux" 2>/dev/null || true

# Build
swift build

# Copy to app bundle
cp .build/debug/cmux .build/debug/cmux.app/Contents/MacOS/

# Open the app
open .build/debug/cmux.app
