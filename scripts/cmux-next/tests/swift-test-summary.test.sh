#!/usr/bin/env bash
# SWIFT-TEST-SUMMARY: swift-test-with-hang-sampler.sh names every red Swift
# Testing test in one ::error line and in the step summary, so a red stays
# visible when a log viewer truncates the step's output. If the run ends
# without the "Test run with" summary line, it fails and names the tests that
# started and never finished (a crashed or killed test process). A test still
# running after CMUX_NEXT_TEST_STUCK_SECONDS is named while the run is going.
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
