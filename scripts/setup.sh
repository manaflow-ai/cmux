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

echo "==> Checking for Rust..."
# Xcode uses a non-login shell, so verify the same PATH used by the sidecar
# build phase rather than relying on the caller's interactive shell setup.
export PATH="${CARGO_HOME:-${HOME}/.cargo}/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
if ! command -v cargo &> /dev/null || ! command -v rustc &> /dev/null; then
    echo "Error: Rust is not installed."
    echo "Install via: https://rustup.rs"
    exit 1
fi
cargo --version
rustc --version
rust_version="$(rustc --version | awk '{print $2}')"
rust_release="${rust_version%%-*}"
rust_major="${rust_release%%.*}"
rust_remainder="${rust_release#*.}"
rust_minor="${rust_remainder%%.*}"
if ! [[ "$rust_major" =~ ^[0-9]+$ && "$rust_minor" =~ ^[0-9]+$ ]] \
   || (( rust_major < 1 || (rust_major == 1 && rust_minor < 88) )); then
    echo "Error: cmux requires Rust 1.88 or newer (found ${rust_version})."
    echo "Update via: rustup update stable"
    exit 1
fi

"$SCRIPT_DIR/ensure-ghosttykit.sh"

"$SCRIPT_DIR/install-git-hooks.sh"

echo "==> Setup complete!"
echo ""
echo "You can now build and run the app:"
echo "  ./scripts/reload.sh --tag first-run"
