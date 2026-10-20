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

RUNNER_TEMP="$TMP_DIR" \
CMUX_VDISPLAY_LOCK_DIR="$CMUX_VDISPLAY_LOCK_DIR" \
CMUX_VDISPLAY_LOCK_TOKEN="$CMUX_VDISPLAY_LOCK_TOKEN" \
  "$SCRIPT" set-owner "$$"

if [ "$(cat "$CMUX_VDISPLAY_LOCK_DIR/owner_pid")" != "$$" ]; then
  echo "FAIL: set-owner did not record the helper PID" >&2
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

{
  printf 'created_at=1\n'
  printf 'token=%s\n' "$CMUX_VDISPLAY_LOCK_TOKEN"
} > "$CMUX_VDISPLAY_LOCK_DIR/metadata"

if RUNNER_TEMP="$TMP_DIR" \
  CMUX_VDISPLAY_LOCK_DIR="$LOCK_DIR" \
  CMUX_VDISPLAY_LOCK_TIMEOUT_SECONDS=1 \
  CMUX_VDISPLAY_LOCK_STALE_SECONDS=1 \
  CMUX_VDISPLAY_LOCK_POLL_SECONDS=1 \
  "$SCRIPT" acquire >/tmp/cmux-vdisplay-live-owner-acquire.out 2>/tmp/cmux-vdisplay-live-owner-acquire.err; then
  cat /tmp/cmux-vdisplay-live-owner-acquire.out
  cat /tmp/cmux-vdisplay-live-owner-acquire.err >&2
  echo "FAIL: stale cleanup removed a lock whose owner PID was alive" >&2
  exit 1
fi

if ps -p 1 >/dev/null 2>&1; then
  printf '1\n' > "$CMUX_VDISPLAY_LOCK_DIR/owner_pid"
  {
    printf 'created_at=1\n'
    printf 'token=%s\n' "$CMUX_VDISPLAY_LOCK_TOKEN"
  } > "$CMUX_VDISPLAY_LOCK_DIR/metadata"

  if RUNNER_TEMP="$TMP_DIR" \
    CMUX_VDISPLAY_LOCK_DIR="$LOCK_DIR" \
    CMUX_VDISPLAY_LOCK_TIMEOUT_SECONDS=1 \
    CMUX_VDISPLAY_LOCK_STALE_SECONDS=1 \
    CMUX_VDISPLAY_LOCK_POLL_SECONDS=1 \
    "$SCRIPT" acquire >/tmp/cmux-vdisplay-foreign-owner-acquire.out 2>/tmp/cmux-vdisplay-foreign-owner-acquire.err; then
    cat /tmp/cmux-vdisplay-foreign-owner-acquire.out
    cat /tmp/cmux-vdisplay-foreign-owner-acquire.err >&2
    echo "FAIL: stale cleanup removed a lock whose owner PID exists but may reject kill -0" >&2
    exit 1
  fi
fi

RUNNER_TEMP="$TMP_DIR" \
CMUX_VDISPLAY_LOCK_DIR="$CMUX_VDISPLAY_LOCK_DIR" \
CMUX_VDISPLAY_LOCK_TOKEN="wrong-token" \
  "$SCRIPT" release 2>/tmp/cmux-vdisplay-wrong-token-release.err

if [ ! -d "$CMUX_VDISPLAY_LOCK_DIR" ]; then
  echo "FAIL: release removed a lock with the wrong token" >&2
  exit 1
fi

rm -f "$CMUX_VDISPLAY_LOCK_DIR/owner_pid"
{
  printf 'created_at=1\n'
  printf 'token=%s\n' "$CMUX_VDISPLAY_LOCK_TOKEN"
} > "$CMUX_VDISPLAY_LOCK_DIR/metadata"

OWNERLESS_LOCK_ENV="$(
  RUNNER_TEMP="$TMP_DIR" \
  CMUX_VDISPLAY_LOCK_DIR="$LOCK_DIR" \
  CMUX_VDISPLAY_LOCK_TIMEOUT_SECONDS=2 \
  CMUX_VDISPLAY_LOCK_STALE_SECONDS=1800 \
  CMUX_VDISPLAY_LOCK_POLL_SECONDS=1 \
  "$SCRIPT" acquire 2>/tmp/cmux-vdisplay-ownerless-acquire.err
)"
eval "$OWNERLESS_LOCK_ENV"

printf '999999999\n' > "$CMUX_VDISPLAY_LOCK_DIR/owner_pid"
DEAD_OWNER_LOCK_ENV="$(
  RUNNER_TEMP="$TMP_DIR" \
  CMUX_VDISPLAY_LOCK_DIR="$LOCK_DIR" \
  CMUX_VDISPLAY_LOCK_TIMEOUT_SECONDS=2 \
  CMUX_VDISPLAY_LOCK_STALE_SECONDS=1800 \
  CMUX_VDISPLAY_LOCK_POLL_SECONDS=1 \
  "$SCRIPT" acquire 2>/tmp/cmux-vdisplay-dead-owner-acquire.err
)"
eval "$DEAD_OWNER_LOCK_ENV"

RUNNER_TEMP="$TMP_DIR" \
CMUX_VDISPLAY_LOCK_DIR="$CMUX_VDISPLAY_LOCK_DIR" \
CMUX_VDISPLAY_LOCK_TOKEN="$CMUX_VDISPLAY_LOCK_TOKEN" \
  "$SCRIPT" release

if [ -d "$CMUX_VDISPLAY_LOCK_DIR" ]; then
  echo "FAIL: release did not remove the matching lock" >&2
  exit 1
fi

# reap-strays kills leaked display helpers while the lock is held, leaves the
# clang compile of the source alone, and refuses to act without the lock token.
REAP_LOCK_DIR="$TMP_DIR/cmux-test-reap.lock"
REAP_ENV="$(
  RUNNER_TEMP="$TMP_DIR" \
  CMUX_VDISPLAY_LOCK_DIR="$REAP_LOCK_DIR" \
  "$SCRIPT" acquire
)"
eval "$REAP_ENV"

( exec -a "$TMP_DIR/create-virtual-display --ready-path /tmp/x" sleep 30 ) &
STRAY_PID=$!
( exec -a "clang -framework CoreGraphics -o $TMP_DIR/create-virtual-display scripts/create-virtual-display.m" sleep 30 ) &
COMPILE_PID=$!
sleep 0.3

# Without the token, reap-strays must refuse (non-zero) and kill nothing.
if RUNNER_TEMP="$TMP_DIR" CMUX_VDISPLAY_LOCK_DIR="$CMUX_VDISPLAY_LOCK_DIR" \
  "$SCRIPT" reap-strays >/dev/null 2>&1; then
  echo "FAIL: reap-strays succeeded without the lock token" >&2
  exit 1
fi
if ! kill -0 "$STRAY_PID" 2>/dev/null; then
  echo "FAIL: reap-strays killed a helper without the lock token" >&2
  exit 1
fi

RUNNER_TEMP="$TMP_DIR" \
CMUX_VDISPLAY_LOCK_DIR="$CMUX_VDISPLAY_LOCK_DIR" \
CMUX_VDISPLAY_LOCK_TOKEN="$CMUX_VDISPLAY_LOCK_TOKEN" \
  "$SCRIPT" reap-strays >/dev/null 2>&1
sleep 0.3
if kill -0 "$STRAY_PID" 2>/dev/null; then
  echo "FAIL: reap-strays did not kill the leaked display helper" >&2
  kill "$STRAY_PID" "$COMPILE_PID" 2>/dev/null || true
  exit 1
fi
if ! kill -0 "$COMPILE_PID" 2>/dev/null; then
  echo "FAIL: reap-strays killed the clang compile of the helper source" >&2
  kill "$COMPILE_PID" 2>/dev/null || true
  exit 1
fi
kill "$COMPILE_PID" 2>/dev/null || true
RUNNER_TEMP="$TMP_DIR" \
CMUX_VDISPLAY_LOCK_DIR="$CMUX_VDISPLAY_LOCK_DIR" \
CMUX_VDISPLAY_LOCK_TOKEN="$CMUX_VDISPLAY_LOCK_TOKEN" \
  "$SCRIPT" release

echo "PASS: virtual display lock serializes acquisition, preserves live-owner locks, reclaims ownerless and dead-owner locks, releases only matching tokens, and reap-strays kills leaked helpers (token-gated, compile-safe)"
