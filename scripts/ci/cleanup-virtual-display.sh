#!/usr/bin/env bash
set -euo pipefail

if [ -n "${VDISPLAY_PID:-}" ]; then
  kill "$VDISPLAY_PID" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    kill -0 "$VDISPLAY_PID" >/dev/null 2>&1 || break
    sleep 0.1
  done
fi

scripts/ci/virtual-display-lock.sh release || true
rm -f \
  "${VDISPLAY_HELPER_PATH:-}" \
  "${VDISPLAY_READY:-}" \
  "${VDISPLAY_ID_PATH:-}" \
  "${VDISPLAY_LOG:-}"
