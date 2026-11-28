#!/usr/bin/env bash
# Sourced at a measure script's top level, from the repo root. The fleet controller stops a measurement that prints
# nothing for 45 minutes (CMUX_CI_MEASURE_SILENT_MAX), and a measure script sends its build's output to a log file, so
# a cold Release build printed nothing past that limit and the step was stopped as hung before its first launch
# (launch-ready.sh dmg=build base= head= of cmux#58981, 2026-11-27; app-at-commit.sh had the same fix for its callers
# since cmux#58024's bench, 2026-11-26).
#
#   measure_quiet LABEL LOG CMD [ARGS...]
# runs CMD with its stdout and stderr appended to LOG and returns CMD's status. Every MEASURE_BUILD_PROGRESS_S seconds
# (300 by default) it prints "LABEL: still building, Ns: <LOG's last line>" on the step's own stdout, saved here as
# fd 9, whatever the caller redirected (stage-table.sh's build runs inside a $(...)).
exec 9>&1

measure_quiet() {
  local label="$1" log="$2" every="${MEASURE_BUILD_PROGRESS_S:-300}" started status ticker
  shift 2
  started="$(date +%s)"
  # The ticker's stdout and stderr are /dev/null and its sleep closes fd 9, so a sleep it leaves behind holds no pipe
  # a $(...) caller would wait on.
  (
    while sleep "$every" 9>&-; do
      echo "$label: still building, $(( $(date +%s) - started ))s: $(tail -n 1 "$log" 2>/dev/null | cut -c1-120)" >&9
    done
  ) >/dev/null 2>&1 &
  ticker=$!
  "$@" >>"$log" 2>&1
  status=$?
  kill "$ticker" 2>/dev/null || true
  wait "$ticker" 2>/dev/null || true
  return "$status"
}
