#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/Tools/CmuxAndroidBridge"
INSTALL_DIR="${CMUX_ANDROID_BRIDGE_INSTALL_DIR:-$HOME/.local/bin}"
DESTINATION="$INSTALL_DIR/cmux-android-bridge"

swift build --package-path "$PACKAGE_DIR" -c release
BINARY_PATH="$(swift build --package-path "$PACKAGE_DIR" -c release --show-bin-path)/cmux-android-bridge"

mkdir -p "$INSTALL_DIR"
install -m 755 "$BINARY_PATH" "$DESTINATION"
strip -x "$DESTINATION"

echo "Installed cmux Android bridge at $DESTINATION"
