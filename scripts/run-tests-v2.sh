#!/usr/bin/env bash
set -euo pipefail

# This runner is intended for the UTM macOS VM (ssh cmux-vm).
# It is intentionally guarded so we don't accidentally kill the host user's cmuxterm instances.
if [ "$(id -un)" != "cmux" ]; then
  echo "ERROR: This script is intended to be run on the cmux-vm (user: cmux)." >&2
  echo "Run via: ssh cmux-vm 'cd /Users/cmux/GhosttyTabs && ./scripts/run-tests-v2.sh'" >&2
  exit 2
fi

cd "$(dirname "$0")/.."

DERIVED_DATA_PATH="$HOME/Library/Developer/Xcode/DerivedData/cmuxterm-tests-v2"
APP="$DERIVED_DATA_PATH/Build/Products/Debug/cmuxterm DEV.app"

echo "== build =="
xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build >/dev/null

if [ ! -d "$APP" ]; then
  echo "ERROR: cmuxterm DEV.app not found at expected path: $APP" >&2
  exit 1
fi

cleanup() {
  pkill -x "cmuxterm DEV" || true
  pkill -x "cmuxterm" || true
  rm -f /tmp/cmuxterm*.sock || true
}

launch_and_wait() {
  cleanup
  # Wait briefly for the previous instance to fully terminate; LaunchServices can flake if we
  # relaunch too quickly.
  for _ in {1..50}; do
    pgrep -x "cmuxterm DEV" >/dev/null 2>&1 || break
    sleep 0.1
  done

  # Force socket mode for deterministic automation runs, independent of prior user settings.
  defaults write com.cmuxterm.app.debug socketControlMode -string full >/dev/null 2>&1 || true

  # Prefer LaunchServices (`open`) so the main window/tab manager initializes normally.
  open "$APP" >/dev/null 2>&1 || true
  sleep 0.3
  if ! pgrep -x "cmuxterm DEV" >/dev/null 2>&1; then
    "$APP/Contents/MacOS/cmuxterm DEV" >/dev/null 2>&1 &
  fi

  SOCK=""
  for _ in {1..120}; do
    SOCK=$(ls -t /tmp/cmuxterm-debug*.sock /tmp/cmuxterm*.sock 2>/dev/null | head -1 || true)
    if [ -n "$SOCK" ] && [ -S "$SOCK" ]; then
      break
    fi
    sleep 0.25
  done

  if [ -z "$SOCK" ] || [ ! -S "$SOCK" ]; then
    echo "ERROR: Socket not ready (looked for /tmp/cmuxterm*.sock)" >&2
    exit 1
  fi
  export CMUX_SOCKET_PATH="$SOCK"
  export CMUX_SOCKET="$SOCK"

  echo "== wait ready =="
  python3 - <<'PY'
import time
import os
import sys

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
    raise SystemExit(f"ERROR: Socket path exists but connect keeps failing: {last}")

while time.time() < deadline:
    try:
        _ = client.current_workspace()
        # Many focus-sensitive tests require the main window to be key.
        # `open "$APP"` does not reliably activate the app when launched from SSH.
        try:
            client.activate_app()
        except Exception:
            pass
        break
    except Exception as e:
        last = e
        time.sleep(0.1)
else:
    raise SystemExit(f"ERROR: Socket connected but TabManager isn't ready: {last}")

# Use a fresh connection to avoid stale-listener races where the first connection succeeds but
# immediate reconnects fail with ECONNREFUSED.
probe_deadline = time.time() + 10.0
while time.time() < probe_deadline:
    probe = None
    try:
        probe = cmux()
        probe.connect()
        _ = probe.current_workspace()
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
    raise SystemExit(f"ERROR: Ready-check reconnect/ping failed: {last}")

if client is not None:
    try:
        client.close()
    except Exception:
        pass
PY
}

run_test_with_retry() {
  local f="$1"
  local attempts=3
  local n=1

  while [ "$n" -le "$attempts" ]; do
    echo "RUN  $f (attempt $n/$attempts)"
    if python3 "$f"; then
      return 0
    fi

    if [ "$n" -ge "$attempts" ]; then
      return 1
    fi

    echo "WARN: attempt $n failed for $f; relaunching and retrying" >&2
    echo "== relaunch (retry) =="
    launch_and_wait
    n=$((n + 1))
  done

  return 1
}

echo "== tests (v2) =="
fail=0
for f in tests_v2/test_*.py; do
  base=$(basename "$f")
  if [ "$base" = "test_ctrl_interactive.py" ]; then
    echo "SKIP $f"
    continue
  fi

  echo "== launch ($base) =="
  launch_and_wait
  if ! run_test_with_retry "$f"; then
    echo "FAIL $f" >&2
    fail=1
    break
  fi
done

echo "== cleanup =="
cleanup

exit "$fail"
