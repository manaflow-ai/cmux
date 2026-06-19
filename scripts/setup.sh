#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "==> Initializing submodules..."
git submodule update --init --recursive

echo "==> Checking for zig..."
if ! command -v zig &> /dev/null; then
    echo "Error: zig is not installed."
    echo "Install via: brew install zig"
    exit 1
fi

echo "==> Checking for Xcode..."
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "Error: full Xcode is required, but xcodebuild is not available from an Xcode developer directory."
    echo "Install Xcode 15+ from the App Store, then run:"
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
fi

"$SCRIPT_DIR/ensure-ghosttykit.sh"

"$SCRIPT_DIR/install-git-hooks.sh"

echo "==> Setup complete!"
echo ""
echo "You can now build and run the app:"
echo "  ./scripts/reload.sh --tag first-run"
