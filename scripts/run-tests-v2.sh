#!/usr/bin/env bash
set -euo pipefail

# This runner is intended for the UTM macOS VM (ssh cmux-vm) or an isolated CI
# macOS runner. It is intentionally guarded so we don't accidentally kill the
# host user's cmux instances.
if [ "$(id -un)" != "cmux" ] && [ "${CMUX_TESTS_V2_ALLOW_NON_VM:-0}" != "1" ]; then
  echo "ERROR: This script is intended to be run on the cmux-vm (user: cmux)." >&2
  echo "Run via: ssh cmux-vm 'cd /Users/cmux/GhosttyTabs && ./scripts/run-tests-v2.sh'" >&2
  echo "Set CMUX_TESTS_V2_ALLOW_NON_VM=1 only on isolated CI runners." >&2
  exit 2
fi

cd "$(dirname "$0")/.."

DERIVED_DATA_PATH="$HOME/Library/Developer/Xcode/DerivedData/cmux-tests-v2"
APP="$DERIVED_DATA_PATH/Build/Products/Debug/cmux DEV.app"
RUN_TAG="tests-v2"
RUN_SOCKET_PATH="/tmp/cmux-debug-${RUN_TAG}.sock"
RUN_DEBUG_LOG="/tmp/cmux-debug-${RUN_TAG}.log"
RUN_CMX_STATE_DIR="/tmp/cmux-cmx-${RUN_TAG}"
RUN_CMX_NATIVE_SOCKET="${RUN_CMX_STATE_DIR}/native.sock"
RUN_CMUXD_SOCKET="$HOME/Library/Application Support/cmux/cmuxd-dev-${RUN_TAG}.sock"
DESKTOP_CMX_BACKEND="${CMUX_TESTS_V2_DESKTOP_CMX_BACKEND:-0}"
RESET_CMX_STATE="${CMUX_TESTS_V2_RESET_CMX_STATE:-1}"
TEST_FILTER="${CMUX_TESTS_V2_FILTER:-test_*.py}"
DIAGNOSTICS_DIR="${CMUX_TESTS_V2_DIAGNOSTICS_DIR:-}"
FAIL_ON_SKIP="${CMUX_TESTS_V2_FAIL_ON_SKIP:-0}"

if [ -n "$DIAGNOSTICS_DIR" ]; then
  rm -rf "$DIAGNOSTICS_DIR"
  mkdir -p "$DIAGNOSTICS_DIR"
fi

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

prepare_desktop_cmx_backend() {
  if [ "$DESKTOP_CMX_BACKEND" != "1" ]; then
    return 0
  fi

  if ! command -v cargo >/dev/null 2>&1; then
    echo "ERROR: cargo is required for CMUX_TESTS_V2_DESKTOP_CMX_BACKEND=1" >&2
    exit 1
  fi

  echo "== build cmx =="
  (cd rust/cmux-cli && cargo build -p cmx)

  local cmx_src="rust/cmux-cli/target/debug/cmx"
  if [ ! -x "$cmx_src" ]; then
    echo "ERROR: cmx binary not found after cargo build: $cmx_src" >&2
    exit 1
  fi

  local bin_dir="$APP/Contents/Resources/bin"
  mkdir -p "$bin_dir"
  cp "$cmx_src" "$bin_dir/cmx"
  chmod +x "$bin_dir/cmx"

  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$APP" || true
  fi
  codesign --force --sign - --timestamp=none --generate-entitlement-der "$APP" >/dev/null
}

collect_diagnostics() {
  if [ -n "$DIAGNOSTICS_DIR" ]; then
    mkdir -p "$DIAGNOSTICS_DIR"
    {
      date
      echo "app: $APP"
      echo "desktop_cmx_backend: $DESKTOP_CMX_BACKEND"
      echo "socket: $RUN_SOCKET_PATH"
      echo "debug_log: $RUN_DEBUG_LOG"
      echo "cmx_state_dir: $RUN_CMX_STATE_DIR"
      echo "bundled_cmx: $APP/Contents/Resources/bin/cmx"
      if [ -x "$APP/Contents/Resources/bin/cmx" ]; then
        "$APP/Contents/Resources/bin/cmx" --version 2>/dev/null || true
      else
        echo "bundled_cmx_missing"
      fi
      ls -la /tmp/cmux* 2>/dev/null || true
      pgrep -af "cmux|cmx" 2>/dev/null || true
    } > "$DIAGNOSTICS_DIR/harness.txt" 2>&1 || true
    for path in \
      "$RUN_DEBUG_LOG" \
      "/tmp/cmux-debug.log" \
      "/tmp/cmux-last-debug-log-path" \
      "/tmp/cmux-last-socket-path" \
      "$RUN_SOCKET_PATH" \
      "$RUN_CMX_NATIVE_SOCKET"
    do
      if [ -e "$path" ]; then
        cp -R "$path" "$DIAGNOSTICS_DIR/" 2>/dev/null || true
      fi
    done
    if [ -d "$RUN_CMX_STATE_DIR" ]; then
      rm -rf "$DIAGNOSTICS_DIR/cmx-state"
      cp -R "$RUN_CMX_STATE_DIR" "$DIAGNOSTICS_DIR/cmx-state" 2>/dev/null || true
    fi
  fi
}

cleanup() {
  collect_diagnostics
  pkill -x "cmux DEV" || true
  pkill -x "cmux" || true
  pkill -f "Resources/bin/cmx --socket ${RUN_CMX_NATIVE_SOCKET}" || true
  rm -f /tmp/cmux*.sock || true
  rm -f "$RUN_CMUXD_SOCKET" || true
  if [ "$DESKTOP_CMX_BACKEND" = "1" ] && [ "$RESET_CMX_STATE" = "1" ]; then
    rm -rf "$RUN_CMX_STATE_DIR"
  fi
  return 0
}

trap cleanup EXIT
prepare_desktop_cmx_backend

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
  printf '%s\n' "$RUN_SOCKET_PATH" > /tmp/cmux-last-socket-path || true
  printf '%s\n' "$RUN_DEBUG_LOG" > /tmp/cmux-last-debug-log-path || true

  # Launch directly with UI test mode enabled so startup follows deterministic test codepaths.
  LAUNCH_ENV=(
    "CMUX_TAG=${RUN_TAG}"
    "CMUX_UI_TEST_MODE=1"
    "CMUX_SOCKET_ENABLE=1"
    "CMUX_SOCKET_MODE=allowAll"
    "CMUX_SOCKET_PATH=${RUN_SOCKET_PATH}"
    "CMUXD_UNIX_PATH=${RUN_CMUXD_SOCKET}"
    "CMUX_DEBUG_LOG=${RUN_DEBUG_LOG}"
    "CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1"
    "CMUXTERM_REPO_ROOT=$PWD"
  )
  if [ "$DESKTOP_CMX_BACKEND" = "1" ]; then
    LAUNCH_ENV+=(
      "CMUX_DESKTOP_CMX_BACKEND=1"
      "CMUX_REMOTE_SSH_STACK_IN_RUST=${CMUX_REMOTE_SSH_STACK_IN_RUST:-1}"
    )
  fi
  env "${LAUNCH_ENV[@]}" "$APP/Contents/MacOS/cmux DEV" >/dev/null 2>&1 &

  SOCK="$RUN_SOCKET_PATH"
  for _ in {1..120}; do
    if [ -n "$SOCK" ] && [ -S "$SOCK" ]; then
      break
    fi
    sleep 0.25
  done

  if [ -z "$SOCK" ] || [ ! -S "$SOCK" ]; then
    collect_diagnostics
    echo "ERROR: Socket not ready (looked for $RUN_SOCKET_PATH)" >&2
    exit 1
  fi
  export CMUX_SOCKET_PATH="$SOCK"

  # Ensure LaunchServices has a visible/main window attached for rendering checks.
  env "${LAUNCH_ENV[@]}" open "$APP" >/dev/null 2>&1 || true
  sleep 0.5

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
    local output_file
    output_file=$(mktemp "${TMPDIR:-/tmp}/cmux-tests-v2-output.XXXXXX")
    if python3 "$f" > >(tee "$output_file") 2> >(tee -a "$output_file" >&2); then
      if [ "$FAIL_ON_SKIP" = "1" ] && grep -Eq '^SKIP:' "$output_file"; then
        echo "FAIL $f reported SKIP while CMUX_TESTS_V2_FAIL_ON_SKIP=1" >&2
        rm -f "$output_file"
        return 1
      fi
      rm -f "$output_file"
      return 0
    fi
    rm -f "$output_file"

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
echo "desktop_cmx_backend: $DESKTOP_CMX_BACKEND"
echo "fail_on_skip: $FAIL_ON_SKIP"
echo "test_filter: $TEST_FILTER"
TEST_FILES=()
read -r -a TEST_PATTERNS <<< "$TEST_FILTER"
for pattern in "${TEST_PATTERNS[@]}"; do
  for f in tests_v2/$pattern; do
    if [ -e "$f" ]; then
      TEST_FILES+=("$f")
    fi
  done
done
if [ "${#TEST_FILES[@]}" -eq 0 ]; then
  echo "ERROR: no tests_v2 files matched CMUX_TESTS_V2_FILTER=$TEST_FILTER" >&2
  exit 1
fi

fail=0
for f in "${TEST_FILES[@]}"; do
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
