#!/usr/bin/env bash
# Give a macOS CI job a display for the rest of its steps.
#
#   virtual-display.sh start <name>   create a CGVirtualDisplay, export its state
#   virtual-display.sh stop           tear it down (safe to call when start failed)
#
# Headless runners have no display, so AppKit never gives a window a display
# link, windows never go key, and terminal surfaces never get real bounds.
# `start` exports VDISPLAY_* and CMUX_VDISPLAY_LOCK_* through GITHUB_ENV so a
# later `stop` step (if: always()) can find the helper.
set -euo pipefail

COMMAND="${1:-}"
NAME="${2:-cmux}"

stop_display() {
  if [ -n "${VDISPLAY_PID:-}" ]; then
    kill "$VDISPLAY_PID" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do
      kill -0 "$VDISPLAY_PID" >/dev/null 2>&1 || break
      sleep 0.1
    done
    if kill -0 "$VDISPLAY_PID" >/dev/null 2>&1; then
      kill -9 "$VDISPLAY_PID" >/dev/null 2>&1 || true
      wait "$VDISPLAY_PID" >/dev/null 2>&1 || true
    fi
    VDISPLAY_PID=""
  fi
  scripts/ci/virtual-display-lock.sh reap-strays || true
  scripts/ci/virtual-display-lock.sh release || true
}

start_display() {
  : "${RUNNER_TEMP:?RUNNER_TEMP is required}"
  : "${GITHUB_ENV:?GITHUB_ENV is required}"
  HELPER_PATH="$RUNNER_TEMP/create-virtual-display"
  VDISPLAY_READY="$RUNNER_TEMP/$NAME-vdisplay.ready"
  VDISPLAY_ID_PATH="$RUNNER_TEMP/$NAME-vdisplay.id"
  VDISPLAY_LOG="$RUNNER_TEMP/$NAME-vdisplay.log"
  VDISPLAY_PID=""

  clang -framework Foundation -framework CoreGraphics \
    -o "$HELPER_PATH" scripts/create-virtual-display.m

  for attempt in 1 2 3; do
    rm -f "$VDISPLAY_READY" "$VDISPLAY_ID_PATH" "$VDISPLAY_LOG"
    LOCK_ENV="$(scripts/ci/virtual-display-lock.sh acquire)"
    eval "$LOCK_ENV"
    export CMUX_VDISPLAY_LOCK_DIR CMUX_VDISPLAY_LOCK_TOKEN
    {
      echo "CMUX_VDISPLAY_LOCK_DIR=$CMUX_VDISPLAY_LOCK_DIR"
      echo "CMUX_VDISPLAY_LOCK_TOKEN=$CMUX_VDISPLAY_LOCK_TOKEN"
    } >> "$GITHUB_ENV"

    # Now that we hold the lock, reap any leaked display helper so a
    # CGVirtualDisplay orphaned by a crashed/cancelled job cannot block
    # this create on persistent self-hosted runners.
    scripts/ci/virtual-display-lock.sh reap-strays || true

    "$HELPER_PATH" \
      --ready-path "$VDISPLAY_READY" \
      --display-id-path "$VDISPLAY_ID_PATH" \
      >"$VDISPLAY_LOG" 2>&1 &
    VDISPLAY_PID=$!
    scripts/ci/virtual-display-lock.sh set-owner "$VDISPLAY_PID"

    {
      echo "VDISPLAY_PID=$VDISPLAY_PID"
      echo "VDISPLAY_HELPER_PATH=$HELPER_PATH"
      echo "VDISPLAY_READY=$VDISPLAY_READY"
      echo "VDISPLAY_ID_PATH=$VDISPLAY_ID_PATH"
      echo "VDISPLAY_LOG=$VDISPLAY_LOG"
    } >> "$GITHUB_ENV"

    for _ in $(seq 1 100); do
      if [ -s "$VDISPLAY_READY" ] && [ -s "$VDISPLAY_ID_PATH" ]; then
        break
      fi
      if ! kill -0 "$VDISPLAY_PID" 2>/dev/null; then
        echo "Virtual display helper exited before readiness on attempt $attempt" >&2
        cat "$VDISPLAY_LOG" >&2 || true
        break
      fi
      sleep 0.1
    done

    if [ -s "$VDISPLAY_READY" ] && [ -s "$VDISPLAY_ID_PATH" ]; then
      echo "Virtual display ready: $(tr -d '\n' < "$VDISPLAY_ID_PATH")"
      cat "$VDISPLAY_LOG"
      return 0
    fi

    echo "Virtual display not ready on attempt $attempt" >&2
    cat "$VDISPLAY_LOG" >&2 || true
    stop_display
    if [ "$attempt" -eq 3 ]; then
      echo "Failed to create virtual display after 3 attempts" >&2
      return 1
    fi
    sleep 5
  done
}

case "$COMMAND" in
  start)
    start_display
    ;;
  stop)
    stop_display
    rm -f "${VDISPLAY_HELPER_PATH:-}" "${VDISPLAY_READY:-}" "${VDISPLAY_ID_PATH:-}" "${VDISPLAY_LOG:-}"
    ;;
  *)
    echo "usage: virtual-display.sh start <name> | stop" >&2
    exit 2
    ;;
esac
