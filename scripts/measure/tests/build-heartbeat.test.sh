#!/usr/bin/env bash
# A fleet measurement step that prints nothing for its silent limit (CMUX_CI_MEASURE_SILENT_MAX, 45 min) is stopped
# as hung. A cold build of an older base that logs only to a file took up to ~42 min, and a dock A/B's base build was
# stopped this way. build-heartbeat.sh prints a line every MEASURE_HEARTBEAT_S seconds while such a build runs; this
# checks that it does and stops cleanly, and that every measurement script whose reload.sh output goes only to a file
# starts it. Runs on Linux:
#   bash scripts/measure/tests/build-heartbeat.test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
fail() { echo "build-heartbeat: $*" >&2; exit 1; }

# shellcheck source=../build-heartbeat.sh
source "$here/build-heartbeat.sh"

# The heartbeat names the build, its elapsed time and its log's last line, on stderr only.
log="$root/build.log"
echo "CompileSwift normal arm64 Workspace.swift" >"$log"
MEASURE_HEARTBEAT_S=1 measure_heartbeat_start "NFL build base" "$log" 2>"$root/err" >"$root/out"
sleep 2.5
pid="$MEASURE_HEARTBEAT_PID"
measure_heartbeat_stop
beats="$(grep -c "^NFL build base still building after [0-9]* s: CompileSwift normal arm64 Workspace.swift$" "$root/err" || true)"
[[ "$beats" -ge 2 ]] || fail "expected 2 or more heartbeat lines in 2.5 s, got $beats: $(cat "$root/err")"
[[ ! -s "$root/out" ]] || fail "the heartbeat wrote to stdout (a caller may capture it): $(cat "$root/out")"

# Stopping ends the heartbeat and its sleep at once: nothing is left holding the step's output open.
kill -0 "$pid" 2>/dev/null && fail "the heartbeat process $pid is still running after stop"
[[ -z "$MEASURE_HEARTBEAT_PID" ]] || fail "stop left MEASURE_HEARTBEAT_PID set"
sleep 1.5
after="$(grep -c "still building" "$root/err" || true)"
[[ "$after" == "$beats" ]] || fail "heartbeat lines kept coming after stop ($beats, then $after)"
if pgrep -P "$pid" >/dev/null 2>&1; then fail "the heartbeat's sleep outlived it"; fi

# Stop without a start is a no-op; a second start replaces the first.
measure_heartbeat_stop
MEASURE_HEARTBEAT_S=1 measure_heartbeat_start "a" "$log" 2>/dev/null
first="$MEASURE_HEARTBEAT_PID"
MEASURE_HEARTBEAT_S=1 measure_heartbeat_start "b" "$log" 2>/dev/null
kill -0 "$first" 2>/dev/null && fail "a second start left the first heartbeat running"
measure_heartbeat_stop

# Detector: a measurement script that sends reload.sh's output only to a file (> or >> a file, or tee into
# /dev/null) must start the heartbeat. A build whose output reaches the step log (tee to the console) needs none.
quiet=()
for f in "$here"/*.sh; do
  if grep -E '\./scripts/reload\.sh' "$f" | grep -vE '^\s*#' | grep -qE '(>>?\s*"?\$[^|]*$|>>?\s*"?\$[^|]*\\$|tee [^|]*>\s*/dev/null)'; then
    grep -q 'measure_heartbeat_start' "$f" || quiet+=("$(basename "$f")")
  fi
done
[[ ${#quiet[@]} == 0 ]] || fail "reload.sh logs only to a file with no heartbeat in: ${quiet[*]} (source build-heartbeat.sh and wrap the build in measure_heartbeat_start/stop)"

echo "build-heartbeat: ok"
