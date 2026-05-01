#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
cd "$ROOT"

command -v xcodebuildmcp >/dev/null

PORT="${COMEUP_TEXT_PORT:-17891}"
SIMULATOR_ID="${COMEUP_SIMULATOR_ID:-}"
SIMULATOR_NAME="${COMEUP_SIMULATOR_NAME:-iPhone 17 Pro}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/comeup-sim-sync.XXXXXX")"
SOCKET="$WORK_DIR/comeup.sock"
SERVER_LOG="$WORK_DIR/comeup-server.log"
CMX_LOG="$WORK_DIR/cmx-pty-recorder.log"
DERIVED_DATA="$WORK_DIR/DerivedData"
AUTH_TOKEN="${COMEUP_AUTH_TOKEN:-comeup-sim-auth-token}"
CMX_SENTINEL="CMX_SENTINEL_TO_SIM"
SIM_SENTINEL="SIM_SENTINEL_FROM_IOS"
SERVER_PID=""
CMX_PID=""

cleanup() {
  local status=$?
  set +e
  if [[ -n "$CMX_PID" ]]; then
    kill "$CMX_PID" 2>/dev/null
    wait "$CMX_PID" 2>/dev/null
  fi
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  if [[ "$status" -eq 0 && "${COMEUP_KEEP_LOGS:-0}" != "1" ]]; then
    rm -rf "$WORK_DIR"
  else
    printf 'comeup simulator sync logs: %s\n' "$WORK_DIR"
  fi
}
trap cleanup EXIT

wait_for_socket() {
  local path="$1"
  for _ in {1..200}; do
    if [[ -S "$path" ]]; then
      return 0
    fi
    if [[ -n "$SERVER_PID" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
      printf 'comeup server exited early\n' >&2
      cat "$SERVER_LOG" >&2 || true
      return 1
    fi
    sleep 0.05
  done
  printf 'timed out waiting for socket %s\n' "$path" >&2
  cat "$SERVER_LOG" >&2 || true
  return 1
}

wait_for_tcp() {
  local port="$1"
  for _ in {1..200}; do
    if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
      return 0
    fi
    if [[ -n "$SERVER_PID" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
      printf 'comeup server exited early\n' >&2
      cat "$SERVER_LOG" >&2 || true
      return 1
    fi
    sleep 0.05
  done
  printf 'timed out waiting for tcp port %s\n' "$port" >&2
  cat "$SERVER_LOG" >&2 || true
  return 1
}

wait_for_log() {
  local path="$1"
  local needle="$2"
  for _ in {1..200}; do
    if grep -Fq "$needle" "$path" 2>/dev/null; then
      return 0
    fi
    if [[ -n "$CMX_PID" ]] && ! kill -0 "$CMX_PID" 2>/dev/null; then
      printf 'cmx exited while waiting for %s\n' "$needle" >&2
      cat "$path" >&2 || true
      return 1
    fi
    sleep 0.05
  done
  printf 'timed out waiting for %s in %s\n' "$needle" "$path" >&2
  cat "$path" >&2 || true
  return 1
}

cargo build -p comeup-daemon -p cmx

"$REPO_ROOT/scripts/ensure-ghosttykit.sh"

COMEUP_AUTH_TOKEN="$AUTH_TOKEN" \
"$ROOT/target/debug/comeup-harness-server" \
  --socket "$SOCKET" \
  --tcp "127.0.0.1:$PORT" \
  --shell /bin/cat \
  --cwd "$WORK_DIR" \
  >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

wait_for_socket "$SOCKET"
wait_for_tcp "$PORT"

COMEUP_AUTH_TOKEN="$AUTH_TOKEN" \
"$ROOT/target/debug/cmx-pty-recorder" \
  --socket "$SOCKET" \
  --cols 120 \
  --rows 40 \
  --send-after "$SIM_SENTINEL" "send $CMX_SENTINEL" \
  >"$CMX_LOG" 2>&1 &
CMX_PID=$!

wait_for_log "$CMX_LOG" "COMEUP_TUI_READY client=1 terminal=1 size=120x40"

WORKSPACE="$ROOT/simulator-harness/ComeupSimulatorHarness.xcworkspace"
SIMULATOR_ARGS=(
  --workspace-path "$WORKSPACE"
  --scheme ComeupSimulatorHarness
)
if [[ -n "$SIMULATOR_ID" ]]; then
  SIMULATOR_ARGS+=(--simulator-id "$SIMULATOR_ID")
else
  SIMULATOR_ARGS+=(--simulator-name "$SIMULATOR_NAME" --use-latest-os true)
fi

COMEUP_TEXT_PORT="$PORT" \
TEST_RUNNER_COMEUP_TEXT_PORT="$PORT" \
COMEUP_AUTH_TOKEN="$AUTH_TOKEN" \
TEST_RUNNER_COMEUP_AUTH_TOKEN="$AUTH_TOKEN" \
COMEUP_SEND_ON_CONNECT="$SIM_SENTINEL" \
TEST_RUNNER_COMEUP_SEND_ON_CONNECT="$SIM_SENTINEL" \
xcodebuildmcp simulator test \
  "${SIMULATOR_ARGS[@]}" \
  --derived-data-path "$DERIVED_DATA" \
  --prefer-xcodebuild true \
  --output text

wait_for_log "$CMX_LOG" "SIZE terminal=1 66x18"
wait_for_log "$CMX_LOG" "WORKSPACE id=2 title=Sim Build"
wait_for_log "$CMX_LOG" "SIZE terminal=2 66x18"
wait_for_log "$CMX_LOG" "$SIM_SENTINEL"
wait_for_log "$CMX_LOG" "$CMX_SENTINEL"

printf 'comeup simulator terminal sync passed\n'
