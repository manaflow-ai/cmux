#!/usr/bin/env bash
# SWIFT-TEST-SUMMARY: swift-test-with-hang-sampler.sh names every red Swift
# Testing test in one ::error line and in the step summary, so a red stays
# visible when a log viewer truncates the step's output. If the run ends
# without the "Test run with" summary line, it fails and names the tests that
# started and never finished (a crashed or killed test process). A summary line
# is not proof the run was whole either: it counts the tests that reported, so
# a run that ends mid-flight still prints one. The job fails when the summaries
# count fewer tests than the log shows starting, or when any started test never
# finished, and each test process's run ("Test run started.") must print its
# own summary counting at least its own starts. The reporter lines are read
# anchored, so a test cannot report itself finished.
# A test still running after CMUX_NEXT_TEST_STUCK_SECONDS is named while the run is going.
# No Swift: a stub `swift` prints canned Swift Testing output.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf '%s\n' "$@" >&2; exit 1; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/swift" <<'EOF'
#!/usr/bin/env bash
cat "$STUB_OUTPUT"
# A helper's crash report, written during the run with this process as its parent:
# the wrapper counts only reports from its own `swift test` and the helpers it saw.
if [[ -n "${STUB_CRASH_REPORT:-}" ]]; then
  sed "s/__PARENT_PID__/$$/" "$STUB_CRASH_REPORT" > "$STUB_CRASH_REPORT_DEST"
  # The run starts at a whole second, so date the report ahead of it; otherwise a
  # write at X.9 and a start at X+1 reads it as from before.
  python3 -c 'import os,sys,time; t=time.time()+60; os.utime(sys.argv[1],(t,t))' "$STUB_CRASH_REPORT_DEST"
fi
# A run that keeps finishing tests while the watchdog watches: one line per STUB_DRIP_SECONDS,
# which is what a healthy width-limited run looks like (thousands open, finishes still arriving).
if [[ -n "${STUB_DRIP:-}" ]]; then
  i=0
  while (( i < STUB_DRIP )); do
    i=$((i + 1))
    printf '✔ Test drip%d() passed after 0.001 seconds.\n' "$i"
    sleep "${STUB_DRIP_SECONDS:-1}"
  done
fi
# A test that never returns: the wrapper has to end it.
[[ -z "${STUB_SLEEP:-}" ]] || sleep "$STUB_SLEEP"
# A run that keeps the CPU busy and finishes nothing for STUB_BUSY seconds: a spin, or a runner so
# starved that one test takes minutes. Then STUB_AFTER's lines, the finishes it got to.
if [[ -n "${STUB_BUSY:-}" ]]; then
  end=$((SECONDS + STUB_BUSY))
  while (( SECONDS < end )); do :; done
fi
[[ -z "${STUB_AFTER:-}" ]] || cat "$STUB_AFTER"
exit "${STUB_STATUS:-0}"
EOF
chmod +x "$TMP/bin/swift"

# run <name> <status>: runs the wrapper on $TMP/<name>.out; sets out, summary, status.
# STUB_PATH goes ahead of the stub swift on PATH (a slow tee).
run() {
  export STUB_OUTPUT="$TMP/$1.out" STUB_STATUS="$2" GITHUB_STEP_SUMMARY="$TMP/$1.summary"
  : > "$GITHUB_STEP_SUMMARY"
  status=0
  # The sampler's log lives in this test's own TMPDIR: on CI the check runs beside
  # many others, and its /tmp/swift-test-log.* was once gone before it was read.
  mkdir -p "$TMP/tmp"
  out=$(PATH="${STUB_PATH:+$STUB_PATH:}$TMP/bin:$PATH" TMPDIR="$TMP/tmp" CMUX_NEXT_TEST_HANG_SECONDS=60 \
    bash "$ROOT/scripts/cmux-next/swift-test-with-hang-sampler.sh" --skip-build 2>&1) || status=$?
  summary=$(cat "$GITHUB_STEP_SUMMARY")
}

# A green run: exit 0 and no error.
cat > "$TMP/green.out" <<'EOF'
◇ Test aPasses() started.
✔ Test aPasses() passed after 0.001 seconds.
◇ Test case passing 1 argument n → 1 to cases(n:) started.
✔ Test cases(n:) with 1 test case passed after 0.001 seconds.
➜ Test needsADisplay() skipped: "no window session"
✔ Test run with 3 tests in 1 suite passed after 0.002 seconds.
EOF
run green 0
[[ "$status" == 0 ]] || fail "a green run exited $status" "$out"
[[ "$out" != *"::error"* ]] || fail "a green run printed an error" "$out"

# A red run with its summary: keeps the exit status, names each red test once
# with its first issue's location, in one ::error line and the step summary.
cat > "$TMP/red.out" <<'EOF'
◇ Test aFails() started.
✘ Test aFails() recorded an issue at AFileTests.swift:12:9: Expectation failed: 1 == 2
✘ Test aFails() recorded an issue at AFileTests.swift:13:9: Expectation failed: 3 == 4
✘ Test aFails() failed after 0.010 seconds with 2 issues.
◇ Test aTimesOut() started.
✘ Test aTimesOut() recorded an issue at BFileTests.swift:40:6: Time limit was exceeded: 60.000 seconds
✘ Test aTimesOut() failed after 60.000 seconds with 1 issue.
◇ Test aPasses() started.
✔ Test aPasses() passed after 0.001 seconds.
✘ Test run with 3 tests in 2 suites failed after 60.010 seconds with 3 issues.
EOF
run red 1
[[ "$status" == 1 ]] || fail "a red run exited $status, not 1" "$out"
errors=$(grep -c '^::error' <<<"$out" || true)
[[ "$errors" == 1 ]] || fail "a red run printed $errors ::error lines, not 1" "$out"
grep '^::error' <<<"$out" | grep -q 'aFails() AFileTests.swift:12' || fail "the error does not name aFails() at its first issue" "$out"
grep '^::error' <<<"$out" | grep -q 'aTimesOut() BFileTests.swift:40' || fail "the error does not name aTimesOut()" "$out"
grep '^::error' <<<"$out" | grep -q '2 red' || fail "the error does not count 2 red tests" "$out"
if grep '^::error' <<<"$out" | grep -q 'aPasses'; then fail "the error names a passing test" "$out"; fi
grep -q 'aFails() AFileTests.swift:12' <<<"$summary" || fail "the step summary does not name aFails()" "$summary"
grep -q 'aTimesOut()' <<<"$summary" || fail "the step summary does not name aTimesOut()" "$summary"

# The log's writer finishes after swift does: a tee that writes late. The report
# still reads the whole log, because the wrapper waits for its tee to end (bash 3.2
# cannot `wait` for a process substitution; run this under /bin/bash to see it).
mkdir -p "$TMP/slow"
cat > "$TMP/slow/tee" <<'EOF'
#!/usr/bin/env bash
in=$(cat); sleep 1; printf '%s\n' "$in" > "$1"; printf '%s\n' "$in"
EOF
chmod +x "$TMP/slow/tee"
STUB_PATH="$TMP/slow" run red 1
grep '^::error' <<<"$out" | grep -q 'aFails() AFileTests.swift:12' || fail "a late-written log was read before its writer finished" "$out"

# No summary line although swift exited 0: the run fails and names the tests
# that started and never finished, and not the finished ones.
cat > "$TMP/cut.out" <<'EOF'
◇ Test run started.
◇ Test aPasses() started.
✔ Test aPasses() passed after 0.001 seconds.
◇ Test hangsForever() started.
◇ Test crashesHere() started.
◇ Test case passing 1 argument n → 1 to cases(n:) started.
EOF
run cut 0
[[ "$status" != 0 ]] || fail "a run without its summary line exited 0" "$out"
grep '^::error' <<<"$out" | grep -q 'no "Test run with" summary' || fail "the error does not say the summary is missing" "$out"
grep '^::error' <<<"$out" | grep -q 'hangsForever()' || fail "the error does not name hangsForever()" "$out"
grep '^::error' <<<"$out" | grep -q 'crashesHere()' || fail "the error does not name crashesHere()" "$out"
if grep '^::error' <<<"$out" | grep -q 'aPasses'; then fail "the error names a finished test" "$out"; fi
# "Test run started." is the run, not a test.
grep '^::error' <<<"$out" | grep -q ' 2 tests started and never finished: hangsForever()' || fail "the error counts the run itself as an unfinished test" "$out"
grep -q 'hangsForever()' <<<"$summary" || fail "the step summary does not name hangsForever()" "$summary"
# A cut-short run reports itself as incomplete, never as a pass or a plain red.
grep -q '^::error title=cmux-next swift test incomplete::' <<<"$out" || fail "a cut-short run is not titled incomplete" "$out"
if grep -q '^::error title=cmux-next swift test ended early' <<<"$out"; then fail "a cut-short run still says ended early, not incomplete" "$out"; fi
grep -q '^### Incomplete: ' <<<"$summary" || fail "the step summary does not say the run is incomplete" "$summary"
grep '^::error title=cmux-next swift test cut short::' <<<"$out" \
  | grep -q 'cut short by the test process ending before its summary (swift test exited 0): 1 tests finished (1 passed, 0 failed, 0 skipped) and 2 started and never finished' \
  || fail "a run that ended before its summary does not count what it got done" "$out"

# A crash exit without a summary keeps its status and names the unfinished test.
run cut 139
[[ "$status" == 139 ]] || fail "a crashed run exited $status, not 139" "$out"
grep '^::error' <<<"$out" | grep -q 'crashesHere()' || fail "a crashed run does not name crashesHere()" "$out"

# The test helper dies on a signal (signal 5 is a Swift runtime trap): the run
# fails, one ::error names the signal and the crashed thread's frames from the
# crash report written during the run, and that report is copied out for
# upload. A report from before the run is neither read nor copied.
reports="$TMP/DiagnosticReports"; crashes="$TMP/crashes"
mkdir -p "$reports"
printf '%s\n' '{"app_name":"swiftpm-testing-helper","bug_type":"309","name":"swiftpm-testing-helper"}' \
  '{"pid":4242,"parentPid":__PARENT_PID__,"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"faultingThread":2,"usedImages":[{"name":"libswift_Concurrency.dylib"},{"name":"CmuxNextPackageTests"}],"threads":[{"frames":[{"imageIndex":1,"symbol":"idleThread"}]},{"frames":[]},{"triggered":true,"frames":[{"imageIndex":0,"symbol":"swift_task_checkIsolatedSwift"},{"imageIndex":1,"symbol":"KeyWindowObserver.windowWillClose(_:)"},{"imageIndex":1,"symbol":"closure #1 in BrowserPopupPanelThreadTests.anOpenerCloseNoticePostedOffMainClosesItsPopupsOnMain()"}]}]}' \
  > "$TMP/trap.ips"
printf '%s\n' '{"app_name":"swiftpm-testing-helper"}' '{"threads":[{"triggered":true,"frames":[{"imageIndex":0,"symbol":"anOldCrash"}]}],"usedImages":[{"name":"x"}]}' \
  > "$reports/swiftpm-testing-helper-old.ips"
touch -t 202001010000 "$reports/swiftpm-testing-helper-old.ips"
cat > "$TMP/trap.out" <<'OUT'
◇ Test anOpenerCloseNoticePostedOffMainClosesItsPopupsOnMain() started.
◇ Test aPasses() started.
✔ Test aPasses() passed after 0.001 seconds.
error: Process '/Applications/Xcode_26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper --test-bundle-path /x/CmuxNextPackageTests.xctest/Contents/MacOS/CmuxNextPackageTests --testing-library swift-testing' exited with unexpected signal code 5
OUT
export CMUX_NEXT_CRASH_REPORTS_DIR="$reports" CMUX_NEXT_CRASH_OUT="$crashes"
STUB_CRASH_REPORT="$TMP/trap.ips" STUB_CRASH_REPORT_DEST="$reports/swiftpm-testing-helper-2026-10-09-021500.ips" \
  CMUX_NEXT_CRASH_WAIT_SECONDS=0 run trap 1
unset CMUX_NEXT_CRASH_REPORTS_DIR CMUX_NEXT_CRASH_OUT
[[ "$status" != 0 ]] || fail "a run whose test helper died on a signal exited 0" "$out"
crash=$(grep '^::error title=cmux-next swift test crash' <<<"$out" || true)
[[ -n "$crash" ]] || fail "no crash ::error line" "$out"
grep -q 'signal 5' <<<"$crash" || fail "the crash error does not name signal 5" "$crash"
grep -q 'BrowserPopupPanelThreadTests.anOpenerCloseNoticePostedOffMainClosesItsPopupsOnMain' <<<"$crash" \
  || fail "the crash error does not name the crashed thread's test frame" "$crash"
grep -q 'KeyWindowObserver.windowWillClose' <<<"$crash" || fail "the crash error does not list the trapping frame" "$crash"
if grep -q 'idleThread\|anOldCrash' <<<"$crash"; then fail "the crash error read another thread or an old report" "$crash"; fi
[[ -f "$crashes/swiftpm-testing-helper-2026-10-09-021500.ips" ]] || fail "the crash report was not copied out" "$(ls -la "$crashes" 2>&1)"
[[ ! -e "$crashes/swiftpm-testing-helper-old.ips" ]] || fail "a report from before the run was copied" "$(ls "$crashes")"
grep -q 'BrowserPopupPanelThreadTests' <<<"$summary" || fail "the step summary does not show the crashed thread" "$summary"

# A run with no Swift Testing output at all (XCTest only, or no test matched
# the filter) needs no summary line.
printf 'Test Suite %s passed\n\t Executed 2 tests, with 0 failures\n' "'All tests'" > "$TMP/xctest.out"
run xctest 0
[[ "$status" == 0 ]] || fail "an XCTest-only run exited $status" "$out"
[[ "$out" != *"::error"* ]] || fail "an XCTest-only run printed an error" "$out"

# A run whose helper ends without a summary and without a signal line: SwiftPM
# prints nothing for SIGINT, SIGTERM or SIGKILL, so the error gives the status
# swift test exited with and says that.
run cut 1
grep '^::error' <<<"$out" | grep -q 'swift test exited 1' || fail "the error does not give the exit status" "$out"
grep '^::error' <<<"$out" | grep -q 'SIGKILL' || fail "the error does not say a silent signal is possible" "$out"

# A truncated run that DOES print a summary: the process ends while tests are
# still going, so the summary counts only the ones that reported. Every test
# that reported passed and swift test exited 0, so without this check the run
# reads as a pass and the tests that never ran are invisible. #23680's own log
# printed no summary (2192 counted against 4736 started and 2890 unfinished, so
# the earlier check caught it); this is that log's counts in the shape that gets
# a summary too, which is the shape nothing caught. The run fails and names the
# unfinished tests, not the finished one.
cat > "$TMP/short.out" <<'EOF'
◇ Test run started.
◇ Test aPasses() started.
✔ Test aPasses() passed after 0.001 seconds.
◇ Test stillGoing() started.
◇ Test alsoStillGoing() started.
✔ Test run with 1 test in 1 suite passed after 0.002 seconds.
EOF
run short 0
[[ "$status" != 0 ]] || fail "a truncated run with a summary line exited 0" "$out"
short_error=$(grep '^::error title=cmux-next swift test incomplete::reported fewer' <<<"$out" || true)
[[ -n "$short_error" ]] || fail "no short-run ::error line" "$out"
grep -q 'summaries count 1 tests in total but 3 started and 2 of those never finished' <<<"$short_error" \
  || fail "the error does not give the three counts" "$short_error"
grep -q 'stillGoing()' <<<"$short_error" || fail "the error does not name stillGoing()" "$short_error"
grep -q 'alsoStillGoing()' <<<"$short_error" || fail "the error does not name alsoStillGoing()" "$short_error"
if grep -q 'aPasses' <<<"$short_error"; then fail "the error names a finished test" "$short_error"; fi
grep -q 'stillGoing()' <<<"$summary" || fail "the step summary does not name the unfinished tests" "$summary"

# A summary that counts fewer tests than the log shows starting, with every
# started test finished: the count itself is the evidence, so the run fails
# without an unfinished test to name.
cat > "$TMP/undercount.out" <<'EOF'
◇ Test aPasses() started.
✔ Test aPasses() passed after 0.001 seconds.
◇ Test bPasses() started.
✔ Test bPasses() passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.002 seconds.
EOF
run undercount 0
[[ "$status" != 0 ]] || fail "a summary that undercounts the log exited 0" "$out"
grep '^::error' <<<"$out" | grep -q 'count 1 tests in total but the log shows 2 starting' \
  || fail "the error does not say the summary undercounts the log" "$out"

# A skipped test prints no "started." line, so the summary legitimately counts
# more than the log shows starting: that is not a truncation. The green case
# above is exactly this shape (2 started, "3 tests"), and it must stay green.
grep -q 'needsADisplay' "$TMP/green.out" || fail "the green fixture no longer covers a skip without a start line"

# One log, one summary per test target: the starts are counted across the whole
# log, so each target's own count is smaller than the total and only their sum
# is comparable. Two whole runs in one log are not a truncation.
cat > "$TMP/twotargets.out" <<'EOF'
◇ Test aPasses() started.
✔ Test aPasses() passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.002 seconds.
◇ Test bPasses() started.
✔ Test bPasses() passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.002 seconds.
EOF
run twotargets 0
[[ "$status" == 0 ]] || fail "two whole runs in one log exited $status" "$out"
[[ "$out" != *"::error"* ]] || fail "two whole runs in one log printed an error" "$out"

# And a truncation inside the second of two targets still fails: the summaries
# total 2, the log shows 3 starting, and one of those never finished.
cat > "$TMP/twotargetscut.out" <<'EOF'
◇ Test aPasses() started.
✔ Test aPasses() passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.002 seconds.
◇ Test bPasses() started.
◇ Test cStillGoing() started.
✔ Test bPasses() passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.002 seconds.
EOF
run twotargetscut 0
[[ "$status" != 0 ]] || fail "a truncation inside the second target exited 0" "$out"
grep '^::error' <<<"$out" | grep -q 'count 2 tests in total but 3 started and 1 of those never finished' \
  || fail "the error does not total the summaries" "$out"
grep '^::error' <<<"$out" | grep -q 'cStillGoing()' || fail "the error does not name cStillGoing()" "$out"

# A finish is not only ✔ or ✘. Both markers a known issue can carry mean FINISHED, and
# reading either as unfinished fails a whole green run.
#
# The "━" case is not hypothetical: this is the real shape, copied from the daemon-tests job
# of cmux#25391 (2026-10-26), where an earlier version of this gate read it as unfinished and
# failed a run of 386 tests whose own summary counted all 386.
cat > "$TMP/knownissue.out" <<'EOF'
◇ Test knownIssue() started.
✘ Test knownIssue() passed after 0.001 seconds with 1 known issue.
◇ Test aRunCutOffMidwayFinishesWithoutDuplicates() started.
━ Test aRunCutOffMidwayFinishesWithoutDuplicates() recorded a known issue at ClassicUpgradeSimulationTests.swift:162:23: Expectation failed
━ Test aRunCutOffMidwayFinishesWithoutDuplicates() passed after 8.359 seconds with 2 known issues.
◇ Test aPasses() started.
✔ Test aPasses() passed after 0.001 seconds.
✔ Test run with 3 tests in 1 suite passed after 8.361 seconds.
EOF
run knownissue 0
[[ "$status" == 0 ]] || fail "a test that passed with a known issue exited $status" "$out"
[[ "$out" != *"::error"* ]] || fail "a test that passed with a known issue printed an error" "$out"

# And a known-issue FAILURE is a finish too, in a run that is red for that reason: the gate's
# job is the truncation, so it must not add a second error on top of a red the job already has.
cat > "$TMP/knownissuefail.out" <<'EOF'
◇ Test knownIssueFails() started.
━ Test knownIssueFails() failed after 0.002 seconds with 1 known issue.
✘ Test run with 1 test in 1 suite failed after 0.003 seconds with 1 issue.
EOF
run knownissuefail 1
[[ "$out" != *"never finished"* ]] \
  || fail "a known-issue failure was read as unfinished" "$out"

# The reporter lines are read anchored at the start of the line, and these two cases
# are the two sides of that choice.
#
# A test's own output is never read as a reporter event. A test that writes
# "✔ Test hung() passed after ..." cannot mark itself finished, so a truncated run
# still fails: that is the failure this whole check exists to prevent, and a marker
# matched anywhere on the line would let a hung test hide behind its own output.
cat > "$TMP/selfreport.out" <<'EOF'
◇ Test hung() started.
debug: ✔ Test hung() passed after 0.001 seconds.
◇ Test aPasses() started.
✔ Test aPasses() passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.002 seconds.
EOF
run selfreport 0
[[ "$status" != 0 ]] || fail "a test that printed its own finish line passed as finished" "$out"
grep '^::error' <<<"$out" | grep -q 'hung()' || fail "the error does not name the test that never finished" "$out"
if grep '^::error' <<<"$out" | grep -q 'aPasses'; then fail "the error names a finished test" "$out"; fi

# The other side: a test that writes without a trailing newline runs its output into
# the next reporter line, so that finish is not seen and the run fails naming it. A
# red naming the exact test, never a silent pass. Of ~12000 marker lines across three
# real job logs every one was anchored, so this shape is the rarer of the two.
cat > "$TMP/runon.out" <<'EOF'
◇ Test aPasses() started.
progress: ✔ Test aPasses() passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.002 seconds.
EOF
run runon 0
[[ "$status" != 0 ]] || fail "a finish line the output ran into was read as a finish" "$out"
grep '^::error' <<<"$out" | grep -q 'aPasses()' || fail "the error does not name the test whose finish was swallowed" "$out"

# One test hangs while the others finish: past CMUX_NEXT_TEST_STUCK_SECONDS the
# run fails within seconds, not at the whole-run limit, and one ::error names
# the stuck test and how long it ran; finished tests are not named, nor a
# parameterized test that failed (its line says "with N test cases").
cat > "$TMP/stuck.out" <<'EOF2'
◇ Test aPasses() started.
✔ Test aPasses() passed after 0.001 seconds.
◇ Test eachFails(n:) started.
◇ Test case passing 1 argument n → 1 to eachFails(n:) started.
✘ Test case passing 1 argument n → 1 to eachFails(n:) failed after 0.001 seconds with 1 issue.
◇ Test case passing 1 argument n → 2 to eachFails(n:) started.
✘ Test case passing 1 argument n → 2 to eachFails(n:) failed after 0.001 seconds with 1 issue.
✘ Test eachFails(n:) with 2 test cases failed after 0.002 seconds with 2 issues.
◇ Test stuckHere() started.
EOF2
started=$SECONDS
STUB_SLEEP=60 CMUX_NEXT_TEST_STUCK_SECONDS=2 CMUX_NEXT_TEST_STUCK_POLL_SECONDS=1 run stuck 0
(( SECONDS - started < 30 )) || fail "a stuck test was ended only after $((SECONDS - started)) s" "$out"
[[ "$status" != 0 ]] || fail "a run with a stuck test exited 0" "$out"
stuck=$(grep '^::error title=cmux-next swift test stuck' <<<"$out" || true)
[[ -n "$stuck" ]] || fail "no stuck-test ::error line" "$out"
grep -q 'stuckHere()' <<<"$stuck" || fail "the stuck error does not name stuckHere()" "$stuck"
if grep -q 'aPasses\|eachFails' <<<"$stuck"; then fail "the stuck error names a finished test" "$stuck"; fi
grep -q '1 test open at least 2s' <<<"$stuck" || fail "the stuck error miscounts" "$stuck"
grep -q 'stuckHere()' <<<"$summary" || fail "the step summary does not name the stuck test" "$summary"
# Its process sat idle (a sleep): that is what makes it a hang at the stall limit.
grep -q 'the test processes sat idle' <<<"$stuck" || fail "the stuck error does not say the processes were idle" "$stuck"
# Cut short, the run still says what it got done: the finished tests by result, the failed one by
# name, the one never finished. Their result lines stay in the log for test_reds.py to compare.
cut=$(grep '^::error title=cmux-next swift test cut short::' <<<"$out" || true)
[[ -n "$cut" ]] || fail "a run the watchdog ended printed no cut-short line" "$out"
grep -q 'cut short by the stall rule' <<<"$cut" || fail "the cut-short line does not say the stall rule ended it" "$cut"
grep -q '2 tests finished (1 passed, 1 failed, 0 skipped) and 1 started and never finished' <<<"$cut" \
  || fail "the cut-short line miscounts the finished and open tests" "$cut"
grep -q 'Failed: eachFails(n:)\.' <<<"$cut" || fail "the cut-short line does not name the failed test" "$cut"
grep -q 'Never finished: stuckHere()' <<<"$cut" || fail "the cut-short line does not name the open test" "$cut"
grep -q 'never a base red' <<<"$cut" || fail "the cut-short line does not say it is never a base red" "$cut"
grep -q '^### Cut short by the stall rule: 2 tests finished' <<<"$summary" \
  || fail "the step summary has no cut-short line" "$summary"

# No test finishes for longer than the stall limit while the test process keeps using CPU: a
# starved runner, where one test takes minutes (cmux#28497 run 41123927916, a 6 vCPU Blacksmith
# Mac: tests under a second on an idle mini finished after 78-227 s, and the old rule cut the pass
# at 300 s with 223 tests open). Slow, not hung: no kill before the busy limit.
printf '%s\n' '◇ Test run started.' '◇ Test slowOnAStarvedRunner() started.' > "$TMP/busy.out"
printf '%s\n' '✔ Test slowOnAStarvedRunner() passed after 6.000 seconds.' \
  '✔ Test run with 1 test in 1 suite passed after 6.001 seconds.' > "$TMP/busy.after"
STUB_BUSY=6 STUB_AFTER="$TMP/busy.after" CMUX_NEXT_TEST_STUCK_SECONDS=2 CMUX_NEXT_TEST_BUSY_STUCK_SECONDS=40 \
  CMUX_NEXT_TEST_STUCK_POLL_SECONDS=1 run busy 0
[[ "$out" != *"swift test stuck"* ]] || fail "the watchdog cut a slow run whose test process kept using CPU" "$out"
[[ "$status" == 0 ]] || fail "a slow run that kept using CPU and then finished exited $status" "$out"
grep -q 'a slow run, not a hang' <<<"$out" || fail "the watchdog did not say it waits on a busy run" "$out"
[[ "$out" != *"cut short"* ]] || fail "a whole run printed a cut-short line" "$out"

# Busy and silent past the busy limit (a spin, or a runner too starved to finish anything): ended
# then, saying the processes were busy, and naming the open test.
started=$SECONDS
STUB_BUSY=60 CMUX_NEXT_TEST_STUCK_SECONDS=2 CMUX_NEXT_TEST_BUSY_STUCK_SECONDS=6 CMUX_NEXT_TEST_STUCK_POLL_SECONDS=1 run busy 0
(( SECONDS - started < 40 )) || fail "a busy silent run was ended only after $((SECONDS - started)) s" "$out"
[[ "$status" != 0 ]] || fail "a busy silent run the watchdog ended exited 0" "$out"
stuck=$(grep '^::error title=cmux-next swift test stuck' <<<"$out" || true)
grep -q 'kept using CPU' <<<"$stuck" || fail "the busy stall does not say the processes kept using CPU" "$out"
grep -q 'CMUX_NEXT_TEST_BUSY_STUCK_SECONDS 6' <<<"$stuck" || fail "the busy stall does not name its limit" "$stuck"
grep -q 'slowOnAStarvedRunner()' <<<"$stuck" || fail "the busy stall does not name the open test" "$stuck"

# The watchdog reads finishes with the same definition report() does, so the two can never
# disagree about what "finished" means. They did: report() learned the known-issue marker and the
# watchdog did not, so a known-issue pass still looked like a test that had been running for the
# whole stuck limit. The cost is not a false red, it is a healthy run SAMPLED AND KILLED while its
# other tests were still going. Every terminal shape appears here, and only the genuinely stuck
# test may be named. A skip has no start: swift-testing skips a test instead of starting it.
cat > "$TMP/stuckshapes.out" <<'EOF2'
◇ Test knownIssuePass() started.
━ Test knownIssuePass() passed after 0.300 seconds with 2 known issues.
◇ Test knownIssueFail() started.
━ Test knownIssueFail() failed after 0.002 seconds with 1 known issue.
◇ Test xKnownIssue() started.
✘ Test xKnownIssue() passed after 0.001 seconds with 1 known issue.
◇ Test cancelledHere() started.
➜ Test cancelledHere() was cancelled after 0.001 seconds.
➜ Test skippedHere() skipped.
◇ Test eachPasses(n:) started.
✔ Test eachPasses(n:) with 2 test cases passed after 0.003 seconds.
◇ Test stuckHere() started.
EOF2
STUB_SLEEP=60 CMUX_NEXT_TEST_STUCK_SECONDS=2 CMUX_NEXT_TEST_STUCK_POLL_SECONDS=1 run stuckshapes 0
stuck=$(grep '^::error title=cmux-next swift test stuck' <<<"$out" || true)
[[ -n "$stuck" ]] || fail "no stuck-test ::error line" "$out"
grep -q '1 test open at least 2s' <<<"$stuck" \
  || fail "the watchdog read a finished test as still running" "$stuck"
grep -q 'stuckHere()' <<<"$stuck" || fail "the stuck error does not name stuckHere()" "$stuck"
for finished in knownIssuePass knownIssueFail xKnownIssue cancelledHere skippedHere eachPasses; do
  if grep -q "$finished" <<<"$stuck"; then
    fail "the watchdog named $finished(), which had finished" "$stuck"
  fi
done

# A cancelled test is a FINISHED test. swift-testing 6.3 ends a non-failing cancellation
# (try Test.cancel()) with "was cancelled after ...", a tail name_of() did not strip, so the
# finish was filed under "f() was cancelled after 0.001 seconds" while the start was filed under
# "f()" -- a green run reported as truncated, forever, with no way for the test to pass.
cat > "$TMP/cancelled.out" <<'EOF'
◇ Test cancelledHere() started.
➜ Test cancelledHere() was cancelled after 0.001 seconds.
◇ Test aPasses() started.
✔ Test aPasses() passed after 0.001 seconds.
✔ Test run with 2 tests in 1 suite passed after 0.002 seconds.
EOF
run cancelled 0
[[ "$status" == 0 ]] || fail "a run with a cancelled test exited $status" "$out"
[[ "$out" != *"::error"* ]] || fail "a run with a cancelled test printed an error" "$out"

# One log can hold the same test name twice: the isolated-suite step runs each suite in its own
# process and appends to one log. While the gate kept a SET of names, the first run finishing
# covered the second run starting, so a truncation that only lost tests an earlier block had
# already run and summarized left every count intact and read as a pass -- the one failure this
# gate exists to prevent, reachable by the shape the step itself produces.
cat > "$TMP/duplicatenames.out" <<'EOF'
◇ Test duplicate() started.
✔ Test duplicate() passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.002 seconds.
◇ Test duplicate() started.
◇ Test other() started.
✔ Test other() passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.002 seconds.
EOF
run duplicatenames 0
[[ "$status" != 0 ]] || fail "a second run of duplicate() that never finished exited 0" "$out"
# The error line only: $out also holds the teed test log, where duplicate() appears either way.
err=$(grep '^::error' <<<"$out")
grep -q 'duplicate()' <<<"$err" || fail "the error does not name duplicate()" "$err"
grep -q 'never finished' <<<"$err" || fail "the error does not say a test never finished" "$err"
! grep -q 'other()' <<<"$err" || fail "the error named other(), which finished" "$err"

# The other side of counting runs: the same name run twice, both finishing, is whole. A gate that
# subtracted totals instead of counting per name would fail this.
cat > "$TMP/duplicategreen.out" <<'EOF'
◇ Test duplicate() started.
✔ Test duplicate() passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.002 seconds.
◇ Test duplicate() started.
✔ Test duplicate() passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.002 seconds.
EOF
run duplicategreen 0
[[ "$status" == 0 ]] || fail "the same test run twice, both finishing, exited $status" "$out"
[[ "$out" != *"::error"* ]] || fail "the same test run twice, both finishing, printed an error" "$out"

# A parameterized test prints a finish per case whose start line the gate deliberately skips, so
# finishes outnumber starts across the whole log. Counting per name keeps those case finishes
# under a name that never started, where they cannot cover a real unfinished test.
cat > "$TMP/parameterized.out" <<'EOF'
◇ Test paramTest(value:) started.
◇ Test case passing 1 argument value → 1 to paramTest(value:) started.
✔ Test case passing 1 argument value → 1 to paramTest(value:) passed after 0.001 seconds.
◇ Test case passing 1 argument value → 2 to paramTest(value:) started.
✔ Test case passing 1 argument value → 2 to paramTest(value:) passed after 0.001 seconds.
✔ Test paramTest(value:) passed after 0.003 seconds.
◇ Test lostAfterTheCases() started.
✔ Test run with 2 tests in 1 suite passed after 0.004 seconds.
EOF
run parameterized 0
[[ "$status" != 0 ]] || fail "a test lost after a parameterized test's cases exited 0" "$out"
# The error line only: $out also holds the teed test log, where every one of these names appears.
err=$(grep '^::error' <<<"$out")
grep -q 'lostAfterTheCases()' <<<"$err" \
  || fail "the error does not name lostAfterTheCases()" "$err"
! grep -q 'paramTest' <<<"$err" \
  || fail "the error named paramTest, whose cases all finished" "$err"

# The watchdog times each RUN, not each name. A name whose first run finished never leaves the open
# list once a second run starts, so while the open-list key was the bare name, run 2 inherited the
# timestamp of the poll that first saw run 1 and was killed for an age it never reached: run 1 seen
# at t=10, finishes at t=180, run 2 starts at t=181, and at t=310 the watchdog reports 300 s and
# samples a run that is 129 s old. Keying per run also means the error names which run was lost.
cat > "$TMP/duprun.out" <<'EOF'
◇ Test duplicate() started.
✔ Test duplicate() passed after 0.001 seconds.
◇ Test duplicate() started.
EOF
run duprun 0
err=$(grep '^::error' <<<"$out")
grep -q 'duplicate() (run 2)' <<<"$err" \
  || fail "the error does not name the second run of duplicate()" "$err"

# A test skipped before it ran prints "➜ ... skipped." with NO start line, so that finish has no
# run to close. Banked as a finish it would close a LATER, real run of the same name: here the
# skipped duplicate() would have covered the unfinished one, leaving 2 starts against a 2-test
# summary with nothing reported as open. A finish with no open start is ignored instead.
cat > "$TMP/skipthenlost.out" <<'EOF'
➜ Test duplicate() skipped: "not on this platform"
◇ Test other() started.
✔ Test other() passed after 0.001 seconds.
◇ Test duplicate() started.
✔ Test run with 2 tests in 1 suite passed after 0.002 seconds.
EOF
run skipthenlost 0
[[ "$status" != 0 ]] || fail "a skip covered a later unfinished run of the same test" "$out"
err=$(grep '^::error' <<<"$out")
grep -q 'duplicate()' <<<"$err" || fail "the error does not name duplicate()" "$err"
! grep -q 'other()' <<<"$err" || fail "the error named other(), which finished" "$err"

# A run key must not be able to collide with a test's own name, because the watchdog remembers
# when it first saw each KEY and will kill a run it believes is older than it is. A display name is
# whatever the author wrote, and name_of truncates at " skipped", so these two legal labels
#   A: "duplicate skipped on unsupported platform"   -> duplicate
#   B: "duplicate (run 2) skipped on unsupported platform" -> duplicate (run 2)
# gave A's run 2 and B's run 1 the same readable key `duplicate (run 2)`. Measured on the real
# parser and the real timer program: A run 2 seen at t=10, B starting after A finished, and at
# t=310 the watchdog reported B as 300 s old when it was 129 s old -- a healthy run sampled and
# killed. The run number now joins with a byte no name can contain.
#
# The key is internal, so this reads it out of the script the same way the script builds it: if the
# shared awk is ever restructured, the extraction yields nothing and this fails loudly rather than
# passing on an empty string.
vars_end=$(grep -n '^open_tests() {' "$ROOT/scripts/cmux-next/swift-test-with-hang-sampler.sh" | cut -d: -f1)
vars_start=$(grep -n '^names_awk=' "$ROOT/scripts/cmux-next/swift-test-with-hang-sampler.sh" | cut -d: -f1)
[[ -n "$vars_start" && -n "$vars_end" ]] || fail "cannot find the shared awk in the sampler"
sed -n "${vars_start},$((vars_end - 1))p" "$ROOT/scripts/cmux-next/swift-test-with-hang-sampler.sh" \
  > "$TMP/shared-awk.sh"
# shellcheck disable=SC1091 # written just above
. "$TMP/shared-awk.sh"
[[ -n "${names_awk:-}" && -n "${count_awk:-}" ]] || fail "the sampler no longer defines names_awk and count_awk"
cat > "$TMP/collide.log" <<'EOF'
◇ Test duplicate skipped on unsupported platform started.
✔ Test duplicate skipped on unsupported platform passed after 0.001 seconds.
◇ Test duplicate skipped on unsupported platform started.
◇ Test duplicate (run 2) skipped on unsupported platform started.
EOF
keys=$(awk "$names_awk$count_awk"'
  END { for (i = 1; i <= name_count; i++)
          for (k = first_open_run(names[i]); k <= started[names[i]]; k++) print run_key(names[i], k) }
' "$TMP/collide.log")
[[ "$(wc -l <<<"$keys" | tr -d " ")" == 2 ]] || fail "expected two open runs, got: $(cat -v <<<"$keys")"
[[ "$(sort -u <<<"$keys" | wc -l | tr -d " ")" == 2 ]] \
  || fail "two different open runs share one watchdog key: $(cat -v <<<"$keys")"
# And the keys still read as words for a person.
labels=$(awk "$names_awk"'{ print run_label($0) }' <<<"$keys")
grep -qx 'duplicate (run 2)' <<<"$labels" || fail "a run key does not read back as its name" "$labels"

# Adversarially, on the key function itself: a display name is any String, so no suffix form is
# safe. Readable text collided with a test named `A (run 2)`; the separator as a SUFFIX still
# collided with a name containing the separator byte. As a prefix, everything up to the first
# separator is digits run_key wrote, so these pairs must all differ, and each must read back as
# its own name.
probe=$(awk "$names_awk"'
  BEGIN {
    sep = run_sep()
    n = 0
    names[++n] = "A"; runs[n] = 2
    names[++n] = "A" sep "2"; runs[n] = 1          # a name that literally holds the separator
    names[++n] = "A (run 2)"; runs[n] = 1          # a name that reads like a key
    names[++n] = "A	B"; runs[n] = 1               # a name holding the seen file separator
    names[++n] = ""; runs[n] = 1                   # the empty name
    for (i = 1; i <= n; i++) {
      key = run_key(names[i], runs[i])
      printf "%s\n", key
      if (run_label(key) != (runs[i] > 1 ? names[i] " (run " runs[i] ")" : names[i]))
        printf "MANGLED: <%s> run %d read back as <%s>\n", names[i], runs[i], run_label(key)
    }
  }' </dev/null)
! grep -q MANGLED <<<"$probe" || fail "a run key does not read back as its own name" "$(cat -v <<<"$probe")"
[[ "$(wc -l <<<"$probe" | tr -d " ")" == "$(sort -u <<<"$probe" | wc -l | tr -d " ")" ]] \
  || fail "two different runs share one key: $(cat -v <<<"$probe")"

# Each test process is held to its own summary. One log holds a run per process, and the totals
# alone let a later process that was cut off after its own starts had all finished hide behind an
# earlier summary that ran ahead of its starts (skipped tests print no start): 2 starts against a
# 3-test summary, nothing open, and the second run never summarized.
cat > "$TMP/blocklost.out" <<'EOF'
◇ Test run started.
◇ Test first() started.
✔ Test first() passed after 0.001 seconds.
➜ Test skippedOne() skipped: "not here"
➜ Test skippedTwo() skipped: "not here"
✔ Test run with 3 tests in 1 suite passed after 0.002 seconds.
◇ Test run started.
◇ Test second() started.
✔ Test second() passed after 0.001 seconds.
EOF
run blocklost 0
[[ "$status" != 0 ]] || fail "a second test run with no summary exited 0" "$out"
err=$(grep '^::error' <<<"$out")
grep -q 'test run 2 of 2 printed no summary after 1 starts' <<<"$err" \
  || fail "the error does not name the run that printed no summary" "$err"
grep -q 'test run 2 of 2' <<<"$summary" || fail "the step summary does not name the unsummarized run" "$summary"

# And a run that summarized fewer tests than it started, behind a total that still adds up.
cat > "$TMP/blockunder.out" <<'EOF'
◇ Test run started.
◇ Test a() started.
✔ Test a() passed after 0.001 seconds.
➜ Test s1() skipped: "not here"
➜ Test s2() skipped: "not here"
✔ Test run with 3 tests in 1 suite passed after 0.002 seconds.
◇ Test run started.
◇ Test b() started.
✔ Test b() passed after 0.001 seconds.
◇ Test c() started.
✔ Test c() passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.002 seconds.
EOF
run blockunder 0
[[ "$status" != 0 ]] || fail "a test run that reported fewer tests than it started exited 0" "$out"
grep '^::error' <<<"$out" | grep -q 'test run 2 of 2 reported 1 tests after 2 starts' \
  || fail "the error does not name the run that undercounted" "$out"

# The healthy shape of the same log: every run summarized, each at least its own starts.
cat > "$TMP/blockgreen.out" <<'EOF'
◇ Test run started.
◇ Test a() started.
✔ Test a() passed after 0.001 seconds.
➜ Test s1() skipped: "not here"
✔ Test run with 2 tests in 1 suite passed after 0.002 seconds.
◇ Test run started.
◇ Test a() started.
✔ Test a() passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.002 seconds.
EOF
run blockgreen 0
[[ "$status" == 0 ]] || fail "two whole test runs in one log exited $status" "$out"
[[ "$out" != *"::error"* ]] || fail "two whole test runs in one log printed an error" "$out"

# Starts and finishes match within one test process. A finish in a later process must not close
# a start an earlier process lost: here process 2 skips duplicate(), and while matching was global
# that skip closed process 1's unfinished start, both summaries covered their own starts, nothing
# read as open, and the run passed.
cat > "$TMP/blockcross.out" <<'EOF'
◇ Test run started.
◇ Test duplicate() started.
✔ Test run with 1 test in 1 suite passed after 0.002 seconds.
◇ Test run started.
➜ Test duplicate() skipped: "not here"
✔ Test run with 1 test in 1 suite passed after 0.002 seconds.
EOF
run blockcross 0
[[ "$status" != 0 ]] || fail "a finish in a later test run closed a start an earlier run lost" "$out"
err=$(grep '^::error' <<<"$out")
grep -q 'duplicate()' <<<"$err" || fail "the error does not name duplicate()" "$err"
# The block prefix is internal: a person reads the bare name.
! grep -q $'\x02' <<<"$err" || fail "the error shows the internal block separator" "$(cat -v <<<"$err")"

# Within one process too: two suites can hold the same bare test name, and a skip is never the end
# of a start (swift-testing skips a test instead of starting it). Suite A's duplicate() is lost,
# suite B's duplicate() is skipped: that skip must not close A's start.
cat > "$TMP/suiteskip.out" <<'EOF'
◇ Test run started.
◇ Suite A started.
◇ Test duplicate() started.
➜ Test duplicate() skipped: "not here"
✔ Test run with 1 test in 2 suites passed after 0.002 seconds.
EOF
run suiteskip 0
[[ "$status" != 0 ]] || fail "a skip in another suite closed a lost start of the same name" "$out"
grep '^::error' <<<"$out" | grep -q 'duplicate()' || fail "the error does not name duplicate()" "$out"

# Only the generated parameterized-case shape is skipped as a start. A test whose display name
# merely begins "case passing" is a test: lost, it must fail the run, not vanish from the count.
cat > "$TMP/casename.out" <<'EOF'
◇ Test run started.
◇ Test case passing the buck() started.
✔ Test run with 1 test in 1 suite passed after 0.002 seconds.
EOF
run casename 0
[[ "$status" != 0 ]] || fail "a lost test named \"case passing ...\" exited 0" "$out"
grep '^::error' <<<"$out" | grep -q 'case passing the buck()' \
  || fail "the error does not name the lost \"case passing\" test" "$out"

# A helper that hangs with no test open (before the first starts, or after the last finishes and
# its summary is out) has nothing for the per-test ages to name; silence for the whole stall limit
# still ends it.
cat > "$TMP/silent.out" <<'EOF'
◇ Test run started.
◇ Test a() started.
✔ Test a() passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.002 seconds.
EOF
started=$SECONDS
STUB_SLEEP=60 CMUX_NEXT_TEST_STUCK_SECONDS=2 CMUX_NEXT_TEST_STUCK_POLL_SECONDS=1 run silent 0
(( SECONDS - started < 30 )) || fail "a silent helper with no test open was ended only after $((SECONDS - started)) s" "$out"
[[ "$status" != 0 ]] || fail "a silent hung helper exited 0" "$out"
grep '^::error title=cmux-next swift test stuck' <<<"$out" | grep -q 'no test open' \
  || fail "the stuck error does not say no test was open" "$out"

# Before any test run has started, silence is not a hang: output has lagged minutes behind a
# healthy pass. The whole-run limit guards that stretch, not the stall rule.
: > "$TMP/quiet.out"
STUB_SLEEP=5 CMUX_NEXT_TEST_STUCK_SECONDS=2 CMUX_NEXT_TEST_STUCK_POLL_SECONDS=1 run quiet 0
[[ "$out" != *"swift test stuck"* ]] || fail "the stall rule killed a pass before any test run started" "$out"

# An open test is not a RUNNING test, so age alone must never end a run. swift-testing prints
# every test "started." as it enters the run while the parallelization width lets only a few
# execute, so on the real suite thousands of tests sit open, and waiting, far past this limit:
# measured 3927 open past 300 s on a healthy step of cmux#25391 run 40313902783, which the
# watchdog killed at exit 143 with nothing wrong (3925 on the merge-base parser, so the premise
# was wrong, not the accounting). What a stuck run stops doing is FINISHING tests, so that is the
# signal. Here one test stays open for the whole run while others keep finishing: no kill.
cat > "$TMP/progress.out" <<'EOF'
◇ Test openTheWholeTime() started.
EOF
STUB_DRIP=6 STUB_DRIP_SECONDS=1 CMUX_NEXT_TEST_STUCK_SECONDS=2 CMUX_NEXT_TEST_STUCK_POLL_SECONDS=1   run progress 0
[[ "$out" != *"swift test stuck"* ]]   || fail "the watchdog killed a run that was still finishing tests" "$out"
[[ "$out" != *"=== sample"* ]] || fail "the watchdog sampled a run making progress" "$out"

# A test prints bytes that are not UTF-8 (a string cut mid-character: the first two bytes of "→").
# CI runs in a UTF-8 locale, where macOS awk died on that line on every read ("towc: multibyte
# conversion failure") and sed with it ("illegal byte sequence"): the report named nothing and the
# stall watchdog never fired (cmux#25978 job 123476714112). Both still work on such a log.
bad=$'\xe2\x86'
utf8=$(locale -a 2>/dev/null | grep -iE '^(en_US|C)\.utf-?8$' | head -n 1 || true)
utf8=${utf8:-en_US.UTF-8}
printf '%s\n' \
  '◇ Test run started.' \
  '◇ Test printsHalfACharacter() started.' \
  "cut here: $bad" \
  '✔ Test printsHalfACharacter() passed after 0.001 seconds.' \
  '◇ Test hangsAfterTheBadByte() started.' \
  > "$TMP/badbyte.out"
LC_ALL=$utf8 run badbyte 143
[[ "$out" != *"towc"* && "$out" != *"illegal byte"* ]] || fail "a log reader died on a non-UTF-8 byte" "$out"
grep '^::error title=cmux-next swift test incomplete' <<<"$out" | grep -q 'hangsAfterTheBadByte()' \
  || fail "the report of a log with a non-UTF-8 byte does not name the unfinished test" "$out"
if grep '^::error' <<<"$out" | grep -q 'printsHalfACharacter'; then fail "the report names the finished test" "$out"; fi
[[ "$status" == 143 ]] || fail "the run with a non-UTF-8 byte exited $status, not 143" "$out"

started=$SECONDS
LC_ALL=$utf8 STUB_SLEEP=60 CMUX_NEXT_TEST_STUCK_SECONDS=2 CMUX_NEXT_TEST_STUCK_POLL_SECONDS=1 run badbyte 0
(( SECONDS - started < 30 )) || fail "the watchdog took $((SECONDS - started)) s on a log with a non-UTF-8 byte" "$out"
[[ "$out" != *"towc"* && "$out" != *"illegal byte"* ]] || fail "the watchdog died on a non-UTF-8 byte" "$out"
grep '^::error title=cmux-next swift test stuck' <<<"$out" | grep -q 'hangsAfterTheBadByte()' \
  || fail "the watchdog does not name the stuck test after a non-UTF-8 byte" "$out"

# The watcher's annotations start their own line even when the test output stops mid-line, or the
# log viewer reads one as the end of a test line (cmux#24073 job 123468767603). The hang annotation
# takes the same printf; the stall one is the one a test can reach in seconds.
printf '%s\n%s' '◇ Test run started.' '◇ Test case passing 1 argument x → 1 to f(x:) start' > "$TMP/midline.out"
STUB_SLEEP=60 CMUX_NEXT_TEST_STUCK_SECONDS=2 CMUX_NEXT_TEST_STUCK_POLL_SECONDS=1 run midline 0
grep -q '^::error title=cmux-next swift test stuck::' <<<"$out" \
  || fail "the watchdog annotation does not start its own line" "$out"

echo "ok swift-test-summary"
