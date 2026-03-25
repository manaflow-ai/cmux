#!/usr/bin/env bash
set -euo pipefail

APP_NAME="cmux-t3code"
BUNDLE_ID="com.cmuxterm.app.t3code"
INSTALL_DIR="/Applications"
APP_SUPPORT_DIR="$HOME/Library/Application Support/cmux"
CMUX_SOCKET="/tmp/cmux-t3code.sock"
CMUXD_SOCKET="${APP_SUPPORT_DIR}/cmuxd-t3code.sock"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SUPERPROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/cmux-t3code-install"

echo "============================================================"
echo "  Installing ${APP_NAME} as standalone app"
echo "============================================================"
echo ""
echo "  Bundle ID:      ${BUNDLE_ID}"
echo "  Install path:   ${INSTALL_DIR}/${APP_NAME}.app"
echo "  Socket:         ${CMUX_SOCKET}"
echo "  Daemon socket:  ${CMUXD_SOCKET}"
echo ""

cd "$REPO_ROOT"

# --- Build t3code server (Node.js sidecar) ---
T3CODE_DIR="${SUPERPROJECT_ROOT}/t3code"
T3CODE_DIST="${T3CODE_DIR}/apps/server/dist/index.mjs"
if [ -d "$T3CODE_DIR" ]; then
  echo "▸ Building t3code server..."
  if command -v bun >/dev/null 2>&1; then
    (cd "$T3CODE_DIR" && bun install && bun run build)
  elif command -v npm >/dev/null 2>&1; then
    (cd "$T3CODE_DIR" && npm install && npm run build)
  else
    echo "warning: neither bun nor npm found — skipping t3code build" >&2
  fi
  if [ -f "$T3CODE_DIST" ]; then
    echo "▸ t3code server built successfully"
  else
    echo "warning: t3code dist not found after build — sidecar will not be bundled" >&2
  fi
else
  echo "warning: t3code submodule not found at ${T3CODE_DIR}" >&2
fi

echo "▸ Building Release configuration..."
XCODE_LOG="/tmp/cmux-t3code-xcodebuild.log"
xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  build 2>&1 | tee "$XCODE_LOG" | grep -E '(warning:|error:|fatal:|BUILD FAILED|BUILD SUCCEEDED|\*\* BUILD)' || true
XCODE_EXIT="${PIPESTATUS[0]}"
echo "Full build log: $XCODE_LOG"
[[ "$XCODE_EXIT" -ne 0 ]] && echo "error: build failed ($XCODE_EXIT)" >&2 && exit "$XCODE_EXIT"
echo "▸ Build succeeded."
sleep 0.2

BUILT_APP="${DERIVED_DATA}/Build/Products/Release/cmux.app"
[[ ! -d "$BUILT_APP" ]] && echo "error: cmux.app not found" >&2 && exit 1

CMUXD_SRC="${REPO_ROOT}/cmuxd/zig-out/bin/cmuxd"
[[ -d "${REPO_ROOT}/cmuxd" ]] && echo "▸ Building cmuxd..." && (cd "${REPO_ROOT}/cmuxd" && zig build -Doptimize=ReleaseFast) || true

GHOSTTY_HELPER_SRC="${REPO_ROOT}/ghostty/zig-out/bin/ghostty"
[[ -d "${REPO_ROOT}/ghostty" ]] && command -v zig >/dev/null 2>&1 && echo "▸ Building ghostty helper..." && \
  (cd "${REPO_ROOT}/ghostty" && zig build cli-helper -Dapp-runtime=none -Demit-macos-app=false -Demit-xcframework=false -Doptimize=ReleaseFast) || true

echo "▸ Quitting any running ${APP_NAME}..."
/usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
sleep 0.3
pkill -f "${APP_NAME}.app/Contents/MacOS/cmux" 2>/dev/null || true
sleep 0.3

INSTALL_PATH="${INSTALL_DIR}/${APP_NAME}.app"
echo "▸ Installing to ${INSTALL_PATH}..."
[[ -d "$INSTALL_PATH" ]] && rm -rf "$INSTALL_PATH"
cp -R "$BUILT_APP" "$INSTALL_PATH"

INFO_PLIST="$INSTALL_PATH/Contents/Info.plist"
echo "▸ Patching Info.plist..."
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME}" "$INFO_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleName string ${APP_NAME}" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${APP_NAME}" "$INFO_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${APP_NAME}" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$INFO_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${BUNDLE_ID}" "$INFO_PLIST"

/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$INFO_PLIST" 2>/dev/null || true
for kv in \
  "CMUX_SOCKET_PATH:${CMUX_SOCKET}" \
  "CMUXD_UNIX_PATH:${CMUXD_SOCKET}" \
  "CMUX_SOCKET_ENABLE:1" \
  "CMUX_SOCKET_MODE:automation" \
  "CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD:1" \
  "CMUXTERM_REPO_ROOT:${SUPERPROJECT_ROOT}" \
  "T3CODE_SERVER_PATH:${T3CODE_DIST}"; do
  KEY="${kv%%:*}"; VAL="${kv#*:}"
  /usr/libexec/PlistBuddy -c "Set :LSEnvironment:${KEY} \"${VAL}\"" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:${KEY} string \"${VAL}\"" "$INFO_PLIST"
done

BIN_DIR="$INSTALL_PATH/Contents/Resources/bin"
mkdir -p "$BIN_DIR"
[[ -x "$CMUXD_SRC" ]] && cp "$CMUXD_SRC" "$BIN_DIR/cmuxd" && chmod +x "$BIN_DIR/cmuxd" && echo "▸ Bundled cmuxd"
[[ -x "$GHOSTTY_HELPER_SRC" ]] && cp "$GHOSTTY_HELPER_SRC" "$BIN_DIR/ghostty" && chmod +x "$BIN_DIR/ghostty" && echo "▸ Bundled ghostty"

echo "▸ Re-codesigning..."
/usr/bin/codesign --force --deep --sign - --timestamp=none --generate-entitlement-der "$INSTALL_PATH" >/dev/null 2>&1 || true

[[ -S "$CMUXD_SOCKET" ]] && rm -f "$CMUXD_SOCKET"
[[ -S "$CMUX_SOCKET" ]] && rm -f "$CMUX_SOCKET"

CLI_SRC="${INSTALL_PATH}/Contents/Resources/bin/cmux"
CLI_TARGET=""
if [[ -x "$CLI_SRC" ]]; then
  for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
    [[ -d "$d" && -w "$d" ]] && CLI_TARGET="$d/cmux-t3code" && break
  done
  [[ -z "$CLI_TARGET" ]] && mkdir -p "$HOME/.local/bin" && CLI_TARGET="$HOME/.local/bin/cmux-t3code"
  ln -sfn "$CLI_SRC" "$CLI_TARGET"
  echo "▸ CLI: ${CLI_TARGET}"
fi

mkdir -p "$APP_SUPPORT_DIR"

echo ""
echo "============================================================"
echo "  ✓ Installation complete!"
echo "============================================================"
echo "  App:       ${INSTALL_PATH}"
echo "  Bundle ID: ${BUNDLE_ID}"
echo "  Socket:    ${CMUX_SOCKET}"
echo "  CLI:       ${CLI_TARGET:-N/A}"
echo ""
echo "  Launch:    open /Applications/cmux-t3code.app"
