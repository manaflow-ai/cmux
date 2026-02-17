#!/bin/bash
set -e

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

echo "==> Building GhosttyKit.xcframework (this may take a few minutes)..."
cd ghostty
zig build -Demit-xcframework=true -Doptimize=ReleaseFast
cd "$PROJECT_DIR"

echo "==> Creating symlink for GhosttyKit.xcframework..."
ln -sf ghostty/macos/GhosttyKit.xcframework GhosttyKit.xcframework

echo "==> Setup complete!"
echo ""
echo "You can now build and run the app:"
echo "  ./scripts/reload.sh --tag first-run"
