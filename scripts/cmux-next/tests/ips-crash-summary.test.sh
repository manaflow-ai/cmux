#!/usr/bin/env bash
# IPS-CRASH-SUMMARY: ips-crash-summary.py names the crashed thread of a test
# helper's crash report, and says where it looked when it finds none.
#
# Both things matter for the same reason. A test helper on a CI Mac leaves its
# report in the SYSTEM /Library/Logs/DiagnosticReports, not the $HOME one a
# login session gets, so a lookup in $HOME alone found nothing for a run that
# had plainly died on signal 6, and printed nothing -- which the caller renders
# as "no crash report from this run". That reads as "the process left no
# report" when the truth was "this searched the wrong directory", and the
# difference is what made that crash undiagnosable (cmux#25391, run
# 40330489336). So it now takes a colon-separated list of directories, and
# silence is never an answer.
#
# No real crash: synthetic .ips files.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT="$ROOT/scripts/cmux-next/ips-crash-summary.py"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf '%s\n' "$@" >&2; exit 1; }

# report DIR NAME SYMBOL [PID PARENT]: a crash report whose crashed thread
# tops out at SYMBOL, written by process PID (default 4242) whose parent is
# PARENT (default 4241).
report() {
  mkdir -p "$1"
  {
    printf '{"app_name":"swiftpm-testing-helper","timestamp":"2026-10-26 13:50:22.00 +0000"}\n'
    printf '{"pid":%s,"parentPid":%s,' "${4:-4242}" "${5:-4241}"
    printf '"exception":{"type":"EXC_CRASH","signal":"SIGABRT"},'
    printf '"threads":[{"triggered":true,"frames":[{"symbol":"%s"},{"symbol":"HoverCardPanel.deinit"}]}],' "$3"
    printf '"usedImages":[{"name":"CmuxNextPackageTests"}]}\n'
  } > "$1/$2"
}

since=$(python3 -c 'import time; print(time.time() - 60)')
system="$TMP/system"
home="$TMP/home"
out="$TMP/out"

# 1. A report in the SECOND directory is found. This is the bug itself: the
#    system directory is the one a CI helper writes to, and a single-directory
#    lookup missed it entirely.
mkdir -p "$home"
report "$system" "swiftpm-testing-helper-2026-10-26-135022.ips" "swift_abortRetainUnowned"
got=$(python3 -I "$SCRIPT" "$home:$system" "$out" "$since" 0)
[[ "$got" == *swift_abortRetainUnowned* ]] \
  || fail "a report in the second directory was not found" "got: $got"
[[ "$got" == *"EXC_CRASH SIGABRT"* ]] || fail "the exception was not named" "got: $got"
[[ -s "$out/swiftpm-testing-helper-2026-10-26-135022.ips" ]] \
  || fail "the report was not copied to the out directory for upload"

# 2. Nothing matching: it says what it looked at, naming every directory. Never
#    silence, which the caller cannot tell apart from a process that left no
#    report at all.
empty_a="$TMP/empty-a"; empty_b="$TMP/empty-b"
mkdir -p "$empty_a" "$empty_b"
got=$(python3 -I "$SCRIPT" "$empty_a:$empty_b" "$out" "$since" 0)
[[ -n "$got" ]] || fail "printed nothing when no report matched"
[[ "$got" == *"$empty_a"* && "$got" == *"$empty_b"* ]] \
  || fail "did not name both searched directories" "got: $got"

# 3. A report older than this run is passed over, and counted as such rather
#    than reported as this run's crash.
stale="$TMP/stale"
report "$stale" "swiftpm-testing-helper-2026-10-01-000000.ips" "somethingElse"
touch -t 202601010000 "$stale/swiftpm-testing-helper-2026-10-01-000000.ips"
got=$(python3 -I "$SCRIPT" "$stale" "$out" "$since" 0)
[[ "$got" != *somethingElse* ]] || fail "reported a crash report older than the run" "got: $got"
[[ "$got" == *"1 older than this run"* ]] || fail "did not count the stale report" "got: $got"

# 4. Another process's report in the same directory is passed over and counted,
#    so a busy CI mini's unrelated crashes never read as this run's.
other="$TMP/other"
report "$other" "Finder-2026-10-26-135022.ips" "notOurs"
got=$(python3 -I "$SCRIPT" "$other" "$out" "$since" 0)
[[ "$got" != *notOurs* ]] || fail "reported another process's crash report" "got: $got"
[[ "$got" == *"1 another process"* ]] || fail "did not count the other process's report" "got: $got"

# 5. A directory that does not exist is named as unreadable, not a traceback:
#    the summary runs after a crash and must never replace the crash with its
#    own failure.
got=$(python3 -I "$SCRIPT" "$TMP/missing" "$out" "$since" 0)
[[ "$got" == *"$TMP/missing"* ]] || fail "did not name the missing directory" "got: $got"
[[ "$got" == *unreadable* ]] || fail "did not say the missing directory was unreadable" "got: $got"
python3 -I "$SCRIPT" "$TMP/missing" "$out" "$since" 0 >/dev/null \
  || fail "a missing directory failed the caller"

# 6. The harness passes both directories by default, system first. A default
#    that names only one is the bug in 1 restored.
grep -q 'CMUX_NEXT_CRASH_REPORTS_DIR:-/Library/Logs/DiagnosticReports:\$HOME/Library/Logs/DiagnosticReports' \
  "$ROOT/scripts/cmux-next/swift-test-with-hang-sampler.sh" \
  || fail "swift-test-with-hang-sampler.sh does not default to both report directories"

# 7. A crash report may never arrive at all, so the crash also names itself in
#    the log: the harness turns Swift's backtracer on, symbolicated, before it
#    starts the run. `enable=tty` is the default and is off under Actions, which
#    is why a signal 6 left only its one-line message and nothing to attribute.
#    Checked by running the harness's own export line, so a typo in the setting
#    fails here rather than on the next crash.
setting=$(
  eval "$(grep -m1 '^export SWIFT_BACKTRACE=' "$ROOT/scripts/cmux-next/swift-test-with-hang-sampler.sh")"
  printf '%s' "$SWIFT_BACKTRACE"
)
case "$setting" in
  *enable=yes*) ;;
  *) fail "the harness does not enable the Swift backtracer: $setting" ;;
esac
case "$setting" in
  *symbolicate=full*) ;;
  *) fail "the backtrace would have no symbols, which answers nothing: $setting" ;;
esac
case "$setting" in
  *interactive=no*) ;;
  *) fail "the backtracer could wait for a keypress that cannot come: $setting" ;;
esac
# And it yields to an explicit setting, so a job that needs its own can say so.
chosen=$(
  export SWIFT_BACKTRACE="enable=no"
  eval "$(grep -m1 '^export SWIFT_BACKTRACE=' "$ROOT/scripts/cmux-next/swift-test-with-hang-sampler.sh")"
  printf '%s' "$SWIFT_BACKTRACE"
)
[[ "$chosen" == "enable=no" ]] || fail "the harness overrode an explicit SWIFT_BACKTRACE: $chosen"

# 8. Another job's helper, same name and the same minutes, in the FIRST
#    directory, and this run's in the second: only this run's is named or
#    copied. A shared CI mini runs other jobs' swiftpm-testing-helper as the same
#    user, and a name and a time matched theirs as ours. This run's helper is
#    known by its parent, the `swift test` pid the harness passes.
foreign="$TMP/foreign-system"; ours="$TMP/ours-home"; out8="$TMP/out8"
report "$foreign" "swiftpm-testing-helper-2026-10-26-135020.ips" "anotherJobsCrash" 5001 5000
report "$ours" "swiftpm-testing-helper-2026-10-26-135022.ips" "thisRunsCrash" 7001 7000
got=$(python3 -I "$SCRIPT" "$foreign:$ours" "$out8" "$since" 0 "7000")
[[ "$got" == *thisRunsCrash* ]] || fail "this run's report was not found" "got: $got"
[[ "$got" != *anotherJobsCrash* ]] || fail "named another job's crash report as this run's" "got: $got"
[[ ! -e "$out8/swiftpm-testing-helper-2026-10-26-135020.ips" ]] \
  || fail "copied another job's crash report up with this run's"
# Known by its own pid too (a helper the watcher saw), not only by its parent.
got=$(python3 -I "$SCRIPT" "$foreign:$ours" "$out8" "$since" 0 "1,7001")
[[ "$got" == *thisRunsCrash* && "$got" != *anotherJobsCrash* ]] \
  || fail "did not tell this run's helper by its own pid" "got: $got"
# Only the foreign one: counted as another process, never reported.
got=$(python3 -I "$SCRIPT" "$foreign" "$out8" "$since" 0 "7000")
[[ "$got" != *anotherJobsCrash* ]] || fail "reported another job's crash report" "got: $got"
[[ "$got" == *"1 another process"* ]] || fail "did not count another job's report" "got: $got"
# And the harness passes the run's pids, or none of this applies.
grep -q '"\$started_at" "\${CMUX_NEXT_CRASH_WAIT_SECONDS:-20}" "\$run_pids"' \
  "$ROOT/scripts/cmux-next/swift-test-with-hang-sampler.sh" \
  || fail "swift-test-with-hang-sampler.sh does not pass the run's pids"

echo "ips-crash-summary.test.sh: ok"
