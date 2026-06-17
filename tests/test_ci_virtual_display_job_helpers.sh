#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/clang" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
if [ -z "$output" ]; then
  echo "mock clang requires -o" >&2
  exit 1
fi
cat > "$output" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
ready_path=""
display_id_path=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ready-path)
      ready_path="$2"
      shift 2
      ;;
    --display-id-path)
      display_id_path="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
printf 'ready\n' > "$ready_path"
printf '123456\n' > "$display_id_path"
trap 'exit 0' TERM
while :; do
  sleep 1
done
HELPER
chmod +x "$output"
SH
chmod +x "$TMP_DIR/clang"

ENV_FILE="$TMP_DIR/github-env"
OUTPUT_LOG="$TMP_DIR/output.log"
LOCK_DIR="$TMP_DIR/cmux-ci-virtual-display.lock"

PATH="$TMP_DIR:$PATH" \
RUNNER_TEMP="$TMP_DIR" \
GITHUB_ENV="$ENV_FILE" \
CMUX_VDISPLAY_LOCK_DIR="$LOCK_DIR" \
CMUX_VDISPLAY_START_ATTEMPTS=1 \
  "$ROOT_DIR/scripts/ci/start-virtual-display.sh" xctest >"$OUTPUT_LOG" 2>&1

if ! grep -Fq "Virtual display ready: 123456" "$OUTPUT_LOG"; then
  cat "$OUTPUT_LOG"
  echo "FAIL: start helper did not report virtual display readiness"
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

if [ -z "${VDISPLAY_PID:-}" ] || ! kill -0 "$VDISPLAY_PID" 2>/dev/null; then
  cat "$OUTPUT_LOG"
  echo "FAIL: start helper did not leave a live display helper for the job"
  exit 1
fi

if [ ! -d "$LOCK_DIR" ]; then
  cat "$OUTPUT_LOG"
  echo "FAIL: start helper did not hold the virtual display lock"
  exit 1
fi

CMUX_VDISPLAY_LOCK_DIR="$CMUX_VDISPLAY_LOCK_DIR" \
CMUX_VDISPLAY_LOCK_TOKEN="$CMUX_VDISPLAY_LOCK_TOKEN" \
RUNNER_TEMP="$TMP_DIR" \
VDISPLAY_PID="$VDISPLAY_PID" \
VDISPLAY_HELPER_PATH="$VDISPLAY_HELPER_PATH" \
VDISPLAY_READY="$VDISPLAY_READY" \
VDISPLAY_ID_PATH="$VDISPLAY_ID_PATH" \
VDISPLAY_LOG="$VDISPLAY_LOG" \
  "$ROOT_DIR/scripts/ci/cleanup-virtual-display.sh"

if kill -0 "$VDISPLAY_PID" 2>/dev/null; then
  echo "FAIL: cleanup helper did not stop the display helper"
  exit 1
fi

if [ -e "$LOCK_DIR" ]; then
  echo "FAIL: cleanup helper did not release the virtual display lock"
  exit 1
fi

if [ -e "$VDISPLAY_HELPER_PATH" ] || [ -e "$VDISPLAY_READY" ] || [ -e "$VDISPLAY_ID_PATH" ] || [ -e "$VDISPLAY_LOG" ]; then
  echo "FAIL: cleanup helper left virtual display files behind"
  exit 1
fi

echo "PASS: virtual display job helpers start, export cleanup state, and release cleanly"
