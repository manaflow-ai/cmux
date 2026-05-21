#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_FILE="$(mktemp)"
LEAK_PID_FILE="$(mktemp)"
trap 'rm -f "$OUTPUT_FILE" "$LEAK_PID_FILE"' EXIT

START_SECONDS="$(date +%s)"
set +e
python3 "$ROOT_DIR/.github/scripts/run-with-output-watchdog.py" \
  --idle-timeout-seconds 30 \
  --termination-grace-seconds 1 \
  --output "$OUTPUT_FILE" \
  -- \
  bash -c 'printf "Program crashed: Signal 11\n"; sleep 30'
STATUS=$?
set -e
ELAPSED_SECONDS="$(($(date +%s) - START_SECONDS))"

if [ "$STATUS" -ne 124 ]; then
  echo "FAIL: watchdog should return 124 after fatal crash output, got $STATUS" >&2
  exit 1
fi

if [ "$ELAPSED_SECONDS" -gt 10 ]; then
  echo "FAIL: watchdog took ${ELAPSED_SECONDS}s to terminate fatal crash output" >&2
  exit 1
fi

if ! grep -Fq "Fatal output detected" "$OUTPUT_FILE"; then
  echo "FAIL: watchdog output did not explain fatal crash termination" >&2
  exit 1
fi

: > "$OUTPUT_FILE"
START_SECONDS="$(date +%s)"
set +e
python3 "$ROOT_DIR/.github/scripts/run-with-output-watchdog.py" \
  --idle-timeout-seconds 2 \
  --termination-grace-seconds 1 \
  --output "$OUTPUT_FILE" \
  -- \
  bash -c 'sleep 30 & echo "$!" > "$1"; printf "direct child exited\n"; exit 0' bash "$LEAK_PID_FILE"
STATUS=$?
set -e
ELAPSED_SECONDS="$(($(date +%s) - START_SECONDS))"

if [ "$STATUS" -ne 124 ]; then
  echo "FAIL: watchdog should return 124 when a grandchild holds stdout open, got $STATUS" >&2
  exit 1
fi

if [ "$ELAPSED_SECONDS" -gt 10 ]; then
  echo "FAIL: watchdog took ${ELAPSED_SECONDS}s to terminate stdout-holding grandchild" >&2
  exit 1
fi

if ! grep -Fq "No output for" "$OUTPUT_FILE"; then
  echo "FAIL: watchdog output did not explain idle termination" >&2
  exit 1
fi

if [ ! -s "$LEAK_PID_FILE" ]; then
  echo "FAIL: stdout-holding grandchild did not write its pid" >&2
  exit 1
fi

LEAK_PID="$(cat "$LEAK_PID_FILE")"
sleep 0.2
if kill -0 "$LEAK_PID" 2>/dev/null; then
  kill "$LEAK_PID" 2>/dev/null || true
  echo "FAIL: watchdog left stdout-holding grandchild process $LEAK_PID running" >&2
  exit 1
fi

: > "$OUTPUT_FILE"
START_SECONDS="$(date +%s)"
set +e
python3 "$ROOT_DIR/.github/scripts/run-with-output-watchdog.py" \
  --idle-timeout-seconds 2 \
  --termination-grace-seconds 1 \
  --output "$OUTPUT_FILE" \
  -- \
  bash -c 'exec 1>&-; sleep 30'
STATUS=$?
set -e
ELAPSED_SECONDS="$(($(date +%s) - START_SECONDS))"

if [ "$STATUS" -ne 124 ]; then
  echo "FAIL: watchdog should return 124 when stdout closes before process exit, got $STATUS" >&2
  exit 1
fi

if [ "$ELAPSED_SECONDS" -gt 10 ]; then
  echo "FAIL: watchdog took ${ELAPSED_SECONDS}s after child stdout closed" >&2
  exit 1
fi

if ! grep -Fq "No output for" "$OUTPUT_FILE"; then
  echo "FAIL: watchdog output did not explain closed-stdout idle termination" >&2
  exit 1
fi

echo "PASS: output watchdog terminates fatal and silent stalled commands"
