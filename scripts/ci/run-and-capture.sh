#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <output-path> <command> [args...]" >&2
  exit 2
fi

output_path="$1"
shift
mkdir -p "$(dirname "$output_path")"
: >"$output_path"

# The tested command writes to a regular file, never to the CI capture pipe.
# A detached descendant may inherit this file descriptor without extending the
# lifetime of the step. A separately-owned tail process provides live CI output.
stream_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-run-capture.XXXXXX")"
stream_fifo="$stream_dir/stream"
stream_copy="$stream_dir/streamed"
mkfifo "$stream_fifo"
: >"$stream_copy"

tee "$stream_copy" <"$stream_fifo" &
reader_pid=$!
tail -n +1 -f "$output_path" >"$stream_fifo" &
stream_pid=$!

stop_stream() {
  kill "$stream_pid" 2>/dev/null || true
  wait "$stream_pid" 2>/dev/null || true
  wait "$reader_pid" 2>/dev/null || true
}
cleanup() {
  stop_stream
  rm -rf "$stream_dir"
}

command_pid=""
forward_signal() {
  local signal_name="$1"
  local exit_status="$2"
  trap - HUP INT TERM
  if [ -n "$command_pid" ] && kill -0 "$command_pid" 2>/dev/null; then
    # The command runs as a new session/process-group leader. Forward
    # cancellation to the whole owned group so xcodebuild/test descendants do
    # not keep running after the capture wrapper is cancelled.
    kill -s "$signal_name" -- "-$command_pid" 2>/dev/null \\n      || kill -s "$signal_name" "$command_pid" 2>/dev/null \\n      || true
    for _ in 1 2 3 4 5; do
      kill -0 "$command_pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$command_pid" 2>/dev/null; then
      kill -KILL -- "-$command_pid" 2>/dev/null \\n        || kill -KILL "$command_pid" 2>/dev/null \\n        || true
    fi
    wait "$command_pid" 2>/dev/null || true
  fi
  command_pid=""
  cleanup
  trap - EXIT
  exit "$exit_status"
}
trap cleanup EXIT
trap 'forward_signal HUP 129' HUP
trap 'forward_signal INT 130' INT
trap 'forward_signal TERM 143' TERM

set +e
CMUX_CI_FILE_CAPTURE_ACTIVE=1 python3 -c '
import os
import sys
os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])
' "$@" >>"$output_path" 2>&1 &
command_pid=$!
wait "$command_pid"
status=$?
command_pid=""
set -e

# Stop the live follower, then wait for the pipe reader to observe EOF. Reconcile
# against the authoritative file by byte count so writes that landed before the
# command exited but had not yet crossed tail's pipe are emitted exactly once.
stop_stream
streamed_bytes="$(wc -c <"$stream_copy" | tr -d ' ')"
captured_bytes="$(wc -c <"$output_path" | tr -d ' ')"
if [ "$streamed_bytes" -lt "$captured_bytes" ]; then
  dd if="$output_path" bs=1 skip="$streamed_bytes" 2>/dev/null
elif [ "$streamed_bytes" -gt "$captured_bytes" ]; then
  echo "FAIL: live capture exceeded authoritative output size" >&2
  exit 1
fi

trap - EXIT HUP INT TERM
rm -rf "$stream_dir"
exit "$status"
