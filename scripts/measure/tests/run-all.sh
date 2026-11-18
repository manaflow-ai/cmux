#!/usr/bin/env bash
# Runs every scripts/measure/tests/*.test.sh and *.test.py, so a new measure test runs in CI without its own guards
# step: only 4 of 45 had one, and the rest went unrun (2026-11-18). A test that cannot pass on a CI runner, or fails
# on base, is listed in SKIP with its reason; the runner names each one it skips. Prints PASS or FAIL per test with a
# failing test's tail, and exits 1 if any failed.
# Each test is cut at MEASURE_TEST_TIMEOUT seconds (600) with whatever the host has: `timeout`, else `gtimeout`, else
# a perl watchdog that ends the test's process group. No Mac has GNU timeout, and its absence failed all 23 tests
# with exit 127 (2026-11-18). With no way to bound a test, it says so once and exits 2 without running any.
set -uo pipefail
shopt -s nullglob

tests="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$tests/../../.." || exit 2

bound="${MEASURE_TEST_TIMEOUT:-600}"
TIMED_OUT=124  # GNU timeout's exit for a cut command; the watchdog uses the same

# bounded CMD...: CMD, ended at $bound seconds; exits CMD's own status, or TIMED_OUT when it was cut.
if command -v timeout >/dev/null 2>&1; then
  bounded() { timeout "$bound" "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then
  bounded() { gtimeout "$bound" "$@"; }
elif command -v perl >/dev/null 2>&1; then
  bounded() {
    perl -e '
      my $bound = shift;
      my $pid = fork() // exit 127;
      if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127; }
      local $SIG{ALRM} = sub { kill "TERM", -$pid; sleep 2; kill "KILL", -$pid; waitpid($pid, 0); exit 124; };
      alarm $bound;
      waitpid($pid, 0);
      exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
    ' "$bound" "$@"
  }
else
  echo "run-all.sh: cannot bound a test to ${bound} s: this host has no timeout, gtimeout or perl; no test was run" >&2
  exit 2
fi

declare -A SKIP=(
  [screen-stream-eval-prebuilt.test.sh]="opens Screen Sharing.app: runs only on a viewer Mac"
)

failed=0
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
for t in "$tests"/*.test.sh "$tests"/*.test.py; do
  name="${t##*/}"
  if [[ -n "${SKIP[$name]:-}" ]]; then
    echo "SKIP $name: ${SKIP[$name]}"
    continue
  fi
  case "$name" in
    *.sh) bounded bash "$t" </dev/null >"$log" 2>&1 ;;
    *.py) bounded python3 "$t" </dev/null >"$log" 2>&1 ;;
  esac
  rc=$?
  if [[ "$rc" == 0 ]]; then
    echo "PASS $name"
  elif [[ "$rc" == "$TIMED_OUT" ]]; then
    echo "FAIL $name (timed out after ${bound} s):"
    tail -n 20 "$log" | sed 's/^/  /'
    failed=1
  else
    echo "FAIL $name (exit $rc):"
    tail -n 20 "$log" | sed 's/^/  /'
    failed=1
  fi
done
exit "$failed"
