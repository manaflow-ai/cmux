#!/usr/bin/env bash
# Feature smoke for a signed cmux app bundle: check the bundled cmux CLI (the
# cmux-tui binary, plans/cmux-next/cli.md), then launch the app and drive it
# through that CLI over the app's control socket.
#
# smoke-launch-macos-app.sh only proves the process stays alive. This script
# proves the shipped CLI runs, its cmux-tui and acpmux names resolve to it, and
# the shipped CLI and app agree on the control socket protocol.
#
# Usage: smoke-signed-app-cli.sh <app-path>
#
# CI only: cmux enforces a single instance per bundle id, so launching a
# bundle whose channel you are using on this Mac terminates your running copy.
#
# Environment:
#   CMUX_CLI_SMOKE_SOCKET_TIMEOUT_SECONDS  wait for the socket (default 45)
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <app-path>" >&2
  exit 2
fi

APP_PATH="$1"
if [[ ! -d "$APP_PATH/Contents" ]]; then
  echo "error: app bundle not found at $APP_PATH" >&2
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
CLI_PATH="$APP_PATH/Contents/Resources/bin/cmux"

if [[ ! -x "$CLI_PATH" ]]; then
  echo "error: bundled CLI missing or not executable at $CLI_PATH" >&2
  exit 1
fi

# Same architecture policy as smoke-launch-macos-app.sh: a thin x86_64 variant
# runs through Rosetta when the host has it, and is skipped when it does not.
HOST_ARCH="$(uname -m)"
if command -v lipo >/dev/null 2>&1 && ! lipo "$EXECUTABLE_PATH" -verify_arch "$HOST_ARCH" 2>/dev/null; then
  APP_ARCHS="$(lipo -archs "$EXECUTABLE_PATH" 2>/dev/null || echo unknown)"
  if [[ "$HOST_ARCH" == "arm64" && "$APP_ARCHS" == "x86_64" ]] && /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
    echo "cli smoke: running x86_64-only app through Rosetta on $HOST_ARCH host"
    # Rosetta translates the large CLI binary on its first run, which alone
    # can pass 20s on a CI runner (nightly-next run 37506678564).
    ROSETTA_CLI_TIMEOUT_SECONDS=120
  else
    echo "SKIP: cannot run the CLI smoke for an app built for '$APP_ARCHS' on a $HOST_ARCH host (Rosetta unavailable)"
    exit 0
  fi
fi

SOCKET_TIMEOUT_SECONDS="${CMUX_CLI_SMOKE_SOCKET_TIMEOUT_SECONDS:-45}"

# A short private socket path: sun_path is limited to 104 bytes, and a private
# path cannot collide with a socket another cmux on the runner already owns.
WORK_DIR="$(mktemp -d /tmp/cmux-cli-smoke.XXXXXX)"
SOCKET_PATH="$WORK_DIR/s.sock"
APP_LOG="$WORK_DIR/app.log"
APP_PID=""
STEP="setup"

cleanup() {
  local status=$?
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    for _ in $(seq 1 25); do
      kill -0 "$APP_PID" 2>/dev/null || break
      sleep 0.2
    done
    kill -9 "$APP_PID" 2>/dev/null || true
  fi
  if [[ -n "$APP_PID" ]]; then
    # The app leaves its cmux-tui daemon running by design; this run started it.
    # Stop it by its socket, never by pattern: a pattern on the bundle path
    # also kills every terminal host, and with it the shells.
    # shellcheck source=SCRIPTDIR/lib/stop-cmux-tui-owners.sh
    source "$(dirname "${BASH_SOURCE[0]}")/lib/stop-cmux-tui-owners.sh"
    cmux_stop_cmux_tui_owners "$APP_PATH/Contents/Resources/bin"
  fi
  if [[ $status -ne 0 ]]; then
    echo "error: CLI smoke failed during step: $STEP" >&2
    if [[ -s "$APP_LOG" ]]; then
      echo "--- app stdout/stderr (last 80 lines) ---" >&2
      tail -n 80 "$APP_LOG" >&2 || true
    fi
    local log_name startup_log
    log_name="$(printf '%s' "$BUNDLE_ID" | sed -E 's/[^A-Za-z0-9._-]/-/g')"
    startup_log="$HOME/Library/Logs/cmux/startup-${log_name}.log"
    if [[ -f "$startup_log" ]]; then
      echo "--- startup breadcrumbs (last 60 lines) ---" >&2
      tail -n 60 "$startup_log" >&2 || true
    fi
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Run the bundled CLI against the private socket with a hard timeout so a hung
# socket call fails this step instead of the whole job timeout.
cli() {
  local timeout_seconds="${CLI_TIMEOUT_SECONDS:-${ROSETTA_CLI_TIMEOUT_SECONDS:-20}}"
  local out_file="$WORK_DIR/cli.out"
  local err_file="$WORK_DIR/cli.err"
  # Drop caller context a cmux terminal would export, so a local run inside
  # cmux cannot route these commands at the caller's own workspace.
  env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID -u CMUX_TAB_ID -u CMUX_PANEL_ID \
    -u CMUX_SOCKET_PASSWORD -u CMUX_TUI_SOCKET -u CMUX_TAG -u CMUX_BUNDLE_ID \
    CMUX_SOCKET_PATH="$SOCKET_PATH" \
    "$CLI_PATH" "$@" >"$out_file" 2>"$err_file" &
  local pid=$!
  local deadline=$((SECONDS + timeout_seconds))
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      echo "cmux $* timed out after ${timeout_seconds}s" >&2
      cat "$err_file" >&2 || true
      return 124
    fi
    sleep 0.1
  done
  local status=0
  wait "$pid" || status=$?
  if [[ $status -ne 0 ]]; then
    echo "cmux $* exited $status" >&2
    cat "$out_file" >&2 || true
    cat "$err_file" >&2 || true
    return "$status"
  fi
  cat "$out_file"
}

echo "==> CLI smoke for $APP_PATH ($BUNDLE_ID $SHORT_VERSION build $BUILD_VERSION)"

# 1. Socket-free CLI checks.
STEP="bin/cmux-tui and bin/acpmux symlinks"
[[ ! -L "$CLI_PATH" ]] || fail "$CLI_PATH is a symlink; it must be the cmux-tui binary itself"
for alias in cmux-tui acpmux; do
  target="$(readlink "$APP_PATH/Contents/Resources/bin/$alias" || true)"
  [[ "$target" == cmux ]] || fail "bin/$alias points at '$target', expected cmux"
done
echo "ok: bin/cmux-tui and bin/acpmux link to bin/cmux"

STEP="cmux --version"
VERSION_OUT="$(cli --version)"
[[ "$VERSION_OUT" == "cmux "* ]] || fail "bundled CLI reports '$VERSION_OUT', expected 'cmux <version>'"
echo "ok: $VERSION_OUT"

STEP="cmux --help"
HELP_OUT="$(cli --help)"
[[ -n "$HELP_OUT" ]] || fail "cmux --help printed nothing"
echo "ok: cmux --help"

STEP="cmux acp --help"
ACP_HELP_OUT="$(cli acp --help)"
[[ -n "$ACP_HELP_OUT" ]] || fail "cmux acp --help printed nothing"
echo "ok: cmux acp --help"

STEP="acpmux --version"
ACPMUX_VERSION="$("$APP_PATH/Contents/Resources/bin/acpmux" --version)"
[[ "$ACPMUX_VERSION" == "acpmux "* ]] || fail "bin/acpmux --version printed '$ACPMUX_VERSION', expected 'acpmux <version>'"
echo "ok: $ACPMUX_VERSION"

# 2. Launch the signed app with the socket open to this script. cmux-next
# reads only its own CMUX_NEXT_* launch knobs (inherited CMUX_* variables never
# choose its socket): CMUX_NEXT_SOCKET_PATH picks the private path, allowAll
# lets a process the app did not spawn connect, and CMUX_NEXT_NO_ACTIVATE keeps
# the window from taking focus.
STEP="launch app"
env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID -u CMUX_TAB_ID -u CMUX_PANEL_ID \
  -u CMUX_SOCKET_PATH -u CMUX_SOCKET_PASSWORD \
  CMUX_NEXT_SOCKET_PATH="$SOCKET_PATH" \
  CMUX_NEXT_SOCKET_MODE=allowAll \
  CMUX_NEXT_NO_ACTIVATE=1 \
  "$EXECUTABLE_PATH" -ApplePersistenceIgnoreState YES >"$APP_LOG" 2>&1 &
APP_PID=$!
echo "app pid $APP_PID, socket $SOCKET_PATH"

STEP="wait for socket"
deadline=$((SECONDS + SOCKET_TIMEOUT_SECONDS))
until [[ -S "$SOCKET_PATH" ]]; do
  kill -0 "$APP_PID" 2>/dev/null || fail "app exited before opening its control socket"
  (( SECONDS < deadline )) || fail "control socket $SOCKET_PATH did not appear within ${SOCKET_TIMEOUT_SECONDS}s"
  sleep 0.25
done

STEP="cmux app ping"
until CLI_TIMEOUT_SECONDS=5 cli --app-socket "$SOCKET_PATH" app ping >/dev/null 2>&1; do
  kill -0 "$APP_PID" 2>/dev/null || fail "app exited while waiting for app ping"
  (( SECONDS < deadline )) || fail "cmux app ping did not answer within ${SOCKET_TIMEOUT_SECONDS}s"
  sleep 0.5
done
echo "ok: cmux app ping"

# 3. Control socket protocol check.
STEP="cmux app identify --json"
IDENTIFY_JSON="$(cli --app-socket "$SOCKET_PATH" --json app identify)"
python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d, dict) and d, d' <<<"$IDENTIFY_JSON" \
  || fail "cmux app identify --json returned no JSON object: $IDENTIFY_JSON"
echo "ok: cmux app identify --json"

STEP="app still alive"
kill -0 "$APP_PID" 2>/dev/null || fail "app exited during the CLI smoke"

STEP="done"
echo "==> CLI smoke OK: bundled CLI drove $BUNDLE_ID over its socket"
