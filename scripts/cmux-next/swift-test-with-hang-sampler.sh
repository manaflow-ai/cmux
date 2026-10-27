#!/usr/bin/env bash
# Runs `swift test` with the given arguments. If it is still running after
# CMUX_NEXT_TEST_HANG_SECONDS (default 1200), or one Swift Testing test has run
# for CMUX_NEXT_TEST_STUCK_SECONDS (default 300; checked every
# CMUX_NEXT_TEST_STUCK_POLL_SECONDS, default 10), it names the stuck tests,
# samples the test processes so the log shows where they are stuck, kills them,
# and fails. Swift Testing has no package-wide time limit (its default limit
# cannot be set from `swift test`), so a test without its own `.timeLimit`
# would otherwise hold the run until the whole-run limit with no name. Run from
# Packages/macOS/CmuxNext.
#
# After the run it names every red Swift Testing test in one ::error line and
# in the step summary, so a red stays visible when a log viewer truncates the
# step's output. A run that printed Swift Testing output but no "Test run
# with" summary line fails and names the tests that started and never
# finished (a crashed or killed test process) and the status `swift test`
# exited with: SwiftPM prints no line when the helper ends on SIGINT, SIGTERM
# or SIGKILL, or exits by itself. On macOS it then prints the system log's
# errors and faults from the helper and the lines other processes logged
# about it (who ended it). When the test helper dies on a
# signal it also names the signal and the crashed thread's frames from the
# crash report the run left (CMUX_NEXT_CRASH_REPORTS_DIR, default
# ~/Library/Logs/DiagnosticReports), and copies that report to
# CMUX_NEXT_CRASH_OUT (default $RUNNER_TEMP/swift-test-crash-reports) for the
# job to upload.
set -uo pipefail
limit="${CMUX_NEXT_TEST_HANG_SECONDS:-1200}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
started_at=$(date +%s)
# The job's own temp dir when there is one. No log, no run: an empty $log
# would turn the cleanup trap into rm -f "" .*.
log="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/swift-test-log.XXXXXX")" \
  || { echo "::error title=cmux-next swift test::cannot create the test log" >&2; exit 1; }
exec 3> >(tee "$log")
tee_pid=$!
# The crash names itself, in this log, rather than through a file that may never
# arrive. Swift's backtracer prints a symbolicated stack to stderr in-process on
# a fatal error; `enable=tty` is the default, so under Actions it was off and a
# trap left only its one-line message. Run 40330489336 died on signal 6 with
# "Attempted to read an unowned reference" and nothing to attribute it to, and
# ReportCrash had written no report for it within the window either (the search
# of both report directories found 316 reports, all older than the run).
#
# symbolicate=full, not the `symbolicate=off` the xcodebuild jobs use: an
# unsymbolicated stack answers none of the question, and this costs only on a
# run that has already crashed. interactive=no and timeout=0s so it never waits
# for a keypress that cannot come; color=no so the log stays readable.
export SWIFT_BACKTRACE="${SWIFT_BACKTRACE:-enable=yes,interactive=no,timeout=0s,symbolicate=full,color=no,threads=crashed}"
swift test "$@" >&3 2>&1 &
test_pid=$!
# Only this run's processes: on a shared CI Mac other jobs run xctest and
# swiftpm-testing-helper as the same user.
descendants() {
  local child
  for child in $(pgrep -P "$1"); do
    echo "$child"
    descendants "$child"
  done
}
stuck_limit="${CMUX_NEXT_TEST_STUCK_SECONDS:-300}"
poll="${CMUX_NEXT_TEST_STUCK_POLL_SECONDS:-10}"
helpers="$log.helpers"
: > "$helpers"
# A test's name from a Swift Testing console line.
names_awk='
  function name_of(line) {
    sub(/^[^ ]+ Test /, "", line)
    sub(/ (started\.|recorded an issue at .*|passed after .*|with [0-9]+ test cases? (passed|failed) after .*|failed after .*|skipped.*)$/, "", line)
    return line
  }'
# The tests the log shows started and not finished, in start order. The
# run's own "Test run started." line is not a test.
open_tests() {
  awk "$names_awk"'
    /^◇ Test .* started\.$/ && !/^◇ Test case passing / && !/^◇ Test run started\.$/ {
      name = name_of($0)
      if (!(name in started)) { started[name] = 1; starts[++count] = name }
    }
    /^✔ Test / || /^✘ Test .* failed after / || /^➜ Test / { finished[name_of($0)] = 1 }
    END { for (i = 1; i <= count; i++) if (!(starts[i] in finished)) print starts[i] }
  ' "$1"
}
# Samples this run's test processes, then ends them and the run.
sample_and_kill() {
  local tree p
  tree="$(descendants "$test_pid")"
  for p in $tree; do
    case "$(ps -o comm= -p "$p" 2>/dev/null)" in
      *xctest|*swiftpm-testing-helper)
        echo "=== sample $p"
        sample "$p" 5 -mayDie 2>&1 | head -n 800 ;;
    esac
  done
  for p in $tree; do
    kill "$p" 2>/dev/null
  done
  kill "$test_pid" 2>/dev/null
}
(
  exec 3>&-
  # Killing the watcher also ends its sleep, so no orphan holds stdout open.
  sleeper=""
  trap '[ -z "$sleeper" ] || kill "$sleeper" 2>/dev/null; exit 0' TERM
  seen="$log.seen" open="$log.open" stuck="$log.stuck" fired="$log.fired"
  : > "$seen"
  while :; do
    sleep "$poll" &
    sleeper=$!
    wait "$sleeper"
    sleeper=""
    now=$(date +%s)
    # The helper's pid, for the system log after a run that lost it.
    for p in $(descendants "$test_pid"); do
      case "$(ps -o comm= -p "$p" 2>/dev/null)" in
        *xctest|*swiftpm-testing-helper) grep -qx "$p" "$helpers" || echo "$p" >> "$helpers" ;;
      esac
    done
    if (( now - started_at >= limit )); then
      : > "$fired"
      echo "::error title=cmux-next swift test hang::swift test still running after ${limit}s; sampling the test processes"
      sample_and_kill
      exit 0
    fi
    # How long each open test has run, from the poll that first saw it.
    open_tests "$log" > "$open"
    : > "$seen.next"
    awk -F'\t' -v now="$now" -v limit="$stuck_limit" -v next_file="$seen.next" '
      FILENAME == ARGV[1] { first[$2] = $1; next }
      {
        at = ($0 in first) ? first[$0] : now
        print at "\t" $0 > next_file
        if (now - at >= limit) printf "%s (%d s)\n", $0, now - at
      }
    ' "$seen" "$open" > "$stuck"
    mv "$seen.next" "$seen"
    if [ -s "$stuck" ]; then
      : > "$fired"
      list="$(awk '{ printf "%s%s", (NR > 1 ? "; " : ""), $0 }' "$stuck")"
      count=$(wc -l < "$stuck" | tr -d ' ')
      echo "::error title=cmux-next swift test stuck::$count test$([ "$count" = 1 ] || echo s) still running after ${stuck_limit}s (CMUX_NEXT_TEST_STUCK_SECONDS): $list; sampling the test processes"
      if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '### Swift tests still running after %ss\n\n' "$stuck_limit" >> "$GITHUB_STEP_SUMMARY"
        # shellcheck disable=SC2016 # the backticks are Markdown, not a command
        sed 's/^\(.*\) (\([0-9]*\) s)$/- `\1` (\2 s)/' "$stuck" >> "$GITHUB_STEP_SUMMARY"
      fi
      sample_and_kill
      exit 0
    fi
  done
) &
watcher=$!
# The cleanup trap comes after every fork: a child forked with it inherits it,
# and the watcher, killed before its first line runs (the run ended at once,
# a loaded host), ran it and deleted the log before the report read it
# (swift-test-summary.test.sh, 1 in 10 runs at 32 checks at once).
trap 'rm -f "$log" "$log".*' EXIT
wait "$test_pid"
status=$?
# Stop the watcher before reporting: the tests a lost helper left open stay
# open in the log, and must not read as stuck while the report runs. A watcher
# that fired is still ending the run's processes: let it finish.
if [ -e "$log.fired" ]; then
  wait "$watcher" 2>/dev/null
else
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
fi
exec 3>&-
# The report reads the log, so its writer must be done. bash 3.2 cannot wait for a
# process substitution (wait returns at once), so watch tee's pid end, up to 10 s.
if ! wait "$tee_pid" 2>/dev/null; then
  for _ in $(seq 1 200); do
    kill -0 "$tee_pid" 2>/dev/null || break
    sleep 0.05
  done
fi

# Prints the ::error lines and the step summary for the run's log. Exits 3
# when Swift Testing output has no "Test run with" summary line.
report() {
  awk -v summary_file="${GITHUB_STEP_SUMMARY:-}" -v status="$status" '
    function name_of(line) {
      sub(/^[^ ]+ Test /, "", line)
      sub(/ (started\.|recorded an issue at .*|passed after .*|with [0-9]+ test cases? (passed|failed) after .*|failed after .*|skipped.*)$/, "", line)
      return line
    }
    function join(list, count,    out, i, max) {
      max = count > 100 ? 100 : count
      for (i = 1; i <= max; i++) out = out (i > 1 ? "; " : "") list[i]
      if (count > max) out = out "; and " (count - max) " more"
      return out
    }
    /^✘ Test .* recorded an issue at / {
      name = name_of($0)
      if (!(name in red)) {
        at = $0; sub(/.* recorded an issue at /, "", at); sub(/:[0-9]+: .*$/, "", at)
        red[name] = 1; reds[++red_count] = name " " at
      }
    }
    /^◇ Test .* started\.$/ && !/^◇ Test case passing / && !/^◇ Test run started\.$/ {
      name = name_of($0)
      if (!(name in started)) { started[name] = 1; starts[++start_count] = name }
    }
    /^✔ Test / || /^✘ Test .* failed after / || /^➜ Test / { finished[name_of($0)] = 1 }
    /^[^ ]+ Test run with [0-9]+ tests? / { has_summary = 1 }
    END {
      if (red_count > 0) {
        printf "::error title=cmux-next swift test reds::%d red tests: %s\n", red_count, join(reds, red_count)
        if (summary_file != "") {
          printf "### %d red Swift tests\n\n", red_count >> summary_file
          for (i = 1; i <= red_count; i++) printf "- `%s`\n", reds[i] >> summary_file
        }
      }
      if (start_count > 0 && !has_summary) {
        for (i = 1; i <= start_count; i++) if (!(starts[i] in finished)) open_tests[++open_count] = starts[i]
        printf "::error title=cmux-next swift test ended early::no \"Test run with\" summary line (crash, kill or truncation); swift test exited %s, and SwiftPM prints no line when the test helper ends on SIGINT, SIGTERM or SIGKILL or exits by itself; %d tests started and never finished: %s\n", status, open_count, join(open_tests, open_count)
        if (summary_file != "") {
          printf "### No Swift Testing summary line: %d unfinished tests\n\n", open_count >> summary_file
          for (i = 1; i <= open_count; i++) printf "- `%s`\n", open_tests[i] >> summary_file
        }
        exit 3
      }
    }
  ' "$log"
}
report
report_status=$?

# A test helper killed by a signal (5 is a Swift runtime trap) leaves no
# summary and thousands of unfinished tests; its crash report names the test.
crash_signal=$(sed -n 's/.*exited with unexpected signal code \([0-9][0-9]*\).*/\1/p' "$log" | head -n 1)
if [[ -n "$crash_signal" ]]; then
  # Both report directories, system one first. A test helper on a CI Mac leaves
  # its report in /Library/Logs/DiagnosticReports, not the $HOME one a login
  # session gets, so searching $HOME alone reported no crash report for a run
  # that had plainly died on signal 6 (run 40330489336).
  crashed=$(python3 "$script_dir/ips-crash-summary.py" \
    "${CMUX_NEXT_CRASH_REPORTS_DIR:-/Library/Logs/DiagnosticReports:$HOME/Library/Logs/DiagnosticReports}" \
    "${CMUX_NEXT_CRASH_OUT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/swift-test-crash-reports}" \
    "$started_at" "${CMUX_NEXT_CRASH_WAIT_SECONDS:-20}" 2>&1)
  printf '::error title=cmux-next swift test crash::the test helper died on signal %s; crashed thread: %s\n' \
    "$crash_signal" "$(tr '\n' ' ' <<<"${crashed:-no crash report from this run}")"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '### The test helper died on signal %s\n\n%s\n\n' "$crash_signal" "${crashed:-No crash report from this run.}" >> "$GITHUB_STEP_SUMMARY"
  fi
  (( status != 0 )) || status=1
fi

# No summary and no signal line: the helper exited by itself or ended on a
# signal SwiftPM does not print. The system log says which: what the helper
# logged as an error or fault, and what the kernel, launchd, RunningBoard,
# WindowServer, loginwindow or Launch Services logged about its pid.
if (( report_status == 3 )) && [[ -z "$crash_signal" && "$(uname)" == Darwin ]] && [ -s "$helpers" ]; then
  log_start="$(date -r "$started_at" '+%Y-%m-%d %H:%M:%S')"
  while read -r p; do
    echo "=== system log about test helper $p since $log_start"
    log show --style compact --start "$log_start" --predicate "(processIdentifier == $p AND (messageType == \"error\" OR messageType == \"fault\")) OR (processIdentifier != $p AND eventMessage CONTAINS \"$p\" AND process IN {\"kernel\", \"launchd\", \"runningboardd\", \"WindowServer\", \"loginwindow\", \"launchservicesd\"})" 2>&1 | tail -n 150
  done < "$helpers"
fi

# The watcher fired: always fail, whatever status the killed run reported.
if [ -e "$log.fired" ]; then exit $(( status == 0 ? 1 : status )); fi
# A missing summary line fails the run even when swift test exited 0.
if (( report_status == 3 && status == 0 )); then exit 1; fi
exit "$status"
