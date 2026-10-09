#!/usr/bin/env bash
# SWIFT-TEST-SUMMARY: swift-test-with-hang-sampler.sh names every red Swift
# Testing test in one ::error line and in the step summary, so a red stays
# visible when a log viewer truncates the step's output. If the run ends
# without the "Test run with" summary line, it fails and names the tests that
# started and never finished (a crashed or killed test process).
# No Swift: a stub `swift` prints canned Swift Testing output.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf '%s\n' "$@" >&2; exit 1; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/swift" <<'EOF'
#!/usr/bin/env bash
cat "$STUB_OUTPUT"
exit "${STUB_STATUS:-0}"
EOF
chmod +x "$TMP/bin/swift"

# run <name> <status>: runs the wrapper on $TMP/<name>.out; sets out, summary, status.
run() {
  export STUB_OUTPUT="$TMP/$1.out" STUB_STATUS="$2" GITHUB_STEP_SUMMARY="$TMP/$1.summary"
  : > "$GITHUB_STEP_SUMMARY"
  status=0
  out=$(PATH="$TMP/bin:$PATH" CMUX_NEXT_TEST_HANG_SECONDS=60 \
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

# No summary line although swift exited 0: the run fails and names the tests
# that started and never finished, and not the finished ones.
cat > "$TMP/cut.out" <<'EOF'
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
run trap 1
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

echo "ok swift-test-summary"
