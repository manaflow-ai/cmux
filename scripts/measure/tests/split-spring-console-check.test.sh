#!/bin/bash
# split-spring.sh makes the launcher's console check before the build, not only before the launch: on a Mac where
# the check fails, a suite that needs a window ends in the step's first second and not after its build.
# Runs split-spring's console_check with a python3 of the test: the check is called one time for a suite that needs
# a window and its status is the function's, with the report's path as the check's argument; --build-only and the 3 suites that the Python side lets through make no
# call. The call's line is above the build's first line. No build, no app, no Python.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
script="$root/scripts/measure/split-spring.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/split-spring-console-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT
sed -n '/^# >>> console-check/,/^# <<< console-check/p' "$script" > "$work/check.sh"
grep -q '^console_check()' "$work/check.sh" || { echo "FAIL: split-spring.sh has no console-check block"; exit 1; }
call="$(grep -n '^console_check "\$build_only"' "$script" | cut -d: -f1 || true)"
build="$(grep -n '^build_start=' "$script" | cut -d: -f1 || true)"
[[ -n "$call" && -n "$build" && "$call" -lt "$build" ]] || { echo "FAIL: the check is not called before the build (lines '$call', '$build')"; exit 1; }

# checked STATUS BUILD_ONLY [ARG...]: the check with the report path of the test; prints the function's status and the count of its python3 calls.
checked() {
  local status="$1"
  shift
  (
    calls=0
    # shellcheck disable=SC2329 # console_check calls it
    python3() { calls=$((calls + 1)); printf '%s\n' "$*" > "$work/argv"; return "$status"; }
    # shellcheck disable=SC1091
    source "$work/check.sh"
    rc=0
    build_only="$1"
    shift
    console_check "$build_only" "$work/report.json" "$@" || rc=$?
    echo "$rc $calls"
  )
}
want() {  # want EXPECTED WHAT STATUS BUILD_ONLY [ARG...]
  local expected="$1" what="$2" got
  shift 2
  got="$(checked "$@")"
  [[ "$got" == "$expected" ]] || { echo "FAIL: $what: status and calls '$got', not '$expected'"; exit 1; }
}
want "0 1" "a window suite on a Mac with the console" 0 0 --suite=pane-perf --actions=close,zoom
want "1 1" "a window suite on a Mac with no console" 1 0 --suite=pane-perf --actions=close,zoom
grep -q 'require_gui_session("split-spring", argv=\["--json", sys.argv\[1\]\])' "$work/argv" && grep -q "$work/report.json\$" "$work/argv" || { echo "FAIL: the call is not the launcher's check: $(cat "$work/argv")"; exit 1; }
want "1 1" "no suite named (the default suite has a window)" 1 0
want "0 0" "--build-only" 1 1 --suite=pane-perf
for suite in launch-check pane-bench action-budget-bench; do
  want "0 0" "--suite=$suite" 1 0 "--suite=$suite" --rounds=3
done
echo "PASS: split-spring.sh checks the console before the build"
