#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ci/virtual-display-lock.sh"
TMP_DIR="$(mktemp -d)"
LOCK_DIR="$TMP_DIR/cmux-test-virtual-display.lock"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

LOCK_ENV="$(
  RUNNER_TEMP="$TMP_DIR" \
  CMUX_VDISPLAY_LOCK_DIR="$LOCK_DIR" \
  CMUX_VDISPLAY_LOCK_TIMEOUT_SECONDS=2 \
  CMUX_VDISPLAY_LOCK_POLL_SECONDS=1 \
  "$SCRIPT" acquire
)"
eval "$LOCK_ENV"

if [ ! -d "$CMUX_VDISPLAY_LOCK_DIR" ] || [ ! -f "$CMUX_VDISPLAY_LOCK_DIR/token" ]; then
  echo "FAIL: acquire did not create tokenized lock" >&2
  exit 1
fi

if RUNNER_TEMP="$TMP_DIR" \
  CMUX_VDISPLAY_LOCK_DIR="$LOCK_DIR" \
  CMUX_VDISPLAY_LOCK_TIMEOUT_SECONDS=1 \
  CMUX_VDISPLAY_LOCK_POLL_SECONDS=1 \
  "$SCRIPT" acquire >/tmp/cmux-vdisplay-second-acquire.out 2>/tmp/cmux-vdisplay-second-acquire.err; then
  cat /tmp/cmux-vdisplay-second-acquire.out
  cat /tmp/cmux-vdisplay-second-acquire.err >&2
  echo "FAIL: second acquire succeeded while lock was held" >&2
  exit 1
fi

RUNNER_TEMP="$TMP_DIR" \
CMUX_VDISPLAY_LOCK_DIR="$CMUX_VDISPLAY_LOCK_DIR" \
CMUX_VDISPLAY_LOCK_TOKEN="$CMUX_VDISPLAY_LOCK_TOKEN" \
  "$SCRIPT" set-owner "$$"

if [ "$(cat "$CMUX_VDISPLAY_LOCK_DIR/owner_pid")" != "$$" ]; then
  echo "FAIL: set-owner did not record the helper PID" >&2
  exit 1
fi

RUNNER_TEMP="$TMP_DIR" \
CMUX_VDISPLAY_LOCK_DIR="$CMUX_VDISPLAY_LOCK_DIR" \
CMUX_VDISPLAY_LOCK_TOKEN="wrong-token" \
  "$SCRIPT" release

if [ ! -d "$CMUX_VDISPLAY_LOCK_DIR" ]; then
  echo "FAIL: release removed a lock with the wrong token" >&2
  exit 1
fi

RUNNER_TEMP="$TMP_DIR" \
CMUX_VDISPLAY_LOCK_DIR="$CMUX_VDISPLAY_LOCK_DIR" \
CMUX_VDISPLAY_LOCK_TOKEN="$CMUX_VDISPLAY_LOCK_TOKEN" \
  "$SCRIPT" release

if [ -d "$CMUX_VDISPLAY_LOCK_DIR" ]; then
  echo "FAIL: release did not remove the matching lock" >&2
  exit 1
fi

echo "PASS: virtual display lock serializes acquisition and releases only matching tokens"
