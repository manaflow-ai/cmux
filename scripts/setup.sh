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
if ! command -v rustup &> /dev/null; then
    echo "Error: Rust is not installed."
    echo "Install via: https://rustup.rs"
    exit 1
fi
DIFF_RUST_TOOLCHAIN="$(awk -F '"' '/^[[:space:]]*channel[[:space:]]*=/{print $2; exit}' Native/DiffSidecar/rust-toolchain.toml)"
rustup toolchain install "$DIFF_RUST_TOOLCHAIN" --profile minimal --component clippy,rustfmt
rustup target add --toolchain "$DIFF_RUST_TOOLCHAIN" aarch64-apple-darwin x86_64-apple-darwin
rustup run "$DIFF_RUST_TOOLCHAIN" cargo --version
rustup run "$DIFF_RUST_TOOLCHAIN" rustc --version

# Every app build also runs scripts/build-cua-driver.sh, which compiles the
# bundled computer-use driver with Cargo (default toolchain). Verify a working
# cargo is on PATH so the first tagged reload does not fail mid-build.
echo "==> Checking for cargo (bundled cua-driver)..."
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
