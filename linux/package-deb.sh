#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DIST_DIR="$ROOT_DIR/dist"
PACKAGE_NAME="cmux-linux-x86_64"
STAGING_DIR="$DIST_DIR/$PACKAGE_NAME"
PROJECT_FILE="$ROOT_DIR/GhosttyTabs.xcodeproj/project.pbxproj"
PYTHON_BIN="${CMUX_PYTHON:-python3}"
PACKAGE_PYCACHE_PREFIX="${CMUX_PYTHONPYCACHEPREFIX:-${PYTHONPYCACHEPREFIX:-$DIST_DIR/.pycache}}"

if [ -z "${CMUX_LINUX_SKIP_TARBALL:-}" ]; then
  bash "$ROOT_DIR/linux/package.sh"
fi

if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "dpkg-deb is required to build the cmux Linux deb package" >&2
  exit 1
fi

VERSION="${CMUX_LINUX_VERSION:-}"
if [ -z "$VERSION" ] && [ -f "$PROJECT_FILE" ]; then
  VERSION=$(grep -m1 'MARKETING_VERSION = ' "$PROJECT_FILE" | sed -E 's/.*= ([^;]+);/\1/')
fi
VERSION="${VERSION:-0.0.0}"
DEB_VERSION="${CMUX_LINUX_DEB_VERSION:-$VERSION-1}"
DEB_ROOT="$DIST_DIR/cmux-linux-deb-root"
DEB_PATH="$DIST_DIR/cmux-linux_${DEB_VERSION}_amd64.deb"

rm -rf "$DEB_ROOT" "$DEB_PATH"
mkdir -p "$DEB_ROOT/DEBIAN" "$DEB_ROOT/usr" "$DEB_ROOT/usr/share/doc/cmux"

tar -C "$STAGING_DIR" --exclude='README.md' -cf - bin lib share \
  | tar -C "$DEB_ROOT/usr" -xf -
cp "$STAGING_DIR/README.md" "$DEB_ROOT/usr/share/doc/cmux/README.md"

REMOTE_DAEMON_FLAG=()
if [ -f "$DEB_ROOT/usr/bin/cmuxd-remote" ]; then
  REMOTE_DAEMON_FLAG=("--remote-daemon-included")
fi

SWIFT_CLI_FLAG=()
if ! head -c 2 "$DEB_ROOT/usr/bin/cmux" | grep -q '#!'; then
  SWIFT_CLI_FLAG=("--swift-cli-included")
fi
VALIDATOR_FLAGS=()
if [ "${#REMOTE_DAEMON_FLAG[@]}" -gt 0 ]; then
  VALIDATOR_FLAGS+=("--require-remote-daemon")
  VALIDATOR_FLAGS+=("--probe-remote-daemon")
fi
if [ "${#SWIFT_CLI_FLAG[@]}" -gt 0 ]; then
  VALIDATOR_FLAGS+=("--require-swift-cli")
fi

PYTHONPYCACHEPREFIX="$PACKAGE_PYCACHE_PREFIX" "$PYTHON_BIN" "$ROOT_DIR/linux/tools/write_package_manifest.py" \
  "$DEB_ROOT/usr" \
  --distribution deb \
  "${REMOTE_DAEMON_FLAG[@]}" \
  "${SWIFT_CLI_FLAG[@]}"

cat > "$DEB_ROOT/DEBIAN/control" <<CONTROL
Package: cmux-linux
Version: $DEB_VERSION
Section: utils
Priority: optional
Architecture: amd64
Maintainer: cmux <support@cmuxterm.com>
Depends: python3, python3-gi, gir1.2-gtk-3.0, gir1.2-vte-2.91, gir1.2-webkit2-4.0
Description: cmux Linux runtime
 cmux Linux GTK runtime, CLI, Python libraries, desktop integration, and socket API bridge.
CONTROL

chmod 0755 "$DEB_ROOT/DEBIAN"
find "$DEB_ROOT/usr/bin" -type f -exec chmod 0755 {} +
dpkg-deb --build --root-owner-group "$DEB_ROOT" "$DEB_PATH" >/dev/null
PYTHONPYCACHEPREFIX="$PACKAGE_PYCACHE_PREFIX" "$PYTHON_BIN" "$ROOT_DIR/linux/tools/validate_package.py" "$DEB_PATH" "${VALIDATOR_FLAGS[@]}"
printf 'Linux deb package: %s\n' "$DEB_PATH"
