#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/verify-local-daemon-session-sharing.sh <tag>

Builds the Zig daemon, launches the tagged cmux app with local-daemon wiring
enabled, and verifies the app auto-starts cmuxd-remote when a local terminal
session is created.
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

TAG="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/zig-build-env.sh"
SANITIZED_TAG="$(echo "$TAG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
BUNDLE_ID="com.cmuxterm.app.debug.$(echo "$TAG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\\.+//; s/\\.+$//; s/\\.+/./g')"
APP_PROCESS_NAME="cmux DEV ${TAG}"
APP_SUPPORT_DIR="$HOME/Library/Application Support/cmux"
APP_SOCKET="/tmp/cmux-debug-${SANITIZED_TAG}.sock"
DAEMON_SOCKET="${APP_SUPPORT_DIR}/cmuxd-dev-${SANITIZED_TAG}.sock"
DAEMON_LOG="/tmp/cmuxd-local-${SANITIZED_TAG}.log"
DAEMON_BIN="$ROOT/daemon/remote/zig/zig-out/bin/cmuxd-remote"
CLI_BIN="$HOME/Library/Developer/Xcode/DerivedData/cmux-${SANITIZED_TAG}/Build/Products/Debug/cmux"
APP="$HOME/Library/Developer/Xcode/DerivedData/cmux-${SANITIZED_TAG}/Build/Products/Debug/cmux DEV ${TAG}.app"
APP_LOG="/tmp/cmux-local-daemon-${SANITIZED_TAG}.log"

mkdir -p "$APP_SUPPORT_DIR"

cleanup() {
  pkill -f "cmuxd-remote serve --unix --socket ${DAEMON_SOCKET}" >/dev/null 2>&1 || true
  rm -f "$DAEMON_SOCKET"
}

trap cleanup EXIT

cd "$ROOT/daemon/remote/zig"
cmux_run_zig build -Doptimize=ReleaseFast
cd "$ROOT"

pkill -f "cmuxd-remote serve --unix --socket ${DAEMON_SOCKET}" >/dev/null 2>&1 || true
rm -f "$DAEMON_SOCKET" "$DAEMON_LOG"

if [[ ! -d "$APP" ]]; then
  echo "error: tagged app not found at $APP" >&2
  exit 1
fi

pkill -f "cmux DEV ${TAG}.app/Contents/MacOS/cmux DEV" >/dev/null 2>&1 || true
rm -f "$APP_SOCKET" "$APP_LOG"

env \
  -u CMUX_SOCKET_PATH \
  -u CMUX_WORKSPACE_ID \
  -u CMUX_SURFACE_ID \
  -u CMUX_TAB_ID \
  -u CMUX_PANEL_ID \
  -u CMUXD_UNIX_PATH \
  -u CMUX_TAG \
  -u CMUX_DEBUG_LOG \
  -u CMUX_BUNDLE_ID \
  -u CMUX_SHELL_INTEGRATION \
  -u GHOSTTY_BIN_DIR \
  -u GHOSTTY_RESOURCES_DIR \
  -u GHOSTTY_SHELL_FEATURES \
  -u GIT_PAGER \
  -u GH_PAGER \
  -u TERMINFO \
  -u XDG_DATA_DIRS \
  CMUX_TAG="$SANITIZED_TAG" \
  CMUX_SOCKET_ENABLE=1 \
  CMUX_SOCKET_MODE=automation \
  CMUX_SOCKET_PATH="$APP_SOCKET" \
  CMUX_SOCKET="$APP_SOCKET" \
  CMUXD_UNIX_PATH="$DAEMON_SOCKET" \
  CMUX_DEBUG_LOG="$APP_LOG" \
  CMUX_BUNDLE_ID="$BUNDLE_ID" \
  CMUX_REMOTE_DAEMON_BINARY="$DAEMON_BIN" \
  CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 \
  CMUXTERM_REPO_ROOT="$ROOT" \
  open "$APP"

deadline=$((SECONDS + 20))
while (( SECONDS < deadline )); do
  if [[ -S "$APP_SOCKET" ]]; then
    break
  fi
  sleep 0.1
done

if [[ ! -S "$APP_SOCKET" ]]; then
  echo "error: app socket not ready at $APP_SOCKET" >&2
  tail -n 120 "$APP_LOG" >&2 || true
  exit 1
fi

CMUX_SOCKET="$APP_SOCKET" \
CMUX_SOCKET_PATH="$APP_SOCKET" \
python3 - <<'PY'
import os
import sys
import time

sys.path.insert(0, os.path.join(os.getcwd(), "tests_v2"))
from cmux import cmux  # type: ignore

deadline = time.time() + 30.0
last = None
client = None
while time.time() < deadline:
    try:
        client = cmux()
        client.connect()
        break
    except Exception as e:
        last = e
        time.sleep(0.1)
else:
    raise SystemExit(f"error: app socket exists but connect keeps failing: {last}")

workspace_ready = False
while time.time() < deadline:
    try:
        _ = client.current_workspace()
        try:
            client.activate_app()
        except Exception:
            pass
        workspace_ready = True
        break
    except Exception as e:
        last = e
        time.sleep(0.1)

if not workspace_ready:
    raise SystemExit(f"error: app never reached workspace-ready state: {last}")

probe_deadline = time.time() + 10.0
while time.time() < probe_deadline:
    probe = None
    try:
        probe = cmux()
        probe.connect()
        if not probe.ping():
            raise RuntimeError("ping returned false")
        print("ready")
        break
    except Exception as e:
        last = e
        time.sleep(0.1)
    finally:
        if probe is not None:
            try:
                probe.close()
            except Exception:
                pass
else:
    raise SystemExit(f"error: app ready-check reconnect/ping failed: {last}")

if client is not None:
    try:
        client.close()
    except Exception:
        pass
PY

if [[ ! -x "$CLI_BIN" ]]; then
  echo "error: tagged cmux CLI not found at $CLI_BIN" >&2
  exit 1
fi

CMUX_SOCKET="$APP_SOCKET" \
CMUX_SOCKET_PATH="$APP_SOCKET" \
CMUXD_UNIX_PATH="$DAEMON_SOCKET" \
CMUX_BUNDLE_ID="$BUNDLE_ID" \
CMUX_APP_PROCESS_NAME="$APP_PROCESS_NAME" \
CMUX_REMOTE_DAEMON_BINARY="$DAEMON_BIN" \
CMUXTERM_CLI="$CLI_BIN" \
python3 "$ROOT/tests_v2/test_local_daemon_session_sharing.py"

if [[ ! -S "$DAEMON_SOCKET" ]]; then
  echo "error: app never auto-started daemon socket at $DAEMON_SOCKET" >&2
  tail -n 120 "$APP_LOG" >&2 || true
  exit 1
fi

echo "app: $APP"
echo "socket: $APP_SOCKET"
echo "cmuxd_socket: $DAEMON_SOCKET"
echo "app_log: $APP_LOG"
echo "daemon_log: $DAEMON_LOG"
