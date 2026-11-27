#!/usr/bin/env bash
# The perf cron's chat-open harness against chat-open-ab.sh's, on one runner: bench/chat-open.bench.ts as the cron's
# web-ui-god part runs it (FIXTURE=god PAIRED=1, 7 rounds, small chat + god chat + calibration page in one browser)
# and as chat-open-ab.sh runs it (one fixture per process), interleaved ROUNDS times. It prints each run's
# attach_to_latest and DOMContentLoaded rows (the median of its rounds) and the calibration page's median.
#   bench/chat-open-harness-ab.sh [rounds=3] [per=7]
#   cmux-ci test --setup playwright --not-tests -- bash webviews/bench/chat-open-harness-ab.sh 3 7
set -uo pipefail
rounds="${1:-3}"
per="${2:-7}"
cd "$(dirname "$0")/.."
PANE_OUT="$(mktemp -d)"
export PANE_OUT
trap 'rm -rf "$PANE_OUT"' EXIT
pick='calibration page|^chat-open \[rail|^paired (small|god):|^per round (attach_to_latest|dom_content_loaded)|"name":"chat_open(_paired)?\.(god\.)?compact\.(attach_to_latest|dom_content_loaded)"'
run() {
  local label="$1"
  shift
  echo "=== $label"
  env "$@" timeout 600 bun bench/chat-open.bench.ts "$per" 300 2>&1 | grep -E "$pick" || echo "=== $label FAILED"
}
for round in $(seq 1 "$rounds"); do
  run "paired round $round" FIXTURE=god PAIRED=1
  run "god alone round $round" FIXTURE=god
  run "small alone round $round" FIXTURE=small
done
echo "=== runner: $(nproc) cpus, $(lscpu | sed -n 's/^Model name: *//p')"
