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

echo "==> Checking for bun..."
if ! command -v bun &> /dev/null; then
    echo "Error: bun is not installed."
    echo "Install via: brew install oven-sh/bun/bun"
    exit 1
fi

# Every app build runs scripts/build-cua-driver.sh, which compiles the bundled
# computer-use driver with Cargo. Catch a missing/broken Rust toolchain here so
# the first tagged reload does not fail mid-build. Check only; never auto-install.
echo "==> Checking for Rust (cargo)..."
if ! command -v cargo &> /dev/null || ! cargo --version &> /dev/null; then
    echo "Error: a working Rust toolchain (cargo) is required to build the bundled cua-driver."
    echo "Install via rustup: https://rustup.rs (or \`brew install rustup && rustup-init\`)"
    exit 1
fi

"$SCRIPT_DIR/ensure-ghosttykit.sh"

"$SCRIPT_DIR/install-git-hooks.sh"

echo "==> Setup complete!"
echo ""
echo "You can now build and run the app:"
echo "  ./scripts/reload.sh --tag first-run"
