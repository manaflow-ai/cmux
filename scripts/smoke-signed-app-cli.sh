#!/usr/bin/env bash
# Feature smoke for a signed cmux app bundle: launch the app, then drive it
# through the CLI bundled inside the same .app over its control socket.
#
# smoke-launch-macos-app.sh only proves the process stays alive. This script
# proves the shipped CLI and the shipped app agree on the socket protocol and
# that a basic workspace round trip works in the Release build.
#
# Usage: smoke-signed-app-cli.sh <app-path>
#
# CI only: cmux enforces a single instance per bundle id, so launching a
# bundle whose channel you are using on this Mac terminates your running copy.
#
# Environment:
#   CMUX_CLI_SMOKE_SOCKET_TIMEOUT_SECONDS  wait for the socket (default 45)
#   CMUX_CLI_SMOKE_WINDOW_TIMEOUT_SECONDS  wait for the first workspace (default 30)
#   CMUX_CLI_SMOKE_REQUIRED_HELP_COMMANDS  space separated commands `--help` must list
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
  else
    echo "SKIP: cannot run the CLI smoke for an app built for '$APP_ARCHS' on a $HOST_ARCH host (Rosetta unavailable)"
    exit 0
  fi
fi

SOCKET_TIMEOUT_SECONDS="${CMUX_CLI_SMOKE_SOCKET_TIMEOUT_SECONDS:-45}"
WINDOW_TIMEOUT_SECONDS="${CMUX_CLI_SMOKE_WINDOW_TIMEOUT_SECONDS:-30}"
REQUIRED_HELP_COMMANDS="${CMUX_CLI_SMOKE_REQUIRED_HELP_COMMANDS:-ping capabilities identify list-workspaces new-workspace close-workspace remote-daemon-status version}"

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
    pkill -f "$APP_PATH/Contents/Resources/bin/cmux-tui" 2>/dev/null || true
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
  local timeout_seconds="${CLI_TIMEOUT_SECONDS:-20}"
  local out_file="$WORK_DIR/cli.out"
  local err_file="$WORK_DIR/cli.err"
  # Drop caller context a cmux terminal would export, so a local run inside
  # cmux cannot route these commands at the caller's own workspace.
  env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID -u CMUX_TAB_ID -u CMUX_PANEL_ID \
    -u CMUX_SOCKET_PASSWORD CMUX_SOCKET_PATH="$SOCKET_PATH" \
    "$CLI_PATH" --socket "$SOCKET_PATH" "$@" >"$out_file" 2>"$err_file" &
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

json_field() {
  # json_field <python expression over `d`>; reads JSON on stdin.
  python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"
}

echo "==> CLI smoke for $APP_PATH ($BUNDLE_ID $SHORT_VERSION build $BUILD_VERSION)"

# 1. Socket-free CLI checks.
STEP="cmux --version"
VERSION_OUT="$(cli --version)"
EXPECTED_VERSION_PREFIX="cmux $SHORT_VERSION ($BUILD_VERSION)"
[[ "$VERSION_OUT" == "$EXPECTED_VERSION_PREFIX"* ]] \
  || fail "bundled CLI reports '$VERSION_OUT', expected it to start with '$EXPECTED_VERSION_PREFIX'"
echo "ok: $VERSION_OUT"

STEP="cmux --help"
HELP_OUT="$(cli --help)"
missing_help=()
for command in $REQUIRED_HELP_COMMANDS; do
  if ! grep -Eq "^[[:space:]]+${command}([[:space:]]|$)" <<<"$HELP_OUT"; then
    missing_help+=("$command")
  fi
done
(( ${#missing_help[@]} == 0 )) || fail "cmux --help is missing top-level commands: ${missing_help[*]}"
echo "ok: --help lists $REQUIRED_HELP_COMMANDS"

STEP="cmux remote-daemon-status"
DAEMON_JSON="$(cli --json remote-daemon-status)"
[[ "$(json_field 'd.get("manifest_present")' <<<"$DAEMON_JSON")" == "True" ]] \
  || fail "remote-daemon-status reports no embedded SSH daemon manifest: $DAEMON_JSON"
echo "ok: remote daemon manifest present ($(json_field 'd.get("release_tag")' <<<"$DAEMON_JSON"), $(json_field 'd.get("asset_name")' <<<"$DAEMON_JSON"))"

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

STEP="cmux ping"
PING_OUT=""
until PING_OUT="$(CLI_TIMEOUT_SECONDS=5 cli ping 2>/dev/null)" && [[ "$PING_OUT" == "PONG" ]]; do
  kill -0 "$APP_PID" 2>/dev/null || fail "app exited while waiting for ping"
  (( SECONDS < deadline )) || fail "ping did not answer PONG within ${SOCKET_TIMEOUT_SECONDS}s (last: '$PING_OUT')"
  sleep 0.5
done
echo "ok: ping -> PONG"

# 3. Socket protocol checks.
STEP="cmux capabilities"
CAPS_JSON="$(cli --json capabilities)"
missing_methods="$(python3 -c '
import json, sys
methods = set(json.load(sys.stdin).get("methods", []))
required = ["system.ping", "system.identify", "workspace.list", "workspace.create", "workspace.close"]
print(" ".join(m for m in required if m not in methods))
' <<<"$CAPS_JSON")"
[[ -z "$missing_methods" ]] || fail "capabilities is missing socket methods: $missing_methods"
echo "ok: capabilities lists workspace.list/create/close"

STEP="cmux workspace list (initial window)"
deadline=$((SECONDS + WINDOW_TIMEOUT_SECONDS))
while :; do
  LIST_JSON="$(CLI_TIMEOUT_SECONDS=10 cli --json --id-format uuids workspace list 2>/dev/null || true)"
  initial_count=0
  if [[ -n "$LIST_JSON" ]]; then
    initial_count="$(json_field 'len(d.get("workspaces", []))' <<<"$LIST_JSON" 2>/dev/null || echo 0)"
  fi
  (( initial_count > 0 )) && break
  kill -0 "$APP_PID" 2>/dev/null || fail "app exited before its first workspace appeared"
  (( SECONDS < deadline )) || fail "no workspace appeared within ${WINDOW_TIMEOUT_SECONDS}s (last list: ${LIST_JSON:-<empty>})"
  sleep 0.5
done
echo "ok: $initial_count workspace(s) at startup"

# 4. Workspace round trip: create, see it listed, close it, see it gone.
SMOKE_NAME="cli-smoke-$$-$RANDOM"
STEP="cmux workspace create"
CREATE_JSON=""
CREATE_ERR="$WORK_DIR/create.err"

workspace_id_for_title() {
  python3 -c '
import json, sys
title = sys.argv[1]
for ws in json.load(sys.stdin).get("workspaces", []):
    if ws.get("title") == title:
        print(ws.get("id") or ws.get("ref") or "")
        break
' "$1"
}

if CREATE_JSON="$(cli --json --id-format uuids workspace create --name "$SMOKE_NAME" --focus false 2>"$CREATE_ERR")"; then
  WS_ID="$(json_field 'd.get("workspace_id") or ""' <<<"$CREATE_JSON")"
else
  # Rosetta can take longer than cmux-tui's terminal-start deadline. The
  # request may still finish after the CLI receives the typed timeout, so
  # accept it only when the named workspace becomes observable.
  WS_ID=""
  if grep -Fq "terminal may still appear" "$CREATE_ERR"; then
    echo "workspace create timed out after dispatch; waiting for the workspace to appear"
    deadline=$((SECONDS + WINDOW_TIMEOUT_SECONDS))
    while (( SECONDS < deadline )); do
      LIST_JSON="$(CLI_TIMEOUT_SECONDS=10 cli --json --id-format uuids workspace list 2>/dev/null || true)"
      if [[ -n "$LIST_JSON" ]]; then
        WS_ID="$(workspace_id_for_title "$SMOKE_NAME" <<<"$LIST_JSON" 2>/dev/null || true)"
        [[ -n "$WS_ID" ]] && break
      fi
      kill -0 "$APP_PID" 2>/dev/null || fail "app exited while waiting for timed-out workspace create"
      sleep 0.5
    done
  fi
  if [[ -z "$WS_ID" ]]; then
    cat "$CREATE_ERR" >&2
    fail "workspace create returned no workspace_id"
  fi
fi
[[ -n "$WS_ID" ]] || fail "workspace create returned no workspace_id: ${CREATE_JSON:-<empty>}"
echo "ok: created workspace $WS_ID"

workspace_titles_for_id() {
  python3 -c '
import json, sys
ws_id = sys.argv[1]
for ws in json.load(sys.stdin).get("workspaces", []):
    if ws.get("id") == ws_id:
        print(ws.get("title") or "")
' "$1"
}

STEP="cmux workspace list (after create)"
LIST_JSON="$(cli --json --id-format uuids workspace list)"
listed_title="$(workspace_titles_for_id "$WS_ID" <<<"$LIST_JSON")"
[[ "$listed_title" == "$SMOKE_NAME" ]] \
  || fail "workspace $WS_ID is not listed with title '$SMOKE_NAME' (got '$listed_title'): $LIST_JSON"
echo "ok: workspace list shows '$SMOKE_NAME'"

STEP="cmux workspace close"
cli --json --id-format uuids workspace close --workspace "$WS_ID" --confirm >/dev/null

STEP="cmux workspace list (after close)"
deadline=$((SECONDS + 10))
while :; do
  LIST_JSON="$(cli --json --id-format uuids workspace list)"
  [[ -z "$(workspace_titles_for_id "$WS_ID" <<<"$LIST_JSON")" ]] && break
  (( SECONDS < deadline )) || fail "workspace $WS_ID is still listed 10s after close: $LIST_JSON"
  sleep 0.25
done
echo "ok: workspace closed"

STEP="app still alive"
kill -0 "$APP_PID" 2>/dev/null || fail "app exited during the CLI smoke"

STEP="done"
echo "==> CLI smoke OK: bundled CLI drove $BUNDLE_ID over its socket"
