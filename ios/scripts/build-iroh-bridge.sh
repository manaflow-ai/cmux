#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/.." && pwd)"
CMUX_CLI_DIR="$REPO_ROOT/rust/cmux-cli"

if [ -z "${DERIVED_FILE_DIR:-}" ]; then
    echo "DERIVED_FILE_DIR is required" >&2
    exit 1
fi

PLATFORM="${PLATFORM_NAME:-}"
ARCH="${CURRENT_ARCH:-${NATIVE_ARCH_ACTUAL:-}}"
if [ -z "$ARCH" ] || [ "$ARCH" = "undefined_arch" ]; then
    ARCH="${ARCHS%% *}"
fi
if [ -z "$ARCH" ]; then
    ARCH="$(uname -m)"
fi
case "$PLATFORM" in
    iphoneos)
        TARGET="aarch64-apple-ios"
        ;;
    iphonesimulator)
        case "$ARCH" in
            arm64|aarch64|"")
                TARGET="aarch64-apple-ios-sim"
                ;;
            x86_64)
                TARGET="x86_64-apple-ios"
                ;;
            *)
                echo "Unsupported iOS simulator arch: $ARCH" >&2
                exit 1
                ;;
        esac
        ;;
    *)
        echo "Unsupported platform for cmux iroh bridge: ${PLATFORM:-unknown}" >&2
        exit 1
        ;;
esac

if ! rustup target list --installed | grep -qx "$TARGET"; then
    echo "Rust target $TARGET is not installed" >&2
    exit 1
fi

DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-26.0}"
export IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
case "$PLATFORM" in
    iphoneos)
        MIN_VERSION_FLAG="-miphoneos-version-min=$DEPLOYMENT_TARGET"
        ;;
    iphonesimulator)
        MIN_VERSION_FLAG="-mios-simulator-version-min=$DEPLOYMENT_TARGET"
        ;;
esac
export CFLAGS="$MIN_VERSION_FLAG ${CFLAGS:-}"
export CFLAGS_aarch64_apple_ios="$MIN_VERSION_FLAG ${CFLAGS_aarch64_apple_ios:-}"
export CFLAGS_aarch64_apple_ios_sim="$MIN_VERSION_FLAG ${CFLAGS_aarch64_apple_ios_sim:-}"

PROFILE="debug"
CARGO_ARGS=(build -p cmux-iroh-bridge --lib --target "$TARGET")
if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
    PROFILE="release"
    CARGO_ARGS+=(--release)
fi

cd "$CMUX_CLI_DIR"
cargo "${CARGO_ARGS[@]}"

mkdir -p "$DERIVED_FILE_DIR"
cp "$CMUX_CLI_DIR/target/$TARGET/$PROFILE/libcmux_iroh_bridge.a" "$DERIVED_FILE_DIR/libcmux_iroh_bridge.a"
