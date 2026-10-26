#!/usr/bin/env bash
# SWIFT-TEST-SUMMARY: swift-test-with-hang-sampler.sh names every red Swift
# Testing test in one ::error line and in the step summary, so a red stays
# visible when a log viewer truncates the step's output. If the run ends
# without the "Test run with" summary line, it fails and names the tests that
# started and never finished (a crashed or killed test process). A summary line
# is not proof the run was whole either: it counts the tests that reported, so
# a run that ends mid-flight still prints one. The job fails when the summaries
# count fewer tests than the log shows starting, or when any started test never
# finished. Names are counted across the whole log, so a truncation that only
# loses tests another target already ran and summarized still reads as a pass;
# that one needs per-summary-block bookkeeping and is not covered here. The
# reporter lines are read anchored, so a test cannot report itself finished.
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
# A test that never returns: the wrapper has to end it.
[[ -z "${STUB_SLEEP:-}" ]] || sleep "$STUB_SLEEP"
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
  '{"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"faultingThread":2,"usedImages":[{"name":"libswift_Concurrency.dylib"},{"name":"CmuxNextPackageTests"}],"threads":[{"frames":[{"imageIndex":1,"symbol":"idleThread"}]},{"frames":[]},{"triggered":true,"frames":[{"imageIndex":0,"symbol":"swift_task_checkIsolatedSwift"},{"imageIndex":1,"symbol":"KeyWindowObserver.windowWillClose(_:)"},{"imageIndex":1,"symbol":"closure #1 in BrowserPopupPanelThreadTests.anOpenerCloseNoticePostedOffMainClosesItsPopupsOnMain()"}]}]}' \
  > "$reports/swiftpm-testing-helper-2026-10-09-021500.ips"
# The run starts at a whole second after this write, so date the report ahead
# of it; otherwise a write at X.9 and a start at X+1 reads it as from before.
python3 -c 'import os,sys,time; t=time.time()+60; os.utime(sys.argv[1],(t,t))' "$reports/swiftpm-testing-helper-2026-10-09-021500.ips"
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
short_error=$(grep '^::error title=cmux-next swift test reported fewer' <<<"$out" || true)
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

# A ✘ finish is not only a failure: a test that passes with a known issue reports
# "✘ Test f() passed after ... with 1 known issue." and HAS finished. Reading it as
# unfinished would fail a whole run.
cat > "$TMP/knownissue.out" <<'EOF'
◇ Test knownIssue() started.
✘ Test knownIssue() passed after 0.001 seconds with 1 known issue.
◇ Test aPasses() started.
✔ Test aPasses() passed after 0.001 seconds.
✔ Test run with 2 tests in 1 suite passed after 0.002 seconds.
EOF
run knownissue 0
[[ "$status" == 0 ]] || fail "a test that passed with a known issue exited $status" "$out"
[[ "$out" != *"::error"* ]] || fail "a test that passed with a known issue printed an error" "$out"

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
grep -q '::1 test still running' <<<"$stuck" || fail "the stuck error miscounts" "$stuck"
grep -q 'stuckHere()' <<<"$summary" || fail "the step summary does not name the stuck test" "$summary"

echo "ok swift-test-summary"
