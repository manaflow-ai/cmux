#!/usr/bin/env bash
set -euo pipefail

# This runner is intended for the UTM macOS VM (ssh cmux-vm).
# It is intentionally guarded so we don't accidentally kill the host user's cmux instances.
if [ "$(id -un)" != "cmux" ]; then
  echo "ERROR: This script is intended to be run on the cmux-vm (user: cmux)." >&2
  echo "Run via: ssh cmux-vm 'cd /Users/cmux/GhosttyTabs && ./scripts/run-tests-v1.sh'" >&2
  exit 2
fi

cd "$(dirname "$0")/.."

DERIVED_DATA_PATH="$HOME/Library/Developer/Xcode/DerivedData/cmux-tests-v1"
APP="$DERIVED_DATA_PATH/Build/Products/Debug/cmux DEV.app"

echo "== build =="
# Work around stale explicit-module cache artifacts (notably Sentry headers) that can
# intermittently break incremental VM builds with "file ... has been modified since the
# module file ... was built".
rm -rf "$DERIVED_DATA_PATH/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules" || true
xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build >/dev/null

if [ ! -d "$APP" ]; then
  echo "ERROR: cmux DEV.app not found at expected path: $APP" >&2
  exit 1
fi

cleanup() {
  pkill -x "cmux DEV" || true
  pkill -x "cmux" || true
  rm -f /tmp/cmux*.sock || true
}

launch_and_wait() {
  cleanup
  # Wait briefly for the previous instance to fully terminate; LaunchServices can flake if we
  # relaunch too quickly.
  for _ in {1..50}; do
    pgrep -x "cmux DEV" >/dev/null 2>&1 || break
    sleep 0.1
  done

  # Force socket mode for deterministic automation runs, independent of prior user settings.
  defaults write com.cmuxterm.app.debug socketControlMode -string full >/dev/null 2>&1 || true

  # Launch directly with UI test mode enabled so startup follows deterministic test codepaths.
  CMUX_UI_TEST_MODE=1 "$APP/Contents/MacOS/cmux DEV" >/dev/null 2>&1 &

  SOCK=""
  for _ in {1..120}; do
    SOCK=$(ls -t /tmp/cmux-debug*.sock /tmp/cmux*.sock 2>/dev/null | head -1 || true)
    if [ -n "$SOCK" ] && [ -S "$SOCK" ]; then
      break
    fi
    sleep 0.25
  done

  if [ -z "$SOCK" ] || [ ! -S "$SOCK" ]; then
    echo "ERROR: Socket not ready (looked for /tmp/cmux*.sock)" >&2
    exit 1
  fi
  export CMUX_SOCKET_PATH="$SOCK"
  export CMUX_SOCKET="$SOCK"

  # Ensure LaunchServices has a visible/main window attached for rendering checks.
  open "$APP" >/dev/null 2>&1 || true
  sleep 0.5

  echo "== wait ready =="
  python3 - <<'PY'
import time
import os
import sys

sys.path.insert(0, os.path.join(os.getcwd(), "tests"))
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

workspace_ready = False
while time.time() < deadline:
    try:
        _ = client.current_workspace()
        # Many focus-sensitive tests require the main window to be key.
        # `open "$APP"` does not reliably activate the app when launched from SSH.
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
    print(f"WARN: continuing without workspace-ready state: {last}")

# Use a fresh connection to avoid stale-listener races where the first connection succeeds but
# immediate reconnects fail with ECONNREFUSED.
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
    raise SystemExit(f"ERROR: Ready-check reconnect/ping failed: {last}")

# Force a single fresh workspace so startup-state restoration doesn't leave tests
# focused on non-terminal panels (which breaks read_screen/read_terminal_text assumptions)
# or with extra pre-existing workspaces that make ordering-dependent tests flaky.
bootstrap_last = None
for _ in range(3):
    try:
        existing_ids = []
        try:
            existing_ids = [row[1] for row in client.list_workspaces() if len(row) >= 2]
        except Exception:
            existing_ids = []

        ws_id = client.new_workspace()
        client.select_workspace(ws_id)

        for old_id in existing_ids:
            if old_id == ws_id:
                continue
            try:
                client.close_workspace(old_id)
            except Exception:
                pass

        surfaces = client.list_surfaces()
        if not surfaces:
            raise RuntimeError("new workspace has no surfaces")
        client.focus_surface(0)
        break
    except Exception as e:
        bootstrap_last = e
        time.sleep(0.2)
else:
    raise SystemExit(f"ERROR: Failed to bootstrap fresh terminal workspace: {bootstrap_last}")

window_last = None
window_deadline = time.time() + 10.0
while time.time() < window_deadline:
    try:
        health = client.surface_health()
        if any(bool(row.get("in_window")) for row in health):
            break
        client.activate_app()
    except Exception as e:
        window_last = e
    time.sleep(0.1)
else:
    print(f"WARN: no in-window terminal surface detected before test start: {window_last}")

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
  if ! run_test_with_retry "$f"; then
    echo "FAIL $f" >&2
    fail=1
    break
  fi
done

echo "== cleanup =="
cleanup

exit "$fail"
