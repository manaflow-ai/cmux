#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_FILE="$(mktemp)"
trap 'rm -f "$OUTPUT_FILE"' EXIT

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

echo "PASS: output watchdog terminates fatal crash output before idle timeout"
