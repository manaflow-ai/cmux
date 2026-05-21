#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: Tests/test_cmuxonly_access_denied_cli.sh --tag <tag> [--iterations <n>]

Runs the tagged debug app twice:
  1. automation mode control, where an external CLI ping must return PONG
  2. cmuxOnly mode, where a non-descendant CLI ping must return Access denied

This guards against regressing cmuxOnly rejections into client-side Broken pipe
transport errors.
EOF
}

sanitize_path() {
  local raw="$1"
  local cleaned
  cleaned="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="agent"
  fi
  printf '%s\n' "$cleaned"
}

sanitize_bundle() {
  local raw="$1"
  local cleaned
  cleaned="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\\.+//; s/\\.+$//; s/\\.+/./g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="agent"
  fi
  printf '%s\n' "$cleaned"
}

TAG=""
ITERATIONS=25

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      shift 2
      ;;
    --iterations)
      ITERATIONS="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$TAG" ]]; then
  echo "error: --tag is required" >&2
  usage >&2
  exit 2
fi

if ! [[ "$ITERATIONS" =~ ^[0-9]+$ ]] || [[ "$ITERATIONS" -lt 1 ]]; then
  echo "error: --iterations must be a positive integer" >&2
  exit 2
fi

TAG_SLUG="$(sanitize_path "$TAG")"
TAG_ID="$(sanitize_bundle "$TAG")"
APP="${CMUX_TEST_APP_PATH:-$HOME/Library/Developer/Xcode/DerivedData/cmux-${TAG_SLUG}/Build/Products/Debug/cmux DEV ${TAG}.app}"
BIN="$APP/Contents/MacOS/cmux DEV"
CLI="${CMUX_TEST_CLI_PATH:-$APP/Contents/Resources/bin/cmux}"
SOCK="/tmp/cmux-debug-${TAG_SLUG}.sock"
CMUXD_SOCK="$HOME/Library/Application Support/cmux/cmuxd-dev-${TAG_SLUG}.sock"
DEBUG_LOG="/tmp/cmux-debug-${TAG_SLUG}.log"
LAUNCH_LOG="/tmp/cmux-launch-${TAG_SLUG}-access-denied-test.out"
BUNDLE_ID="com.cmuxterm.app.debug.${TAG_ID}"

if [[ ! -x "$BIN" ]]; then
  echo "error: app binary not found or not executable: $BIN" >&2
  exit 2
fi

if [[ ! -x "$CLI" ]]; then
  echo "error: bundled CLI not found or not executable: $CLI" >&2
  exit 2
fi

APP_PID=""
CONTROL_OUT=""
CONTROL_ERR=""
CONTROL_V2_OUT=""
CONTROL_V2_ERR=""
DENIED_OUT=""
DENIED_ERR=""

cleanup() {
  if [[ -n "${APP_PID:-}" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
    APP_PID=""
  fi
  pkill -f "cmux DEV ${TAG}.app/Contents/MacOS/cmux DEV" >/dev/null 2>&1 || true
  rm -f "$SOCK" "$CMUXD_SOCK" "$DEBUG_LOG" "$LAUNCH_LOG"
  rm -f "$CONTROL_OUT" "$CONTROL_ERR" "$CONTROL_V2_OUT" "$CONTROL_V2_ERR" "$DENIED_OUT" "$DENIED_ERR"
}
trap cleanup EXIT

launch_app() {
  local mode="$1"
  cleanup
  mkdir -p "$(dirname "$CMUXD_SOCK")"
  CMUX_TAG="$TAG_SLUG" \
  CMUX_BUNDLE_ID="$BUNDLE_ID" \
  CMUX_SOCKET_ENABLE=1 \
  CMUX_SOCKET_MODE="$mode" \
  CMUX_SOCKET_PATH="$SOCK" \
  CMUXD_UNIX_PATH="$CMUXD_SOCK" \
  CMUX_DEBUG_LOG="$DEBUG_LOG" \
  CMUX_DISABLE_SESSION_RESTORE=1 \
  CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 \
  CMUXTERM_REPO_ROOT="${CMUXTERM_REPO_ROOT:-$PWD}" \
  CMUX_BUNDLED_CLI_PATH="$CLI" \
  CMUX_SHELL_INTEGRATION_DIR="$APP/Contents/Resources/shell-integration" \
  "$BIN" >"$LAUNCH_LOG" 2>&1 &
  APP_PID=$!

  local deadline=$((SECONDS + 20))
  while (( SECONDS < deadline )); do
    if [[ -S "$SOCK" ]]; then
      return 0
    fi
    if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
      echo "error: app exited before creating socket in $mode mode" >&2
      sed -n '1,120p' "$LAUNCH_LOG" >&2 || true
      exit 1
    fi
    sleep 0.1
  done

  echo "error: timed out waiting for socket in $mode mode: $SOCK" >&2
  sed -n '1,120p' "$LAUNCH_LOG" >&2 || true
  exit 1
}

run_cli_command() {
  local out_file="$1"
  local err_file="$2"
  shift 2
  set +e
  CMUX_CLI_SENTRY_DISABLED=1 "$CLI" --socket "$SOCK" "$@" >"$out_file" 2>"$err_file"
  local rc=$?
  set -e
  return "$rc"
}

CONTROL_OUT="$(mktemp -t cmux-access-control-out.XXXXXX)"
CONTROL_ERR="$(mktemp -t cmux-access-control-err.XXXXXX)"
CONTROL_V2_OUT="$(mktemp -t cmux-access-control-v2-out.XXXXXX)"
CONTROL_V2_ERR="$(mktemp -t cmux-access-control-v2-err.XXXXXX)"
DENIED_OUT="$(mktemp -t cmux-access-denied-out.XXXXXX)"
DENIED_ERR="$(mktemp -t cmux-access-denied-err.XXXXXX)"

launch_app automation
if ! run_cli_command "$CONTROL_OUT" "$CONTROL_ERR" ping; then
  echo "error: automation control ping failed" >&2
  echo "stdout:" >&2
  sed -n '1,40p' "$CONTROL_OUT" >&2 || true
  echo "stderr:" >&2
  sed -n '1,40p' "$CONTROL_ERR" >&2 || true
  exit 1
fi
if ! grep -Fxq "PONG" "$CONTROL_OUT"; then
  echo "error: automation control did not return PONG" >&2
  sed -n '1,40p' "$CONTROL_OUT" >&2 || true
  sed -n '1,40p' "$CONTROL_ERR" >&2 || true
  exit 1
fi
if ! run_cli_command "$CONTROL_V2_OUT" "$CONTROL_V2_ERR" capabilities; then
  echo "error: automation control v2 capabilities failed" >&2
  echo "stdout:" >&2
  sed -n '1,40p' "$CONTROL_V2_OUT" >&2 || true
  echo "stderr:" >&2
  sed -n '1,40p' "$CONTROL_V2_ERR" >&2 || true
  exit 1
fi

launch_app cmuxOnly

access_denied_count=0
broken_pipe_count=0
unexpected_success_count=0
unexpected_failure_count=0

for i in $(seq 1 "$ITERATIONS"); do
  for command in ping capabilities; do
    if run_cli_command "$DENIED_OUT" "$DENIED_ERR" "$command"; then
      unexpected_success_count=$((unexpected_success_count + 1))
      continue
    fi

    combined="$(cat "$DENIED_OUT" "$DENIED_ERR")"
    if grep -Fq "Broken pipe" <<<"$combined"; then
      broken_pipe_count=$((broken_pipe_count + 1))
    elif grep -Fq "Access denied" <<<"$combined"; then
      access_denied_count=$((access_denied_count + 1))
    else
      unexpected_failure_count=$((unexpected_failure_count + 1))
    fi
  done
done

attempts=$((ITERATIONS * 2))
printf 'automation_control=PONG\n'
printf 'automation_control_v2=ok\n'
printf 'iterations=%s\n' "$ITERATIONS"
printf 'attempts=%s\n' "$attempts"
printf 'access_denied=%s\n' "$access_denied_count"
printf 'broken_pipe=%s\n' "$broken_pipe_count"
printf 'unexpected_success=%s\n' "$unexpected_success_count"
printf 'unexpected_failure=%s\n' "$unexpected_failure_count"

if [[ "$broken_pipe_count" -ne 0 || "$unexpected_success_count" -ne 0 || "$unexpected_failure_count" -ne 0 ]]; then
  echo "error: cmuxOnly rejection did not consistently return Access denied" >&2
  echo "last stdout:" >&2
  sed -n '1,20p' "$DENIED_OUT" >&2 || true
  echo "last stderr:" >&2
  sed -n '1,20p' "$DENIED_ERR" >&2 || true
  exit 1
fi

if [[ "$access_denied_count" -ne "$attempts" ]]; then
  echo "error: expected every cmuxOnly attempt to return Access denied" >&2
  exit 1
fi
