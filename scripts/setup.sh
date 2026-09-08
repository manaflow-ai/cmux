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
# shellcheck source=/dev/null
source "$SCRIPT_DIR/ghostty-zig-version.sh"
ZIG_REQUIRED="$(ghostty_minimum_zig_version "$PROJECT_DIR")"
ZIG_ACTUAL="$(zig version)"
if ! ghostty_zig_version_is_compatible "$ZIG_ACTUAL" "$ZIG_REQUIRED"; then
    echo "Error: Ghostty requires zig ${ZIG_REQUIRED} or a newer patch release in the same major/minor series, but $(command -v zig) reports ${ZIG_ACTUAL}."
    echo "Install or upgrade via: brew install zig"
    exit 1
fi
echo "zig ${ZIG_ACTUAL} found at $(command -v zig)"

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

# Every app build also runs scripts/build-cmux-cua.sh, which compiles the
# bundled cmux-cua engine with Cargo (default toolchain). Verify a working
# cargo is on PATH so the first tagged reload does not fail mid-build.
echo "==> Checking for cargo (bundled cmux-cua)..."
if ! command -v cargo &> /dev/null || ! cargo --version &> /dev/null; then
    echo "Error: a working Rust toolchain (cargo) is required to build the bundled cmux-cua."
    echo "Install via rustup: https://rustup.rs"
    echo "(Homebrew's rustup is keg-only and ships no rustup-init: add"
    echo " \"\$(brew --prefix rustup)/bin\" to PATH, then run \`rustup default stable\`.)"
    exit 1
fi

# Xcode 26 ships the Metal compiler as a separately downloaded component rather
# than inside Xcode.app. Without it the app target fails partway through the
# build ("cannot execute tool 'metal' due to missing Metal Toolchain"), after
# the Swift modules have already compiled. Fail here instead, where the fix is
# one command. Older Xcode bundles metal, so this check simply passes there.
# The Command Line Tools do not ship metal at all, so the message names both
# causes rather than assuming the component is merely missing.
echo "==> Checking for the Metal toolchain..."
if ! xcrun metal --version &> /dev/null; then
    echo "Error: the Metal compiler is not available."
    echo "Active developer directory: $(xcode-select -p 2>/dev/null || echo 'unset')"
    echo "If that is a full Xcode, install the toolchain component:"
    echo "    xcodebuild -downloadComponent MetalToolchain"
    echo "If it is the Command Line Tools, select Xcode first:"
    echo "    sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
    exit 1
fi

# The Cloud tunnel system extension embeds wireguard-go, built by
# scripts/build-wireguard-go.sh. Release builds require Go; a Debug build
# without it gets a stub engine (the extension cannot load in a Debug build
# anyway), so this is advisory rather than fatal.
echo "==> Checking for Go (Cloud tunnel extension)..."
export PATH="/usr/local/go/bin:${HOME}/go/bin:${PATH}"
if command -v go &> /dev/null; then
    go version
else
    echo "Note: go is not installed; Debug builds will use a stub WireGuard engine."
    echo "Install via: brew install go (required for Release builds)"
fi

"$SCRIPT_DIR/ensure-ghosttykit.sh"

"$SCRIPT_DIR/install-git-hooks.sh"

echo "==> Setup complete!"
echo ""
echo "You can now build and run the app:"
echo "  ./scripts/reload.sh --tag first-run"
