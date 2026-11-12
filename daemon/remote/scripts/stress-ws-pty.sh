#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

duration="${CMUX_PTY_STRESS_DURATION:-12h}"
fuzztime="${CMUX_PTY_FUZZTIME:-5m}"
log_every="${CMUX_PTY_STRESS_LOG_EVERY:-60}"
test_timeout="${CMUX_PTY_TEST_TIMEOUT:-2m}"
package="./cmd/cmuxd-remote"
stress_filter='TestWebSocketPTY(StressSessionCleanupAndBoundedScrollback|ReconnectKeepsSessionProcess|MultiAttachUsesSmallestResize|RunsShellOverBinaryFrames)'
stress_tmp="$(mktemp -d)"
trap 'rm -rf "$stress_tmp"' EXIT
stress_bin="$stress_tmp/cmuxd-remote.test"

cd "$REMOTE_DIR"
export GOTOOLCHAIN="${GOTOOLCHAIN:-go1.24.7+auto}"

if [[ ! "$log_every" =~ ^[1-9][0-9]*$ ]]; then
  echo "invalid CMUX_PTY_STRESS_LOG_EVERY: $log_every" >&2
  exit 2
fi

echo "== unit and integration =="
go test "$package" -run 'Test(WebSocketPTY|ServeWS)' -count=1

echo "== fuzz lease parser =="
go test "$package" -run '^$' -fuzz FuzzConsumeWebSocketLease -fuzztime "$fuzztime"

echo "== fuzz pty size normalizer =="
go test "$package" -run '^$' -fuzz FuzzNormalizePTYSize -fuzztime "$fuzztime"

echo "== build stress binary =="
go test -c "$package" -o "$stress_bin"

deadline_epoch="$(python3 - "$duration" <<'PY'
import re
import sys
import time

raw = sys.argv[1].strip()
match = re.fullmatch(r"(\d+)([smhd]?)", raw)
if not match:
    raise SystemExit(f"invalid duration: {raw}")
value = int(match.group(1))
unit = match.group(2) or "s"
scale = {"s": 1, "m": 60, "h": 3600, "d": 86400}[unit]
print(int(time.time()) + value * scale)
PY
)"

iteration=0
max_rss_kb=0
echo "== stress loop duration=$duration =="
while [[ "$(date +%s)" -lt "$deadline_epoch" ]]; do
  iteration=$((iteration + 1))
  output_file="$(mktemp)"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    set +e
    /usr/bin/time -l "$stress_bin" -test.timeout "$test_timeout" -test.run "$stress_filter" -test.count=1 >"$output_file" 2>&1
    status=$?
    set -e
    rss_kb="$(awk '/maximum resident set size/ {print int($1 / 1024)}' "$output_file" | tail -n 1)"
  else
    set +e
    "$stress_bin" -test.timeout "$test_timeout" -test.run "$stress_filter" -test.count=1 >"$output_file" 2>&1
    status=$?
    set -e
    rss_kb=""
  fi
  if [[ -n "$rss_kb" && "$rss_kb" -gt "$max_rss_kb" ]]; then
    max_rss_kb="$rss_kb"
  fi
  if [[ "$status" -eq 0 ]]; then
    if [[ "$iteration" -eq 1 || $((iteration % log_every)) -eq 0 ]]; then
      if [[ -n "$rss_kb" ]]; then
        echo "stress iteration $iteration ok rss=${rss_kb}KB max_rss=${max_rss_kb}KB"
      else
        echo "stress iteration $iteration ok"
      fi
    fi
  else
    echo "stress iteration $iteration failed"
    cat "$output_file"
    rm -f "$output_file"
    exit 1
  fi
  rm -f "$output_file"
done

if [[ "$max_rss_kb" -gt 0 ]]; then
  echo "stress complete iterations=$iteration max_rss=${max_rss_kb}KB"
else
  echo "stress complete iterations=$iteration"
fi
