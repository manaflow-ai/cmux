#!/usr/bin/env bash
# Runs `swift test` with the given arguments. If it is still running after
# CMUX_NEXT_TEST_HANG_SECONDS (default 1200), samples the test processes so the
# log shows where they are stuck, kills them, and fails. Run from
# Packages/macOS/CmuxNext.
set -uo pipefail
limit="${CMUX_NEXT_TEST_HANG_SECONDS:-1200}"
swift test "$@" &
test_pid=$!
(
  sleep "$limit"
  echo "::error title=cmux-next swift test hang::swift test still running after ${limit}s; sampling the test processes"
  for p in $(pgrep -x xctest) $(pgrep -f swiftpm-testing-helper); do
    echo "=== sample $p"
    sample "$p" 5 -mayDie 2>&1 | head -n 800
  done
  pkill -x xctest
  pkill -f swiftpm-testing-helper
  kill "$test_pid"
) &
watcher=$!
wait "$test_pid"
status=$?
if kill -0 "$watcher" 2>/dev/null; then
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  exit "$status"
fi
# The watcher fired: always fail, whatever status the killed run reported.
exit $(( status == 0 ? 1 : status ))
