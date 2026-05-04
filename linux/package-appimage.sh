#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DIST_DIR="$ROOT_DIR/dist"
PACKAGE_NAME="cmux-linux-x86_64"
STAGING_DIR="$DIST_DIR/$PACKAGE_NAME"
APPDIR="$DIST_DIR/cmux-linux.AppDir"
APPIMAGE_PATH="$DIST_DIR/cmux-linux-x86_64.AppImage"
APPIMAGETOOL_BIN="${APPIMAGETOOL:-appimagetool}"
PYTHON_BIN="${CMUX_PYTHON:-python3}"
PACKAGE_PYCACHE_PREFIX="${CMUX_PYTHONPYCACHEPREFIX:-${PYTHONPYCACHEPREFIX:-$DIST_DIR/.pycache}}"

if [ -z "${CMUX_LINUX_SKIP_TARBALL:-}" ]; then
  bash "$ROOT_DIR/linux/package.sh"
fi

if ! command -v "$APPIMAGETOOL_BIN" >/dev/null 2>&1; then
  echo "appimagetool is required to build the cmux Linux AppImage" >&2
  exit 1
fi

rm -rf "$APPDIR" "$APPIMAGE_PATH"
mkdir -p "$APPDIR/usr/share/doc/cmux"

tar -C "$STAGING_DIR" --exclude='README.md' -cf - bin lib share \
  | tar -C "$APPDIR/usr" -xf -
cp "$STAGING_DIR/README.md" "$APPDIR/usr/share/doc/cmux/README.md"
cp "$STAGING_DIR/share/applications/com.cmuxterm.cmux.desktop" \
  "$APPDIR/com.cmuxterm.cmux.desktop"

REMOTE_DAEMON_FLAG=()
if [ -f "$APPDIR/usr/bin/cmuxd-remote" ]; then
  REMOTE_DAEMON_FLAG=("--remote-daemon-included")
fi

SWIFT_CLI_FLAG=()
if ! head -c 2 "$APPDIR/usr/bin/cmux" | grep -q '#!'; then
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
  "$APPDIR/usr" \
  --distribution appimage \
  "${REMOTE_DAEMON_FLAG[@]}" \
  "${SWIFT_CLI_FLAG[@]}"

cat > "$APPDIR/AppRun" <<'APPRUN'
#!/usr/bin/env bash
set -euo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export PYTHONPATH="$HERE/usr/lib:${PYTHONPATH:-}"
exec "$HERE/usr/bin/cmux-linux" "$@"
APPRUN

cat > "$APPDIR/utilities-terminal.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">
  <rect width="128" height="128" rx="20" fill="#20242b"/>
  <path d="M28 38l24 26-24 26" fill="none" stroke="#f4f6f8" stroke-width="10" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M62 90h38" fill="none" stroke="#55d6be" stroke-width="10" stroke-linecap="round"/>
</svg>
SVG

chmod 0755 "$APPDIR/AppRun"
find "$APPDIR/usr/bin" -type f -exec chmod 0755 {} +
ARCH=x86_64 "$APPIMAGETOOL_BIN" "$APPDIR" "$APPIMAGE_PATH" >/dev/null
PYTHONPYCACHEPREFIX="$PACKAGE_PYCACHE_PREFIX" "$PYTHON_BIN" "$ROOT_DIR/linux/tools/validate_package.py" "$APPIMAGE_PATH" "${VALIDATOR_FLAGS[@]}"
printf 'Linux AppImage package: %s\n' "$APPIMAGE_PATH"
