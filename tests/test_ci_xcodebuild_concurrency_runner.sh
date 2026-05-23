#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT_DIR/scripts/xcodebuild-concurrency-runner.py"
TMP_DIR="$(mktemp -d)"
declare -a CHILD_PIDS=()

cleanup() {
  for pid in "${CHILD_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

wait_for_file() {
  local path="$1"
  local attempts="${2:-100}"
  for ((i = 0; i < attempts; i++)); do
    if [[ -f "$path" ]]; then
      return 0
    fi
    sleep 0.05
  done
  echo "timed out waiting for $path" >&2
  return 1
}

assert_file_absent_for() {
  local path="$1"
  local attempts="${2:-12}"
  for ((i = 0; i < attempts; i++)); do
    if [[ -f "$path" ]]; then
      echo "expected $path to remain absent" >&2
      return 1
    fi
    sleep 0.05
  done
}

wait_for_pattern() {
  local path="$1"
  local pattern="$2"
  local attempts="${3:-100}"
  for ((i = 0; i < attempts; i++)); do
    if [[ -f "$path" ]] && grep -Fq "$pattern" "$path"; then
      return 0
    fi
    sleep 0.05
  done
  echo "timed out waiting for $pattern in $path" >&2
  [[ -f "$path" ]] && cat "$path" >&2
  return 1
}

cat > "$TMP_DIR/hold.py" <<'PY'
import pathlib
import sys
import time

ready = pathlib.Path(sys.argv[1])
release = pathlib.Path(sys.argv[2])
ready.write_text("ready\n", encoding="utf-8")

deadline = time.time() + 20
while not release.exists():
    if time.time() > deadline:
        raise SystemExit(f"timed out waiting for {release}")
    time.sleep(0.05)
PY

cat > "$TMP_DIR/touch.py" <<'PY'
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text("done\n", encoding="utf-8")
PY

cat > "$TMP_DIR/require_slot_env.py" <<'PY'
import os
import pathlib
import sys

if os.environ.get("CMUX_XCODEBUILD_SLOT_HELD") != "1":
    raise SystemExit("missing CMUX_XCODEBUILD_SLOT_HELD")
pathlib.Path(sys.argv[1]).write_text("slot env set\n", encoding="utf-8")
PY

CMUX_XCODEBUILD_CONCURRENCY=1 \
  "$RUNNER" --lock-root "$TMP_DIR/slots-env" -- \
  python3 "$TMP_DIR/require_slot_env.py" "$TMP_DIR/slot-env.done" \
  >"$TMP_DIR/slot-env.out" 2>&1
wait_for_file "$TMP_DIR/slot-env.done"

CMUX_XCODEBUILD_CONCURRENCY=1 \
  "$RUNNER" --lock-root "$TMP_DIR/slots-one" -- \
  python3 "$TMP_DIR/hold.py" "$TMP_DIR/one.ready" "$TMP_DIR/one.release" \
  >"$TMP_DIR/one-holder.out" 2>&1 &
one_holder_pid="$!"
CHILD_PIDS+=("$one_holder_pid")
wait_for_file "$TMP_DIR/one.ready"

CMUX_XCODEBUILD_CONCURRENCY=1 \
  "$RUNNER" --lock-root "$TMP_DIR/slots-one" -- \
  python3 "$TMP_DIR/touch.py" "$TMP_DIR/one-queued.done" \
  >"$TMP_DIR/one-queued.out" 2>&1 &
one_queued_pid="$!"
CHILD_PIDS+=("$one_queued_pid")

wait_for_pattern "$TMP_DIR/one-queued.out" "All 1 local xcodebuild slots are busy"
assert_file_absent_for "$TMP_DIR/one-queued.done"
touch "$TMP_DIR/one.release"
wait "$one_holder_pid"
wait "$one_queued_pid"
CHILD_PIDS=()
wait_for_file "$TMP_DIR/one-queued.done"

CMUX_XCODEBUILD_CONCURRENCY=1 \
  "$RUNNER" --lock-root "$TMP_DIR/slots-term" -- \
  python3 "$TMP_DIR/hold.py" "$TMP_DIR/term.ready" "$TMP_DIR/term.release" \
  >"$TMP_DIR/term-holder.out" 2>&1 &
term_holder_pid="$!"
CHILD_PIDS+=("$term_holder_pid")
wait_for_file "$TMP_DIR/term.ready"

CMUX_XCODEBUILD_CONCURRENCY=1 \
  "$RUNNER" --lock-root "$TMP_DIR/slots-term" -- \
  python3 "$TMP_DIR/touch.py" "$TMP_DIR/term-queued.done" \
  >"$TMP_DIR/term-queued.out" 2>&1 &
term_queued_pid="$!"
CHILD_PIDS+=("$term_queued_pid")

wait_for_pattern "$TMP_DIR/term-queued.out" "All 1 local xcodebuild slots are busy"
assert_file_absent_for "$TMP_DIR/term-queued.done"
kill -TERM "$term_holder_pid"
term_status=0
wait "$term_holder_pid" 2>/dev/null || term_status="$?"
if [[ "$term_status" -ne 143 ]]; then
  echo "expected SIGTERM holder status 143, got $term_status" >&2
  exit 1
fi
wait "$term_queued_pid"
CHILD_PIDS=()
wait_for_file "$TMP_DIR/term-queued.done"

CMUX_XCODEBUILD_CONCURRENCY=1 \
  "$RUNNER" --lock-root "$TMP_DIR/slots-kill" -- \
  python3 "$TMP_DIR/hold.py" "$TMP_DIR/kill.ready" "$TMP_DIR/kill.release" \
  >"$TMP_DIR/kill-holder.out" 2>&1 &
kill_holder_pid="$!"
CHILD_PIDS+=("$kill_holder_pid")
wait_for_file "$TMP_DIR/kill.ready"

CMUX_XCODEBUILD_CONCURRENCY=1 \
  "$RUNNER" --lock-root "$TMP_DIR/slots-kill" -- \
  python3 "$TMP_DIR/touch.py" "$TMP_DIR/kill-queued.done" \
  >"$TMP_DIR/kill-queued.out" 2>&1 &
kill_queued_pid="$!"
CHILD_PIDS+=("$kill_queued_pid")

wait_for_pattern "$TMP_DIR/kill-queued.out" "All 1 local xcodebuild slots are busy"
assert_file_absent_for "$TMP_DIR/kill-queued.done"
kill -KILL "$kill_holder_pid"
kill_status=0
wait "$kill_holder_pid" 2>/dev/null || kill_status="$?"
if [[ "$kill_status" -ne 137 ]]; then
  echo "expected SIGKILL holder status 137, got $kill_status" >&2
  exit 1
fi
wait "$kill_queued_pid"
CHILD_PIDS=()
wait_for_file "$TMP_DIR/kill-queued.done"

printf '2\n' > "$TMP_DIR/concurrency"
CMUX_XCODEBUILD_CONCURRENCY_FILE="$TMP_DIR/concurrency" \
  "$RUNNER" --lock-root "$TMP_DIR/slots-two" -- \
  python3 "$TMP_DIR/hold.py" "$TMP_DIR/two.ready" "$TMP_DIR/two.release" \
  >"$TMP_DIR/two-holder.out" 2>&1 &
two_holder_pid="$!"
CHILD_PIDS+=("$two_holder_pid")
wait_for_file "$TMP_DIR/two.ready"

CMUX_XCODEBUILD_CONCURRENCY_FILE="$TMP_DIR/concurrency" \
  "$RUNNER" --lock-root "$TMP_DIR/slots-two" -- \
  python3 "$TMP_DIR/touch.py" "$TMP_DIR/two-parallel.done" \
  >"$TMP_DIR/two-parallel.out" 2>&1
wait_for_file "$TMP_DIR/two-parallel.done"
touch "$TMP_DIR/two.release"
wait "$two_holder_pid"
CHILD_PIDS=()

if "$RUNNER" --lock-root "$TMP_DIR/invalid" --concurrency 0 -- true \
  >"$TMP_DIR/invalid.out" 2>&1; then
  echo "expected invalid concurrency to fail" >&2
  exit 1
fi

if ! grep -Fq "positive integer" "$TMP_DIR/invalid.out"; then
  echo "expected invalid concurrency error" >&2
  cat "$TMP_DIR/invalid.out" >&2
  exit 1
fi

echo "PASS: xcodebuild concurrency runner gates commands by configurable slots"
