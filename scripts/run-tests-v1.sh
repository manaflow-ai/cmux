#!/usr/bin/env bash
set -euo pipefail

# This runner is intended for the UTM macOS VM (ssh cmux-vm).
# It is intentionally guarded so we don't accidentally kill the host user's cmuxterm instances.
if [ "$(id -un)" != "cmux" ]; then
  echo "ERROR: This script is intended to be run on the cmux-vm (user: cmux)." >&2
  echo "Run via: ssh cmux-vm 'cd /Users/cmux/GhosttyTabs && ./scripts/run-tests-v1.sh'" >&2
  exit 2
fi

cd "$(dirname "$0")/.."

echo "== build =="
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination "platform=macOS" build >/dev/null

APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/cmuxterm DEV.app" -print -quit)
if [ -z "${APP:-}" ] || [ ! -d "$APP" ]; then
  echo "ERROR: cmuxterm DEV.app not found under DerivedData" >&2
  exit 1
fi

cleanup() {
  pkill -x "cmuxterm DEV" || true
  pkill -x "cmuxterm" || true
  rm -f /tmp/cmuxterm-debug.sock /tmp/cmuxterm.sock || true
}

launch_and_wait() {
  cleanup
  # Wait briefly for the previous instance to fully terminate; LaunchServices can flake if we
  # relaunch too quickly.
  for _ in {1..50}; do
    pgrep -x "cmuxterm DEV" >/dev/null 2>&1 || break
    sleep 0.1
  done

  # Prefer LaunchServices (`open`) but fall back to running the app binary directly if `open`
  # fails under SSH/UTM.
  open "$APP" >/dev/null 2>&1 || true
  sleep 0.2
  if ! pgrep -x "cmuxterm DEV" >/dev/null 2>&1; then
    "$APP/Contents/MacOS/cmuxterm DEV" >/dev/null 2>&1 &
  fi

  for i in {1..80}; do
    [ -S /tmp/cmuxterm-debug.sock ] && break
    sleep 0.25
  done

  SOCK=/tmp/cmuxterm-debug.sock
  if [ ! -S "$SOCK" ]; then
    echo "ERROR: Socket not ready at $SOCK" >&2
    exit 1
  fi
  export CMUX_SOCKET_PATH="$SOCK"
  export CMUX_SOCKET="$SOCK"

  echo "== wait ready =="
  python3 - <<'PY'
import time
import os
import sys

sys.path.insert(0, os.path.join(os.getcwd(), "tests"))
from cmux import cmux  # type: ignore

client = cmux()
client.connect()

deadline = time.time() + 10.0
last = None
while time.time() < deadline:
    try:
        _ = client.current_workspace()
        # Many focus-sensitive tests require the main window to be key.
        # `open "$APP"` does not reliably activate the app when launched from SSH.
        try:
            client.activate_app()
        except Exception:
            pass
        print("ready")
        break
    except Exception as e:
        last = e
        time.sleep(0.1)
else:
    raise SystemExit(f"ERROR: Socket became available but TabManager isn't ready: {last}")
PY
}

echo "== tests (v1) =="
fail=0
for f in tests/test_*.py; do
  base=$(basename "$f")
  if [ "$base" = "test_ctrl_interactive.py" ]; then
    echo "SKIP $f"
    continue
  fi
  echo "== launch ($base) =="
  launch_and_wait
  echo "RUN  $f"
  if ! python3 "$f"; then
    echo "FAIL $f" >&2
    fail=1
    break
  fi
done

echo "== cleanup =="
cleanup

exit "$fail"
