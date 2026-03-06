#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-typing-perf-surface-load}"
DURATION_SECONDS="${2:-20}"
TRACE_ROOT="/tmp/cmux-traces"
APP_BINARY="$HOME/Library/Developer/Xcode/DerivedData/cmux-${TAG}/Build/Products/Debug/cmux DEV ${TAG}.app/Contents/MacOS/cmux DEV"

PID="$(pgrep -nf "$APP_BINARY" || true)"

if [[ -z "${PID:-}" ]]; then
  echo "No running tagged build found for ${TAG}" >&2
  echo "Expected process path: ${APP_BINARY}" >&2
  exit 1
fi

mkdir -p "$TRACE_ROOT"
STAMP="$(date +%Y%m%d-%H%M%S)"
TRACE_PATH="${TRACE_ROOT}/${TAG}-${STAMP}.trace"

echo "Recording Time Profiler + Points of Interest for pid ${PID} (${DURATION_SECONDS}s)" >&2
echo "Output: ${TRACE_PATH}" >&2

xcrun xctrace record \
  --template 'Time Profiler' \
  --instrument 'Points of Interest' \
  --attach "$PID" \
  --output "$TRACE_PATH" \
  --time-limit "${DURATION_SECONDS}s" \
  --no-prompt

echo "$TRACE_PATH"
open "$TRACE_PATH"
