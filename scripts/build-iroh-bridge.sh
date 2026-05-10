#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CMUX_CLI_DIR="$REPO_ROOT/rust/cmux-cli"

if [ -z "${DERIVED_FILE_DIR:-}" ]; then
    echo "DERIVED_FILE_DIR is required" >&2
    exit 1
fi

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

host_target="$(rustc -vV | awk '/^host:/ { print $2 }')"

target_for_arch() {
    case "$1" in
        arm64|aarch64)
            echo "aarch64-apple-darwin"
            ;;
        x86_64)
            echo "x86_64-apple-darwin"
            ;;
        *)
            echo "Unsupported macOS arch: $1" >&2
            exit 1
            ;;
    esac
}

archs="${ARCHS:-}"
if [ -z "$archs" ] || [ "$archs" = "undefined_arch" ]; then
    arch="${CURRENT_ARCH:-${NATIVE_ARCH_ACTUAL:-}}"
    if [ -z "$arch" ] || [ "$arch" = "undefined_arch" ]; then
        arch="$(uname -m)"
    fi
    archs="$arch"
fi

profile="debug"
if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
    profile="release"
fi

mkdir -p "$DERIVED_FILE_DIR"
libs=()
for arch in $archs; do
    target="$(target_for_arch "$arch")"
    if [ "$target" != "$host_target" ] && ! rustup target list --installed | grep -qx "$target"; then
        echo "Rust target $target is not installed" >&2
        exit 1
    fi
    (
        cd "$CMUX_CLI_DIR"
        if [ "$profile" = "release" ]; then
            cargo build -p cmux-iroh-bridge --lib --target "$target" --release
        else
            cargo build -p cmux-iroh-bridge --lib --target "$target"
        fi
    )
    libs+=("$CMUX_CLI_DIR/target/$target/$profile/libcmux_iroh_bridge.a")
done

if [ "${#libs[@]}" -eq 1 ]; then
    cp "${libs[0]}" "$DERIVED_FILE_DIR/libcmux_iroh_bridge.a"
else
    lipo -create "${libs[@]}" -output "$DERIVED_FILE_DIR/libcmux_iroh_bridge.a"
fi
