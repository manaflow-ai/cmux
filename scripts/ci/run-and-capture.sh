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
# lifetime of the step. A separate tail process provides live CI output and is
# owned explicitly by this wrapper.
tail -n +1 -f "$output_path" &
stream_pid=$!

stop_stream() {
  kill "$stream_pid" 2>/dev/null || true
  wait "$stream_pid" 2>/dev/null || true
}
trap stop_stream EXIT HUP INT TERM

set +e
"$@" >>"$output_path" 2>&1
status=$?
set -e

# Give tail one polling interval to drain the command's final writes. The file
# remains the authoritative complete artifact even if a detached child writes
# after the command itself exits.
sleep 0.2
stop_stream
trap - EXIT HUP INT TERM
exit "$status"
