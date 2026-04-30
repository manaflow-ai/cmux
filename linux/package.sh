#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DIST_DIR="$ROOT_DIR/dist"
PACKAGE_NAME="cmux-linux-x86_64"
STAGING_DIR="$DIST_DIR/$PACKAGE_NAME"
ARCHIVE_PATH="$DIST_DIR/$PACKAGE_NAME.tar.gz"
PYTHON_BIN="${CMUX_PYTHON:-python3}"
PACKAGE_PYCACHE_PREFIX="${CMUX_PYTHONPYCACHEPREFIX:-${PYTHONPYCACHEPREFIX:-$DIST_DIR/.pycache}}"
CLI_BINARY_PATH="${CMUX_LINUX_CLI_BINARY:-$ROOT_DIR/CLI/.build/release/cmux}"
REMOTE_DAEMON_BINARY_PATH="${CMUX_LINUX_REMOTE_DAEMON_BINARY:-$ROOT_DIR/daemon/remote/cmuxd-remote}"

rm -rf "$STAGING_DIR" "$ARCHIVE_PATH"
mkdir -p "$STAGING_DIR/bin" "$STAGING_DIR/lib" "$STAGING_DIR/share/applications"

cp "$ROOT_DIR/linux/bin/cmux-linux" "$STAGING_DIR/bin/cmux-linux"
SWIFT_CLI_INCLUDED=0
if [ -f "$CLI_BINARY_PATH" ]; then
  cp "$CLI_BINARY_PATH" "$STAGING_DIR/bin/cmux"
  SWIFT_CLI_INCLUDED=1
else
  cp "$ROOT_DIR/linux/bin/cmux" "$STAGING_DIR/bin/cmux"
fi
if [ -f "$REMOTE_DAEMON_BINARY_PATH" ]; then
  cp "$REMOTE_DAEMON_BINARY_PATH" "$STAGING_DIR/bin/cmuxd-remote"
fi
tar -C "$ROOT_DIR/linux/lib" --exclude='__pycache__' --exclude='*.pyc' -cf - cmux_linux \
  | tar -C "$STAGING_DIR/lib" -xf -
cp "$ROOT_DIR/linux/share/applications/com.cmuxterm.cmux.desktop" \
  "$STAGING_DIR/share/applications/com.cmuxterm.cmux.desktop"
cp "$ROOT_DIR/linux/README.md" "$STAGING_DIR/README.md"

chmod +x "$STAGING_DIR/bin/cmux-linux"
chmod +x "$STAGING_DIR/bin/cmux"
if [ -f "$STAGING_DIR/bin/cmuxd-remote" ]; then
  chmod +x "$STAGING_DIR/bin/cmuxd-remote"
fi

MANIFEST_ARGS=("$STAGING_DIR")
VALIDATOR_FLAGS=()
if [ -f "$STAGING_DIR/bin/cmuxd-remote" ]; then
  MANIFEST_ARGS+=("--remote-daemon-included")
  VALIDATOR_FLAGS+=("--require-remote-daemon")
  VALIDATOR_FLAGS+=("--probe-remote-daemon")
fi
if [ "$SWIFT_CLI_INCLUDED" -eq 1 ]; then
  MANIFEST_ARGS+=("--swift-cli-included")
  VALIDATOR_FLAGS+=("--require-swift-cli")
fi
PYTHONPYCACHEPREFIX="$PACKAGE_PYCACHE_PREFIX" "$PYTHON_BIN" "$ROOT_DIR/linux/tools/write_package_manifest.py" "${MANIFEST_ARGS[@]}"

tar -C "$DIST_DIR" -czf "$ARCHIVE_PATH" "$PACKAGE_NAME"
PYTHONPYCACHEPREFIX="$PACKAGE_PYCACHE_PREFIX" "$PYTHON_BIN" "$ROOT_DIR/linux/tools/validate_package.py" "$ARCHIVE_PATH" "${VALIDATOR_FLAGS[@]}"
printf 'Linux package: %s\n' "$ARCHIVE_PATH"
