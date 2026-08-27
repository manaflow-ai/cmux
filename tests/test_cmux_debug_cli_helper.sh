#!/usr/bin/env bash
# Regression test: the tag-bound debug CLI helper scrubs ambient cmux env and
# routes commands through the tagged socket and tagged bundled CLI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TAG="Debug_Helper.Test"
TAG_SLUG="debug-helper-test"
TAG_BUNDLE_ID="debug.helper.test"
SOCKET_PATH="/tmp/cmux-debug-${TAG_SLUG}.sock"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
  rm -f "$SOCKET_PATH"
}
trap cleanup EXIT

FAKE_HOME="$TMP_DIR/home"
FAKE_CLI_DIR="$FAKE_HOME/Library/Developer/Xcode/DerivedData/cmux-${TAG_SLUG}/Build/Products/Debug/cmux DEV ${TAG_SLUG}.app/Contents/Resources/bin"
FAKE_CLI="$FAKE_CLI_DIR/cmux"
mkdir -p "$FAKE_CLI_DIR"
cat > "$FAKE_CLI" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "env" ]]; then
  env | sort
  exit 0
fi
printf 'fake cmux argv:'
printf ' %q' "$@"
printf '\n'
EOF
chmod +x "$FAKE_CLI"

rm -f "$SOCKET_PATH"
python3 - "$SOCKET_PATH" <<'PY' >/dev/null 2>&1 &
import os
import socket
import sys
import time

path = sys.argv[1]
try:
    os.unlink(path)
except FileNotFoundError:
    pass

sock = socket.socket(socket.AF_UNIX)
sock.bind(path)
sock.listen(1)
time.sleep(60)
PY
SERVER_PID="$!"

for _ in {1..100}; do
  if [[ -S "$SOCKET_PATH" ]]; then
    break
  fi
  sleep 0.05
done

if [[ ! -S "$SOCKET_PATH" ]]; then
  echo "FAIL: test socket was not created at $SOCKET_PATH"
  exit 1
fi

OUTPUT="$(
  HOME="$FAKE_HOME" \
  CMUX_TAG="$TAG" \
  CMUX_SOCKET="/tmp/main-cmux-legacy.sock" \
  CMUX_SOCKET_PATH="/tmp/main-cmux.sock" \
  CMUX_SOCKET_PASSWORD="main-secret" \
  CMUX_BUNDLE_ID="com.cmuxterm.app" \
  CMUX_BUNDLED_CLI_PATH="/Applications/cmux.app/Contents/Resources/bin/cmux" \
  CMUX_WORKSPACE_ID="main-workspace" \
  CMUX_TAB_ID="main-tab" \
  CMUX_SURFACE_ID="main-surface" \
  CMUX_PANEL_ID="main-panel" \
  CMUXD_UNIX_PATH="/tmp/main-cmuxd.sock" \
  CMUX_DEBUG_LOG="/tmp/main-cmux.log" \
  "$ROOT_DIR/scripts/cmux-debug-cli.sh" env
)"

require_line() {
  local expected="$1"
  if ! grep -Fxq "$expected" <<<"$OUTPUT"; then
    echo "FAIL: expected env line not found: $expected"
    echo "$OUTPUT"
    exit 1
  fi
}

reject_prefix() {
  local prefix="$1"
  if grep -Eq "^${prefix}=" <<<"$OUTPUT"; then
    echo "FAIL: unexpected env line with prefix: $prefix"
    echo "$OUTPUT"
    exit 1
  fi
}

require_line "CMUX_SOCKET_PATH=$SOCKET_PATH"
require_line "CMUX_TAG=$TAG_SLUG"
require_line "CMUX_BUNDLE_ID=com.cmuxterm.app.debug.${TAG_BUNDLE_ID}"
require_line "CMUX_BUNDLED_CLI_PATH=$FAKE_CLI"

reject_prefix "CMUX_SOCKET"
reject_prefix "CMUX_SOCKET_PASSWORD"
reject_prefix "CMUX_WORKSPACE_ID"
reject_prefix "CMUX_TAB_ID"
reject_prefix "CMUX_SURFACE_ID"
reject_prefix "CMUX_PANEL_ID"
reject_prefix "CMUXD_UNIX_PATH"
reject_prefix "CMUX_DEBUG_LOG"

echo "PASS: cmux-debug-cli.sh routes through the tagged CLI/socket and scrubs ambient cmux env"
