# shellcheck shell=bash
# Sourced by measurement scripts. A fleet measurement step that prints nothing for its silent limit
# (CMUX_CI_MEASURE_SILENT_MAX, 45 min) is stopped as hung, and a cold build that logs only to a file can run about
# that long (a base commit's Release build took up to ~42 min). While such a build runs, print one line to stderr every
# MEASURE_HEARTBEAT_S seconds (default 300): what is building, for how long, and its log's last line.
#   measure_heartbeat_start "NFL build base" "$out/build-base.log"
#   ./scripts/reload.sh ... >>"$out/build-base.log" 2>&1
#   measure_heartbeat_stop
# Checked by scripts/measure/tests/build-heartbeat.test.sh, which also fails on a script whose reload.sh output goes
# only to a file without a heartbeat.

MEASURE_HEARTBEAT_PID=""

measure_heartbeat_start() {
  measure_heartbeat_stop
  local label="$1" log="$2" every="${MEASURE_HEARTBEAT_S:-300}" started=$SECONDS
  (
    # TERM ends the wait on the sleep at once; the sleep goes with it, so nothing keeps the step's output open.
    local nap=""
    trap - EXIT # a caller's EXIT trap (a report, a temp folder's removal) is the caller's alone
    trap 'kill "$nap" 2>/dev/null; exit 0' TERM
    while :; do
      sleep "$every" &
      nap=$!
      wait "$nap"
      echo "$label still building after $((SECONDS - started)) s: $(tail -n 1 "$log" 2>/dev/null | tr -d '\r' | cut -c1-160)" >&2
    done
  ) &
  MEASURE_HEARTBEAT_PID=$!
}

measure_heartbeat_stop() {
  [[ -n "${MEASURE_HEARTBEAT_PID:-}" ]] || return 0
  kill "$MEASURE_HEARTBEAT_PID" 2>/dev/null || true
  wait "$MEASURE_HEARTBEAT_PID" 2>/dev/null || true
  MEASURE_HEARTBEAT_PID=""
}
