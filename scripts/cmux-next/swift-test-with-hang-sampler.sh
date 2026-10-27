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
# One definition, used by the watchdog below and by report(): they are the only two readers, and
# having a copy each is how a finish shape came to be handled by one and not the other. The
# watchdog's copy still read a known-issue pass as unfinished after report()'s was fixed, so a
# healthy run whose other tests kept going for stuck_limit would have been sampled and KILLED.
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
# Both verbs on every marker, because which marker carries which verb is the reporter's business.
# name_of must strip each of those tails: a tail it leaves behind becomes part of the key, so the
# finish is filed under a name no start ever used and the test reads as unfinished forever.
#
# Separate anchored alternatives, NEVER a bracket set: awk reads [✔✘➜━] as the set of BYTES those
# characters are made of, and each ends in a byte another also contains, so match() lands
# mid-character and every line matches. Anchored at the line start, so a test's own output
# ("debug: ✔ Test hung() passed...") cannot self-report.
names_awk='
  function name_of(line) {
    sub(/^[^ ]+ Test /, "", line)
    sub(/ (started\.|recorded an issue at .*|passed after .*|with [0-9]+ test cases? (passed|failed) after .*|failed after .*|was cancelled after .*|skipped.*)$/, "", line)
    return line
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
  # The key a run is counted and timed under. Per RUN, not per name: the watchdog remembers when
  # it first saw each key, so if run 2 of a name were keyed the same as run 1, it would inherit
  # run 1 starting time and be killed for an age it never reached.
  #
  # A run key is the run number, a separator, then the name -- the number FIRST, and on every run
  # including the first. A display name is whatever the author wrote, so no suffix form is safe:
  # with readable text, run 2 of `duplicate` collided with run 1 of a test actually named
  # `duplicate (run 2)`, and with the separator as a suffix it still collided with a name that
  # contains the separator. As a prefix, everything up to the FIRST separator is digits this
  # function wrote, so two different runs can never produce one key whatever the name holds.
  # Keys are internal; run_label turns one back into words for a message.
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
    return k + 0 > 1 ? key " (run " k ")" : key
  }'
# The bookkeeping both readers do, in one place for the same reason is_finish is: the watchdog and
# the report must never be able to disagree about what is still running.
#
# Occurrences, matched in order, not a set of names. One log can hold the same test name more than
# once (the isolated-suite step runs each suite in its own process, appending to one log). With a
# set, run 1 finishing covered run 2 starting, so a truncation that only lost names an earlier
# block had already run and summarized read as a pass.
#
# A finish only ever closes a start that is still open. A finish with no open start is ignored
# rather than banked, which is what keeps two shapes harmless: a parameterized test prints a finish
# per case ("✔ Test case passing 1 argument ... passed after ...") whose start line the rule below
# deliberately skips, and a test skipped before it ran prints a "➜ ... skipped." with no start at
# all. Banked, either could have closed a later, real run of the same name.
count_awk='
  /^◇ Test .* started\.$/ && !/^◇ Test case passing / && !/^◇ Test run started\.$/ {
    counted_name = name_of($0)
    if (!(counted_name in seen_name)) { seen_name[counted_name] = 1; names[++name_count] = counted_name }
    started[counted_name]++
    start_count++
  }
  is_finish($0) {
    counted_name = name_of($0)
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
    # An open test is not a RUNNING test. swift-testing prints every test "started." as it enters
    # the run, but SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH (6 in cmux-next.yml) lets only a
    # few execute at a time, so on this suite thousands of tests are legitimately open, and
    # waiting, for far longer than this limit. Measured on the selected-targets step of
    # cmux#25391 run 40313902783: 7159 started, 2003 finished, 3927 open past 300 s, and the
    # watchdog killed the step at exit 143 with nothing wrong -- the same 3925 on the merge-base
    # parser, so this is the premise of the check, not the accounting under it.
    #
    # Lack of PROGRESS is the signal that survives any width: while tests are running, finishes
    # keep arriving, and a run that is truly stuck stops producing them. So the age of an open
    # test only says which tests to NAME; whether the run is stuck is whether any test has
    # finished in the last stuck_limit seconds.
    # -E, not plain grep: the pattern is an alternation, and basic grep reads its parentheses
    # and pipes as literal text, so it matched nothing, progress never advanced after the first
    # poll, and the watchdog killed a run that was finishing a test every second.
    finishes=$(grep -cE "$finish_re" "$log" 2>/dev/null || true)
    finishes=${finishes:-0}
    if [ "$finishes" != "$last_finishes" ]; then
      last_finishes="$finishes"
      last_progress="$now"
    fi
    if (( now - last_progress < stuck_limit )); then
      : > "$stuck"
    fi
    if [ -s "$stuck" ]; then
      : > "$fired"
      list="$(awk '{ printf "%s%s", (NR > 1 ? "; " : ""), $0 }' "$stuck")"
      count=$(wc -l < "$stuck" | tr -d ' ')
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
    # Every rule below is anchored at the start of the line, deliberately. A reporter marker found
    # ANYWHERE on the line would read the output of a test as a reporter event too, so a test that
    # writes "debug: ✔ Test hung() passed after 0.001 seconds." could mark itself finished and a
    # truncated run would pass -- the one failure this whole check exists to prevent. Anchoring
    # trades that for the opposite risk: a test that writes without a trailing newline runs its
    # output into the next reporter line, that finish is not seen, and the start of it makes a
    # whole run look truncated. That is a red naming the exact test rather than silence, so it is
    # the better of the two. Measured before choosing: of ~12000 marker lines across three real job
    # logs (a healthy run, the #23680 truncation and the live #25364 one) every one was anchored,
    # so the run-on shape is hypothetical while the false pass defeats the gate.
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
    }
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
      # A summary line is not proof the run was whole. The summary counts the tests that
      # REPORTED, so a run that ends while tests are still going can still print one, and then a
      # truncated run reads as a normal result -- or as a pass, when the tests that did report
      # were green. Two things hold on a whole run and fail on a truncated one: every test the
      # log shows starting also finishes, and the summaries count at least as many tests as
      # started. Not equality: a skipped test prints no "started." line (so the summary runs
      # ahead of the starts -- 2 starts against "3 tests" on the green fixture, and a healthy
      # CmuxNextAppTests run measured 399 started, 399 finished, "399 tests in 80 suites").
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
if (( report_status == 3 && status == 0 )); then exit 1; fi
exit "$status"
