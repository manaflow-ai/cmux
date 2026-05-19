#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/leak-smoke-ci.sh [app-path]

Launch a Debug cmux app with malloc stack logging, take a baseline leaks
snapshot, exercise workspace churn through the socket CLI, and fail if the
churn introduces new leaks.

Environment:
  CMUX_LEAK_SMOKE_TAG       Socket/app tag. Default: ci-leaks
  CMUX_LEAK_SMOKE_CYCLES    Workspace churn cycles. Default: 6
  CMUX_LEAK_SMOKE_OUT_DIR   Output directory. Default: /tmp/cmux-leak-smoke
EOF
}

sanitize_path() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="ci-leaks"
  fi
  echo "$cleaned"
}

find_debug_app() {
  find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path "*/Build/Products/Debug/cmux DEV.app" \
    -exec stat -f '%m %N' {} \; 2>/dev/null \
    | sort -nr \
    | head -1 \
    | cut -d' ' -f2-
}

parse_leak_summary() {
  local file="$1"
  sed -nE 's/^Process [0-9]+: ([0-9]+) leaks for ([0-9]+) total leaked bytes\./\1 \2/p' "$file" | tail -1
}

wait_for_socket() {
  local pid="$1"
  local socket_path="$2"
  local deadline=$((SECONDS + 45))

  while (( SECONDS < deadline )); do
    if [[ -S "$socket_path" ]]; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "ERROR: cmux exited while waiting for socket at $socket_path" >&2
      print_launch_logs
      return 1
    fi
    sleep 0.25
  done

  echo "ERROR: socket not ready after 45s at $socket_path" >&2
  print_launch_logs
  return 1
}

wait_for_cli() {
  local cli="$1"
  local socket_path="$2"
  local pid="$3"
  local deadline=$((SECONDS + 20))

  while (( SECONDS < deadline )); do
    if CMUX_SOCKET_PATH="$socket_path" "$cli" ping >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "ERROR: cmux exited while waiting for CLI ping" >&2
      print_launch_logs
      return 1
    fi
    sleep 0.25
  done

  echo "ERROR: cmux CLI did not respond to ping" >&2
  print_launch_logs
  return 1
}

print_launch_logs() {
  for log_path in "$STDOUT_LOG" "$STDERR_LOG"; do
    if [[ -s "$log_path" ]]; then
      echo "--- ${log_path} ---" >&2
      tail -80 "$log_path" >&2 || true
    fi
  done
}

launch_direct() {
  env \
    MallocStackLogging=1 \
    MallocStackLoggingNoCompact=1 \
    CMUX_TAG="$TAG_SLUG" \
    CMUX_SOCKET_MODE=allowAll \
    CMUX_ALLOW_SOCKET_OVERRIDE=1 \
    CMUX_SOCKET_PATH="$SOCKET_PATH" \
    CMUXD_UNIX_PATH="$CMUXD_SOCKET_PATH" \
    CMUX_UI_TEST_MODE=1 \
    CMUX_DISABLE_SESSION_RESTORE=1 \
    "$BINARY" >"$STDOUT_LOG" 2>"$STDERR_LOG" &
  APP_PID=$!
}

launch_open() {
  open -n -g \
    --stdout "$STDOUT_LOG" \
    --stderr "$STDERR_LOG" \
    --env MallocStackLogging=1 \
    --env MallocStackLoggingNoCompact=1 \
    --env CMUX_TAG="$TAG_SLUG" \
    --env CMUX_SOCKET_MODE=allowAll \
    --env CMUX_ALLOW_SOCKET_OVERRIDE=1 \
    --env CMUX_SOCKET_PATH="$SOCKET_PATH" \
    --env CMUXD_UNIX_PATH="$CMUXD_SOCKET_PATH" \
    --env CMUX_UI_TEST_MODE=1 \
    --env CMUX_DISABLE_SESSION_RESTORE=1 \
    "$APP"

  for _ in $(seq 1 40); do
    APP_PID="$(pgrep -n -f "$APP/Contents/MacOS/cmux DEV" || true)"
    if [[ -n "$APP_PID" ]]; then
      return 0
    fi
    sleep 0.25
  done

  echo "ERROR: launched with open, but could not find cmux process for $APP" >&2
  print_launch_logs
  return 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

APP="${1:-${CMUX_LEAK_SMOKE_APP:-}}"
if [[ -z "$APP" ]]; then
  APP="$(find_debug_app)"
fi

if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "ERROR: Debug cmux app not found. Pass app-path or set CMUX_LEAK_SMOKE_APP." >&2
  exit 1
fi

BINARY="$APP/Contents/MacOS/cmux DEV"
CLI="$APP/Contents/Resources/bin/cmux"
if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: app binary not executable: $BINARY" >&2
  exit 1
fi
if [[ ! -x "$CLI" ]]; then
  echo "ERROR: bundled cmux CLI not executable: $CLI" >&2
  exit 1
fi
if ! command -v leaks >/dev/null 2>&1; then
  echo "ERROR: leaks tool not found" >&2
  exit 1
fi

TAG="${CMUX_LEAK_SMOKE_TAG:-ci-leaks}"
TAG_SLUG="$(sanitize_path "$TAG")"
CYCLES="${CMUX_LEAK_SMOKE_CYCLES:-6}"
OUT_DIR="${CMUX_LEAK_SMOKE_OUT_DIR:-/tmp/cmux-leak-smoke}"
SOCKET_PATH="/tmp/cmux-debug-${TAG_SLUG}.sock"
CMUXD_SOCKET_PATH="$HOME/Library/Application Support/cmux/cmuxd-dev-${TAG_SLUG}.sock"
STDOUT_LOG="$OUT_DIR/cmux.log"
STDERR_LOG="$OUT_DIR/cmux.err"
BASELINE_LOG="$OUT_DIR/leaks-baseline.txt"
BASELINE_GRAPH="$OUT_DIR/baseline.memgraph"
DIFF_LOG="$OUT_DIR/leaks-diff.txt"

if [[ ! "$CYCLES" =~ ^[0-9]+$ || "$CYCLES" -lt 1 ]]; then
  echo "ERROR: CMUX_LEAK_SMOKE_CYCLES must be a positive integer" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
rm -f "$SOCKET_PATH" "$CMUXD_SOCKET_PATH" "$BASELINE_LOG" "$BASELINE_GRAPH" "$DIFF_LOG" "$STDOUT_LOG" "$STDERR_LOG"

APP_PID=""
cleanup() {
  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$SOCKET_PATH" "$CMUXD_SOCKET_PATH"
}
trap cleanup EXIT

echo "=== cmux leak smoke ==="
echo "app: $APP"
echo "tag: $TAG_SLUG"
echo "socket: $SOCKET_PATH"
echo "out: $OUT_DIR"

launch_direct
echo "pid: $APP_PID"

if ! wait_for_socket "$APP_PID" "$SOCKET_PATH"; then
  echo "Direct executable launch did not reach the socket; retrying via LaunchServices..."
  kill "$APP_PID" >/dev/null 2>&1 || true
  wait "$APP_PID" >/dev/null 2>&1 || true
  APP_PID=""
  rm -f "$SOCKET_PATH" "$CMUXD_SOCKET_PATH" "$STDOUT_LOG" "$STDERR_LOG"
  launch_open
  echo "pid: $APP_PID"
  wait_for_socket "$APP_PID" "$SOCKET_PATH"
fi
wait_for_cli "$CLI" "$SOCKET_PATH" "$APP_PID"

echo "Capturing baseline leaks graph..."
set +e
leaks --quiet --outputGraph="$BASELINE_GRAPH" "$APP_PID" >"$BASELINE_LOG" 2>&1
BASELINE_STATUS=$?
set -e
cat "$BASELINE_LOG"
if [[ ! -f "$BASELINE_GRAPH" ]]; then
  echo "ERROR: leaks did not produce baseline graph: $BASELINE_GRAPH" >&2
  exit 1
fi
if [[ "$BASELINE_STATUS" -ne 0 ]]; then
  echo "Baseline leaks status was $BASELINE_STATUS; continuing because the diff gate only fails on new leaks."
fi

echo "Running workspace churn..."
refs=()
for i in $(seq 1 "$CYCLES"); do
  out="$(
    CMUX_SOCKET_PATH="$SOCKET_PATH" "$CLI" \
      new-workspace \
      --name "leak-smoke-$i" \
      --cwd "$PWD" \
      --command "printf 'leak-smoke-$i\\n'" \
      --focus true
  )"
  ref="$(printf '%s\n' "$out" | awk '/OK/{print $2}')"
  if [[ -z "$ref" ]]; then
    echo "ERROR: failed to parse workspace ref from: $out" >&2
    exit 1
  fi
  refs+=("$ref")
  CMUX_SOCKET_PATH="$SOCKET_PATH" "$CLI" send --workspace "$ref" "printf 'typed-$i\\n'" >/dev/null
  CMUX_SOCKET_PATH="$SOCKET_PATH" "$CLI" read-screen --workspace "$ref" --lines 5 >/dev/null || true
done

CMUX_SOCKET_PATH="$SOCKET_PATH" "$CLI" select-workspace --workspace workspace:1 >/dev/null || true
for ref in "${refs[@]}"; do
  CMUX_SOCKET_PATH="$SOCKET_PATH" "$CLI" close-workspace --workspace "$ref" >/dev/null || true
done

echo "Checking for new leaks..."
set +e
leaks --quiet --list --diffFrom="$BASELINE_GRAPH" "$APP_PID" >"$DIFF_LOG" 2>&1
DIFF_STATUS=$?
set -e
cat "$DIFF_LOG"

summary="$(parse_leak_summary "$DIFF_LOG" || true)"
if [[ -z "$summary" ]]; then
  if [[ "$DIFF_STATUS" -ne 0 ]]; then
    echo "ERROR: leaks failed without a parseable summary" >&2
    exit "$DIFF_STATUS"
  fi
  echo "ERROR: leaks output did not include a parseable summary" >&2
  exit 1
fi

read -r leak_count leaked_bytes <<<"$summary"
if [[ "$leak_count" -ne 0 || "$leaked_bytes" -ne 0 ]]; then
  echo "ERROR: leak smoke introduced $leak_count leaks ($leaked_bytes bytes)" >&2
  exit 1
fi

echo "=== cmux leak smoke passed: no new leaks ==="
