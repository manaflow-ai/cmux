#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
cleanup() {
  if [ -r "$TMP_DIR/child.pid" ]; then
    kill "$(cat "$TMP_DIR/child.pid")" 2>/dev/null || true
  fi
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

set +e
SECONDS=0
"$ROOT_DIR/scripts/ci/run-and-capture.sh" "$TMP_DIR/capture.log" \
  /bin/bash -c '
    echo "command-started"
    sleep 60 >>"$1" 2>&1 &
    echo $! >"$2"
    echo "detached-child=$!"
    exit 7
  ' _ "$TMP_DIR/capture.log" "$TMP_DIR/child.pid" \
  >"$TMP_DIR/streamed.log" 2>&1
status=$?
elapsed=$SECONDS
set -e

if [ "$status" -ne 7 ]; then
  cat "$TMP_DIR/streamed.log"
  echo "FAIL: capture wrapper changed command status to $status"
  exit 1
fi
if [ "$elapsed" -ge 5 ]; then
  cat "$TMP_DIR/streamed.log"
  echo "FAIL: detached child held the capture wrapper open for ${elapsed}s"
  exit 1
fi
if ! grep -Fq "command-started" "$TMP_DIR/capture.log" \
  || ! grep -Fq "detached-child=" "$TMP_DIR/capture.log"; then
  cat "$TMP_DIR/capture.log"
  echo "FAIL: capture file did not retain command output"
  exit 1
fi
if ! kill -0 "$(cat "$TMP_DIR/child.pid")" 2>/dev/null; then
  echo "FAIL: detached child did not survive long enough to prove pipe independence"
  exit 1
fi

echo "PASS: file-backed capture returns when the command exits even with a detached writer"
