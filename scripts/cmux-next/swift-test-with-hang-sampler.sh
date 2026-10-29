#!/usr/bin/env bash
# Runs `swift test` with the given arguments. If it is still running after
# CMUX_NEXT_TEST_HANG_SECONDS (default 1200), or no Swift Testing test has
# finished for CMUX_NEXT_TEST_STUCK_SECONDS (default 300; checked every
# CMUX_NEXT_TEST_STUCK_POLL_SECONDS, default 10), it names the tests open at
# least that long, samples the test processes so the log shows where they are
# stuck, kills them, and fails. Swift Testing has no package-wide time limit (its default limit
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
# A test's name from a Swift Testing console line, and whether that line is a FINISH.
#
# One definition for the watchdog and report(): a copy each once let them disagree.
#
# Every terminal line a test can get, measured against the reporter rather than assumed:
#   ✔ Test f() passed after 0.001 seconds.
#   ✘ Test f() failed after 0.001 seconds with 1 issue.
#   ✘ Test f() passed after 0.001 seconds with 1 known issue.      a ✘ finish is not only a failure
#   ━ Test f() passed after 8.359 seconds with 2 known issues.     a known issue has its own marker
#   ━ Test f() failed after 0.002 seconds with 1 known issue.
#   ➜ Test f() skipped.
#   ➜ Test f() was cancelled after 0.001 seconds.                  swift-testing 6.3, Test.cancel()
#   ✔ Test f(n:) with 2 test cases passed after 0.003 seconds.     parameterized
# name_of strips each tail, or the finish is filed under a name no start used.
# Anchored alternatives, NEVER a bracket set: awk reads [✔✘➜━] as a set of BYTES and every line
# matches. Anchored, so a test's own output cannot self-report.
names_awk='
  function name_of(line) {
    sub(/^[^ ]+ Test /, "", line)
    sub(/ (started\.|recorded an issue at .*|passed after .*|with [0-9]+ test cases? (passed|failed) after .*|failed after .*|was cancelled after .*|skipped.*)$/, "", line)
    return line
  }
  # A test start. The own start of a parameterized case ("◇ Test case passing 1 argument n → 1 to
  # f(n:) started.") is not one: its test has a start of its own. Matched on the whole generated
  # shape, argument count included, so a test whose display name merely begins "case passing" is
  # still counted. Nor is the "Test run started." line of the run itself.
  function is_start(line) {
    return line ~ /^◇ Test .* started\.$/ \
        && line !~ /^◇ Test case passing [0-9]+ arguments? / \
        && line !~ /^◇ Test run started\.$/
  }
  function is_finish(line) {
    return line ~ /^✔ Test / \
        || line ~ /^✘ Test .* (passed|failed) after / \
        || line ~ /^━ Test .* (passed|failed) after / \
        || line ~ /^➜ Test /
  }
  # The runs of NAME that started and have not been closed by a finish, as an inclusive index
  # range into its starts. A finish closes the earliest run still open, so the open runs are
  # always the most recent ones.
  function first_open_run(n) {
    return (n in first_open) ? first_open[n] : 1
  }
  function open_runs(n,    fo) {
    fo = first_open_run(n)
    return started[n] >= fo ? started[n] - fo + 1 : 0
  }
  # The key a run is counted and timed under, per RUN so run 2 never inherits the age of run 1:
  # the run number, a separator, then the name. Number FIRST: a display name can hold anything,
  # so no suffix form is collision-free. run_label turns a key back into words.
  function run_sep() {
    return sprintf("%c", 1)
  }
  function run_key(n, k) {
    return k run_sep() n
  }
  function run_label(key,    at, k) {
    at = index(key, run_sep())
    if (!at) return key
    k = substr(key, 1, at - 1)
    key = substr(key, at + 1)
    key = block_name(key)
    return k + 0 > 1 ? key " (run " k ")" : key
  }
  # Starts and finishes are matched within one test process: each prints its own "Test run
  # started.", and a finish in a later process must never close a start an earlier one lost (a
  # skip of the same name in process 2 would otherwise close the start process 1 never finished).
  # So the name every run is counted under is prefixed with its block number, the same way a run
  # key is prefixed with its run number, and block_name takes it back off for a message.
  function block_sep() {
    return sprintf("%c", 2)
  }
  function block_key(n) {
    return (count_block + 0) block_sep() n
  }
  function block_name(key,    at) {
    at = index(key, block_sep())
    if (at > 1 && substr(key, 1, at - 1) ~ /^[0-9]+$/) return substr(key, at + 1)
    return key
  }'
# The bookkeeping both readers share. Occurrences matched in order, not a set of names: one log
# can hold the same name more than once. A finish only closes a start still open; one with no
# open start (a parameterized case finish) is ignored, never banked for a later run.
# A skip closes nothing: swift-testing skips a test INSTEAD of starting it, and two suites can
# share a bare name, so suite B's skip of exportIsFresh() would close suite A's lost start (seen
# once in 220 skips on a real log). It still counts as watchdog progress.
count_awk='
  /^◇ Test run started\.$/ { count_block++; block_starts[count_block] = 0 }
  is_start($0) {
    counted_name = block_key(name_of($0))
    if (count_block) block_starts[count_block]++
    if (!(counted_name in seen_name)) { seen_name[counted_name] = 1; names[++name_count] = counted_name }
    started[counted_name]++
    start_count++
  }
  is_finish($0) && $0 !~ /^➜ Test .* skipped/ {
    counted_name = block_key(name_of($0))
    # Read it into a variable first. Naming first_open[counted_name] as the target of an
    # assignment CREATES that key before the right-hand side is evaluated, so
    # `first_open[n] = first_open_run(n) + 1` made first_open_run take its "already set" branch
    # and read the empty value it had just created: every finish wrote 1 and closed nothing, and
    # a wholly green run reported every test as unfinished.
    counted_open = first_open_run(counted_name)
    if (counted_open <= started[counted_name]) first_open[counted_name] = counted_open + 1
  }'
# The tests the log shows started and not finished, in start order. The
# run's own "Test run started." line is not a test.
open_tests() {
  awk "$names_awk$count_awk"'
    END {
      for (i = 1; i <= name_count; i++)
        for (k = first_open_run(names[i]); k <= started[names[i]]; k++) print run_key(names[i], k)
    }
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
  # The finish markers, as one grep -E pattern: counting them is how this loop sees progress.
  # Anchored for the same reason the report anchors them, and an alternation rather than a
  # bracket set for the same reason too (a set of these multibyte markers is read as a set of
  # their BYTES, and every line matches).
  finish_re='^(✔ Test |✘ Test .* (passed|failed) after |━ Test .* (passed|failed) after |➜ Test )'
  last_finishes=-1
  last_size=-1
  last_progress=$started_at
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
    # names_awk only for run_label: the keys carried here are run keys, and what a person reads
    # has to be the test name and its run number, not the separator byte that keeps them apart.
    # Split the seen file on its FIRST tab only, by hand rather than on $1 and $2: a test display
    # name may contain a tab, and field splitting would then read part of the name as the next
    # field and lose that run timer.
    awk -v now="$now" -v limit="$stuck_limit" -v next_file="$seen.next" "$names_awk"'
      FILENAME == ARGV[1] {
        at = index($0, "\t")
        if (at) first[substr($0, at + 1)] = substr($0, 1, at - 1)
        next
      }
      {
        at = ($0 in first) ? first[$0] : now
        print at "\t" $0 > next_file
        if (now - at >= limit) printf "%s (%d s)\n", run_label($0), now - at
      }
    ' "$seen" "$open" > "$stuck"
    mv "$seen.next" "$seen"
    # An open test is not a RUNNING test: swift-testing prints "started." as a test is scheduled,
    # and width 6 lets only a few run, so thousands sit open past this limit on a healthy run
    # (cmux#25391 run 40313902783: 3927 open past 300 s, killed with nothing wrong). The signal
    # is PROGRESS: stuck means no test finished in stuck_limit; open ages only pick the names.
    # grep -E: the pattern is an alternation.
    finishes=$(grep -cE "$finish_re" "$log" 2>/dev/null || true)
    finishes=${finishes:-0}
    # With no test open, any output is progress, and silence for the whole limit is a hang too
    # (a helper that never exits after its summary). Only once a test has started: before
    # that, output can lag minutes behind a healthy run (a broad pass printed nothing for 356 s,
    # then its first 2,000 lines at once), so the whole-run limit is the guard there.
    size=$(wc -c < "$log" 2>/dev/null | tr -d ' ')
    if [ "$finishes" != "$last_finishes" ] || { [ ! -s "$open" ] && [ "${size:-0}" != "$last_size" ]; } \
      || ! grep -q '^◇ Test ' "$log" 2>/dev/null; then
      last_progress="$now"
    fi
    last_finishes="$finishes"
    last_size="${size:-0}"
    if (( now - last_progress < stuck_limit )); then
      : > "$stuck"
    elif [ ! -s "$stuck" ]; then
      echo "no test open; the run printed nothing in ${stuck_limit} s" > "$stuck"
    fi
    if [ -s "$stuck" ]; then
      : > "$fired"
      list="$(awk '{ printf "%s%s", (NR > 1 ? "; " : ""), $0 }' "$stuck")"
      count=$(grep -c ' ([0-9]* s)$' "$stuck" || true)
      echo "::error title=cmux-next swift test stuck::no test finished in ${stuck_limit}s (CMUX_NEXT_TEST_STUCK_SECONDS); $count test$([ "$count" = 1 ] || echo s) open at least that long: $list; sampling the test processes"
      if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '### No Swift test finished in %ss; these were open at least that long\n\n' "$stuck_limit" >> "$GITHUB_STEP_SUMMARY"
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

# Prints the ::error lines and the step summary for the run's log. Exits 3 when
# the run was truncated: no "Test run with" summary line, or a summary that
# reports fewer tests than the log shows starting.
report() {
  awk -v summary_file="${GITHUB_STEP_SUMMARY:-}" -v status="$status" "$names_awk$count_awk"'
    function join(list, count,    out, i, max) {
      max = count > 100 ? 100 : count
      for (i = 1; i <= max; i++) out = out (i > 1 ? "; " : "") list[i]
      if (count > max) out = out "; and " (count - max) " more"
      return out
    }
    # Every rule is anchored, so a test printing a reporter-like line cannot mark itself finished.
    # The cost (output run on into a reporter line hides that finish) is a named red, not a pass;
    # all ~12000 marker lines in three real job logs were anchored.
    /^✘ Test .* recorded an issue at / {
      name = name_of($0)
      if (!(name in red)) {
        at = $0; sub(/.* recorded an issue at /, "", at); sub(/:[0-9]+: .*$/, "", at)
        red[name] = 1; reds[++red_count] = name " " at
      }
    }
    /^[^ ]+ Test run with [0-9]+ tests? / {
      has_summary = 1
      # "✔ Test run with 399 tests in 80 suites passed after ...". Taken out of the text rather
      # than as field $5, which says what it reads.
      # Summed, not assigned: one log can hold a summary per test target (the live #25364 step
      # holds dozens, one per isolated suite), and the starts are counted across all of them, so
      # only the total is comparable with start_count.
      counted = $0
      sub(/^[^ ]+ Test run with /, "", counted); sub(/ .*$/, "", counted)
      summary_tests += counted + 0
      if (count_block && !(count_block in block_summary)) block_summary[count_block] = counted + 0
    }
    # Totals can hide one truncated test process behind another, so each run block (one
    # "Test run started." per process) is also held to its own summary and its own starts.
    END {
      if (red_count > 0) {
        printf "::error title=cmux-next swift test reds::%d red tests: %s\n", red_count, join(reds, red_count)
        if (summary_file != "") {
          printf "### %d red Swift tests\n\n", red_count >> summary_file
          for (i = 1; i <= red_count; i++) printf "- `%s`\n", reds[i] >> summary_file
        }
      }
      # Once, for both branches below, and by the same run keys the watchdog lists, so the two
      # name the same runs: open_count counts unfinished RUNS and open_tests names each one.
      for (i = 1; i <= name_count; i++)
        for (k = first_open_run(names[i]); k <= started[names[i]]; k++) {
          open_count++
          open_tests[++open_list] = run_label(run_key(names[i], k))
        }
      if (start_count > 0 && !has_summary) {
        printf "::error title=cmux-next swift test ended early::no \"Test run with\" summary line (crash, kill or truncation); swift test exited %s, and SwiftPM prints no line when the test helper ends on SIGINT, SIGTERM or SIGKILL or exits by itself; %d tests started and never finished: %s\n", status, open_count, join(open_tests, open_list)
        if (summary_file != "") {
          printf "### No Swift Testing summary line: %d unfinished tests\n\n", open_count >> summary_file
          for (i = 1; i <= open_list; i++) printf "- `%s`\n", open_tests[i] >> summary_file
        }
        exit 3
      }
      # A summary counts the tests that REPORTED, so a truncated run can still print one. Whole
      # means every start finished and the summaries count at least the starts (not equality:
      # a skipped test prints no start).
      if (has_summary && start_count > 0) {
        if (open_count > 0 || summary_tests < start_count) {
          if (open_count > 0)
            printf "::error title=cmux-next swift test reported fewer tests than it ran::the summaries count %d tests in total but %d started and %d of those never finished; swift test exited %s. A summary line does not make a truncated run a result: %s\n", summary_tests, start_count, open_count, status, join(open_tests, open_list)
          else
            printf "::error title=cmux-next swift test reported fewer tests than it ran::the summaries count %d tests in total but the log shows %d starting, and every one of those finished; swift test exited %s. A summary that undercounts the log is not a result.\n", summary_tests, start_count, status
          if (summary_file != "") {
            printf "### The run reported %d of %d tests (%d unfinished)\n\n", summary_tests, start_count, open_count >> summary_file
            for (i = 1; i <= open_list; i++) printf "- `%s`\n", open_tests[i] >> summary_file
          }
          exit 3
        }
      }
      for (b = 1; b <= count_block; b++) {
        if (!(b in block_summary)) {
          bad_blocks[++bad_count] = sprintf("test run %d of %d printed no summary after %d starts", b, count_block, block_starts[b])
        } else if (block_summary[b] < block_starts[b]) {
          bad_blocks[++bad_count] = sprintf("test run %d of %d reported %d tests after %d starts", b, count_block, block_summary[b], block_starts[b])
        }
      }
      if (bad_count > 0) {
        printf "::error title=cmux-next swift test ended early::%d of %d test runs in this log are not whole (crash, kill or truncation of one test process); swift test exited %s: %s\n", bad_count, count_block, status, join(bad_blocks, bad_count)
        if (summary_file != "") {
          printf "### %d of %d Swift Testing runs are not whole\n\n", bad_count, count_block >> summary_file
          for (i = 1; i <= bad_count; i++) printf "- %s\n", bad_blocks[i] >> summary_file
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
  crashed=$(python3 "$script_dir/ips-crash-summary.py" \
    "${CMUX_NEXT_CRASH_REPORTS_DIR:-$HOME/Library/Logs/DiagnosticReports}" \
    "${CMUX_NEXT_CRASH_OUT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/swift-test-crash-reports}" \
    "$started_at" "${CMUX_NEXT_CRASH_WAIT_SECONDS:-20}" 2>&1)
  printf '::error title=cmux-next swift test crash::the test helper died on signal %s; crashed thread: %s\n' \
    "$crash_signal" "$(tr '\n' ' ' <<<"${crashed:-no crash report from this run}")"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '### The test helper died on signal %s\n\n%s\n\n' "$crash_signal" "${crashed:-No crash report from this run.}" >> "$GITHUB_STEP_SUMMARY"
  fi
  (( status != 0 )) || status=1
fi

# A truncated run (no summary, or a summary that counts fewer tests than the log
# shows starting) and no signal line: the helper exited by itself or ended on a
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
# A truncated run fails even when swift test exited 0: a missing summary line,
# or a summary that reports fewer tests than the log shows starting.
# So does a report that could not run (an awk error): no verdict is not a pass.
if (( report_status != 0 && status == 0 )); then exit 1; fi
exit "$status"
