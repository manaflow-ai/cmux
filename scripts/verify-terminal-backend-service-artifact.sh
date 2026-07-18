#!/usr/bin/env bash

set -euo pipefail

APP_BUNDLE=""
EXPECTED_BUNDLE_ID=""
EXPECTED_ARCHITECTURES=""
REQUIRE_SIGNED=0
REQUIRE_MINIMAL_ENTITLEMENTS=0
REQUIRE_ENABLED=0
REQUIRE_DISABLED=0
SMOKE_HEADLESS=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDENTITY_TOOL="$SCRIPT_DIR/terminal-backend-identity.py"
EXPECTED_SIGNING_IDENTIFIER="com.cmuxterm.cmux-terminal-backend"
EXPECTED_RENDERER_SIGNING_IDENTIFIER="com.cmuxterm.cmux-terminal-renderer"
RENDERER_SMOKE_TOOL="$SCRIPT_DIR/test-terminal-renderer-helper.sh"

usage() {
  echo "Usage: ./scripts/verify-terminal-backend-service-artifact.sh --app-bundle <path> [--bundle-id <identifier>] [--architectures \"arm64 x86_64\"] [--require-signed] [--require-minimal-entitlements] [--require-enabled | --require-disabled] [--smoke-headless]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-bundle)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      APP_BUNDLE="$2"
      shift 2
      ;;
    --bundle-id)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      EXPECTED_BUNDLE_ID="$2"
      shift 2
      ;;
    --architectures)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      EXPECTED_ARCHITECTURES="$2"
      shift 2
      ;;
    --require-signed)
      REQUIRE_SIGNED=1
      shift
      ;;
    --require-minimal-entitlements)
      REQUIRE_MINIMAL_ENTITLEMENTS=1
      shift
      ;;
    --require-enabled)
      REQUIRE_ENABLED=1
      shift
      ;;
    --require-disabled)
      REQUIRE_DISABLED=1
      shift
      ;;
    --smoke-headless)
      SMOKE_HEADLESS=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$APP_BUNDLE" ]] || { echo "error: --app-bundle is required" >&2; exit 2; }
[[ -d "$APP_BUNDLE" ]] || { echo "error: app bundle not found: $APP_BUNDLE" >&2; exit 1; }
if [[ "$REQUIRE_ENABLED" -eq 1 && "$REQUIRE_DISABLED" -eq 1 ]]; then
  echo "error: --require-enabled and --require-disabled are mutually exclusive" >&2
  exit 2
fi

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || { echo "error: app Info.plist not found: $INFO_PLIST" >&2; exit 1; }
ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
if [[ -z "$EXPECTED_BUNDLE_ID" ]]; then
  EXPECTED_BUNDLE_ID="$ACTUAL_BUNDLE_ID"
fi
IFS=$'\t' read -r NORMALIZED_BUNDLE_ID IDENTITY_TOKEN SERVICE_LABEL PLIST_NAME EXPECTED_SESSION EXPECTED_SOCKET EXPECTED_STATE_NAMESPACE \
  <<< "$("$IDENTITY_TOOL" --bundle-id "$EXPECTED_BUNDLE_ID" --format tsv)"
[[ "$ACTUAL_BUNDLE_ID" == "$NORMALIZED_BUNDLE_ID" ]] || {
  echo "error: bundle identifier is $ACTUAL_BUNDLE_ID, expected $NORMALIZED_BUNDLE_ID" >&2
  exit 1
}
if [[ "$REQUIRE_ENABLED" -eq 1 || "$REQUIRE_DISABLED" -eq 1 ]]; then
  ENABLED_VALUE="$(/usr/libexec/PlistBuddy -c 'Print :CMUXTerminalBackendServiceEnabled' "$INFO_PLIST" 2>/dev/null || true)"
  NORMALIZED_ENABLED_VALUE="$(printf '%s' "$ENABLED_VALUE" | tr '[:upper:]' '[:lower:]')"
  if [[ "$REQUIRE_ENABLED" -eq 1 ]]; then
    case "$NORMALIZED_ENABLED_VALUE" in
      1|true|yes|on) ;;
      *) echo "error: terminal backend feature gate is not enabled in $INFO_PLIST" >&2; exit 1 ;;
    esac
  else
    case "$NORMALIZED_ENABLED_VALUE" in
      1|true|yes|on)
        echo "error: terminal backend production gate is enabled before live-PTY-safe upgrades are verified" >&2
        exit 1
        ;;
      *) ;;
    esac
  fi
fi

PLIST="$APP_BUNDLE/Contents/Library/LaunchAgents/$PLIST_NAME"
EXECUTABLE="$APP_BUNDLE/Contents/Resources/bin/cmux-terminal-backend"
BUILD_ID_FILE="${EXECUTABLE}.build-id"
RENDERER_EXECUTABLE="$APP_BUNDLE/Contents/Resources/bin/cmux-terminal-renderer"

[[ -x "$EXECUTABLE" ]] || { echo "error: terminal backend executable missing: $EXECUTABLE" >&2; exit 1; }
[[ -r "$BUILD_ID_FILE" ]] || { echo "error: terminal backend build ID missing: $BUILD_ID_FILE" >&2; exit 1; }
[[ -x "$RENDERER_EXECUTABLE" ]] || { echo "error: terminal renderer executable missing: $RENDERER_EXECUTABLE" >&2; exit 1; }
[[ -r "$PLIST" ]] || { echo "error: terminal backend launch-agent plist missing: $PLIST" >&2; exit 1; }
/usr/bin/plutil -lint "$PLIST" >/dev/null

PACKAGED_BUILD_ID="$(tr -d '[:space:]' < "$BUILD_ID_FILE")"
[[ "$PACKAGED_BUILD_ID" =~ ^[0-9a-f]{64}$ ]] || {
  echo "error: terminal backend build ID is not a lowercase SHA-256: $PACKAGED_BUILD_ID" >&2
  exit 1
}
REPORTED_BUILD_ID="$($EXECUTABLE --build-id)"
[[ "$REPORTED_BUILD_ID" == "$PACKAGED_BUILD_ID" ]] || {
  echo "error: terminal backend reports build ID $REPORTED_BUILD_ID, packaged sidecar has $PACKAGED_BUILD_ID" >&2
  exit 1
}

expect_plist_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST")"
  [[ "$actual" == "$expected" ]] || {
    echo "error: $PLIST $key is $actual, expected $expected" >&2
    exit 1
  }
}

expect_plist_value Label "$SERVICE_LABEL"
expect_plist_value BundleProgram "Contents/Resources/bin/cmux-terminal-backend"
expect_plist_value ProgramArguments:0 "cmux-terminal-backend"
expect_plist_value ProgramArguments:1 "--headless"
expect_plist_value ProgramArguments:2 "--app-service-layout"
expect_plist_value ProgramArguments:3 "--session"
expect_plist_value ProgramArguments:4 "$EXPECTED_SESSION"

PROGRAM_ARGUMENT_COUNT="$(/usr/bin/plutil -extract ProgramArguments raw -o - "$PLIST")"
[[ "$PROGRAM_ARGUMENT_COUNT" -eq 5 ]] || {
  echo "error: expected exactly five terminal backend program arguments" >&2
  exit 1
}

if [[ -n "$EXPECTED_ARCHITECTURES" ]]; then
  for executable in "$EXECUTABLE" "$RENDERER_EXECUTABLE"; do
    ACTUAL_ARCHITECTURES="$(/usr/bin/lipo -archs "$executable")"
    for architecture in $EXPECTED_ARCHITECTURES; do
      case " $ACTUAL_ARCHITECTURES " in
        *" $architecture "*) ;;
        *) echo "error: $(basename "$executable") is missing architecture $architecture ($ACTUAL_ARCHITECTURES)" >&2; exit 1 ;;
      esac
    done
  done
fi

if [[ "$REQUIRE_SIGNED" -eq 1 ]]; then
  /usr/bin/codesign --verify --strict --verbose=2 "$EXECUTABLE"
  /usr/bin/codesign --verify --strict --verbose=2 "$RENDERER_EXECUTABLE"
  ACTUAL_SIGNING_IDENTIFIER="$(/usr/bin/codesign -dvv "$EXECUTABLE" 2>&1 | sed -n 's/^Identifier=//p')"
  [[ "$ACTUAL_SIGNING_IDENTIFIER" == "$EXPECTED_SIGNING_IDENTIFIER" ]] || {
    echo "error: terminal backend signing identifier is $ACTUAL_SIGNING_IDENTIFIER, expected $EXPECTED_SIGNING_IDENTIFIER" >&2
    exit 1
  }
  ACTUAL_RENDERER_SIGNING_IDENTIFIER="$(/usr/bin/codesign -dvv "$RENDERER_EXECUTABLE" 2>&1 | sed -n 's/^Identifier=//p')"
  [[ "$ACTUAL_RENDERER_SIGNING_IDENTIFIER" == "$EXPECTED_RENDERER_SIGNING_IDENTIFIER" ]] || {
    echo "error: terminal renderer signing identifier is $ACTUAL_RENDERER_SIGNING_IDENTIFIER, expected $EXPECTED_RENDERER_SIGNING_IDENTIFIER" >&2
    exit 1
  }
fi
if [[ "$REQUIRE_MINIMAL_ENTITLEMENTS" -eq 1 ]]; then
  [[ "$REQUIRE_SIGNED" -eq 1 ]] || {
    echo "error: --require-minimal-entitlements requires --require-signed" >&2
    exit 2
  }
  for executable in "$EXECUTABLE" "$RENDERER_EXECUTABLE"; do
    ENTITLEMENTS_OUTPUT="$(/usr/bin/codesign -d --entitlements :- "$executable" 2>&1)"
    if grep -q '<key>' <<< "$ENTITLEMENTS_OUTPUT"; then
      echo "error: $(basename "$executable") carries entitlements beyond its dedicated empty profile" >&2
      echo "$ENTITLEMENTS_OUTPUT" >&2
      exit 1
    fi
  done
fi

if [[ "$SMOKE_HEADLESS" -eq 1 ]]; then
  SMOKE_ROOT="$(mktemp -d /tmp/cmux-backend-smoke.XXXXXX)"
  SMOKE_LOG="$SMOKE_ROOT/backend.log"
  SMOKE_IDENTIFY="$SMOKE_ROOT/identify.json"
  SMOKE_PING="$SMOKE_ROOT/ping.json"
  SMOKE_SESSION="artifact-smoke-$$-${RANDOM}"
  SMOKE_RUNTIME_DIR="/tmp/cmux-tui-$(id -u)"
  SMOKE_SOCKET="$SMOKE_RUNTIME_DIR/$SMOKE_SESSION.sock"
  IFS=$'\t' read -r SMOKE_STATE_RECORD SMOKE_STATE_LOCK <<< "$(/usr/bin/python3 - "$SMOKE_SESSION" <<'PY'
import os
import pathlib
import pwd
import sys
import uuid

session = sys.argv[1]
home = pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir)
root = home / "Library" / "Application Support" / "cmux-tui" / "state"
key = uuid.uuid5(uuid.UUID("9f872e39-dcd4-4d89-a43f-29771b35754a"), session)
print(root / "sessions" / f"{key}.json", root / "locks" / f"{key}.lock", sep="\t")
PY
  )"
  SMOKE_PID=""
  SMOKE_RUNTIME_OWNED=0

  stop_smoke_process() {
    [[ -n "$SMOKE_PID" ]] || return 0
    if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
      wait "$SMOKE_PID" 2>/dev/null || true
      SMOKE_PID=""
      return 0
    fi
    kill -TERM "$SMOKE_PID" 2>/dev/null || true
    local process_state=""
    for _ in {1..200}; do
      process_state="$(ps -o stat= -p "$SMOKE_PID" 2>/dev/null | tr -d '[:space:]')"
      if [[ -z "$process_state" || "$process_state" == Z* ]]; then
        wait "$SMOKE_PID" 2>/dev/null || true
        SMOKE_PID=""
        return 0
      fi
      sleep 0.05
    done
    kill -KILL "$SMOKE_PID" 2>/dev/null || true
    for _ in {1..40}; do
      process_state="$(ps -o stat= -p "$SMOKE_PID" 2>/dev/null | tr -d '[:space:]')"
      if [[ -z "$process_state" || "$process_state" == Z* ]]; then
        wait "$SMOKE_PID" 2>/dev/null || true
        SMOKE_PID=""
        return 124
      fi
      sleep 0.05
    done
    return 124
  }

  cleanup_smoke() {
    stop_smoke_process >/dev/null 2>&1 || true
    if [[ "$SMOKE_RUNTIME_OWNED" -eq 1 ]]; then
      rm -f -- "$SMOKE_SOCKET" "$SMOKE_STATE_RECORD" "$SMOKE_STATE_LOCK"
    fi
    rm -rf "$SMOKE_ROOT"
  }
  trap cleanup_smoke EXIT

  [[ ! -e "$SMOKE_SOCKET" && ! -e "$SMOKE_STATE_RECORD" && ! -e "$SMOKE_STATE_LOCK" ]] || {
    echo "error: unique app-service smoke paths unexpectedly exist" >&2
    exit 1
  }
  SMOKE_RUNTIME_OWNED=1

  # Launch the helper with the exact argument shape embedded in the SMAppService plist.
  "$EXECUTABLE" \
    --headless \
    --app-service-layout \
    --session "$SMOKE_SESSION" \
    >"$SMOKE_LOG" 2>&1 &
  SMOKE_PID=$!

  # Identify and ping share one absolute deadline. Each identify attempt is
  # separately capped so a stale socket cannot consume the entire budget in
  # the CLI's own read timeout.
  if ! /usr/bin/python3 - \
    "$EXECUTABLE" \
    "$SMOKE_SOCKET" \
    "$SMOKE_IDENTIFY" \
    "$SMOKE_PING" \
    "$SMOKE_LOG" \
    "$SMOKE_PID" <<'PY'
import os
import pathlib
import subprocess
import sys
import time

executable, socket_path, identify_path, ping_path, log_path, pid_text = sys.argv[1:]
backend_pid = int(pid_text)
deadline = time.monotonic() + 10.0


def remaining() -> float:
    value = deadline - time.monotonic()
    if value <= 0:
        raise TimeoutError("terminal backend readiness exceeded one 10-second deadline")
    return value


def backend_alive() -> bool:
    try:
        os.kill(backend_pid, 0)
        return True
    except ProcessLookupError:
        return False


def run_cli(command: str, output_path: str, timeout: float) -> bool:
    with open(output_path, "wb") as output, open(log_path, "ab") as log:
        try:
            result = subprocess.run(
                [executable, "--socket", socket_path, "--json", command],
                stdout=output,
                stderr=log,
                timeout=timeout,
                check=False,
            )
        except subprocess.TimeoutExpired:
            return False
    return result.returncode == 0


try:
    identified = False
    while not identified:
        if not backend_alive():
            raise RuntimeError("terminal backend exited before becoming ready")
        budget = remaining()
        if pathlib.Path(socket_path).is_socket():
            identified = run_cli("identify", identify_path, min(0.25, budget))
        if not identified:
            time.sleep(min(0.05, remaining()))

    if not run_cli("ping", ping_path, remaining()):
        raise RuntimeError("terminal backend ping failed within the readiness deadline")
except (OSError, RuntimeError, TimeoutError) as error:
    print(f"error: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
  then
    sed -n '1,120p' "$SMOKE_LOG" >&2
    exit 1
  fi

  /usr/bin/python3 - "$SMOKE_IDENTIFY" "$SMOKE_PING" "$SMOKE_SESSION" "$SMOKE_PID" <<'PY'
import json
import pathlib
import sys

identify_path, ping_path, expected_session, expected_pid = sys.argv[1:]
payload = json.loads(pathlib.Path(identify_path).read_text(encoding="utf-8"))
ping = json.loads(pathlib.Path(ping_path).read_text(encoding="utf-8"))
required_capabilities = {
    "canonical-topology-snapshot-v1",
    "durable-session-identity-v1",
    "presentation-registry-v1",
    "stable-entity-uuid-v1",
    "topology-resume-v1",
}
assert payload.get("app") == "cmux-tui", payload
assert payload.get("session") == expected_session, payload
assert payload.get("pid") == int(expected_pid), payload
assert payload.get("protocol_min") <= 8 <= payload.get("protocol_max"), payload
missing = required_capabilities.difference(payload.get("capabilities", []))
assert not missing, f"missing terminal-authority capabilities: {sorted(missing)}"
assert ping.get("session") == expected_session, ping
assert ping.get("pid") == int(expected_pid), ping
assert ping.get("daemon_instance_id") == payload.get("daemon_instance_id"), (payload, ping)
assert ping.get("session_id") == payload.get("session_id"), (payload, ping)
assert ping.get("canonical_topology_revision") >= payload.get("canonical_topology_revision"), (payload, ping)
PY

  if ! stop_smoke_process; then
    echo "error: terminal backend did not stop within the bounded shutdown deadline" >&2
    exit 1
  fi
  [[ ! -e "$SMOKE_SOCKET" ]] || {
    echo "error: terminal backend left its control socket behind after shutdown" >&2
    exit 1
  }
  trap - EXIT
  cleanup_smoke
  "$RENDERER_SMOKE_TOOL" "$RENDERER_EXECUTABLE"
fi

echo "Terminal backend service artifact verified: $SERVICE_LABEL ($EXPECTED_SESSION)"
