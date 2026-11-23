#!/usr/bin/env bash
# Runs every scripts/measure/tests/*.test.sh and *.test.py, so a new measure test runs in CI without its own guards
# step: only 4 of 45 had one, and the rest went unrun (2026-11-18). A test that cannot pass on a CI runner, or fails
# on base, is listed in SKIP with its reason; the runner names each one it skips. Prints PASS or FAIL per test with a
# failing test's tail, and exits 1 if any failed.
set -uo pipefail

tests="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$tests/../../.." || exit 2

declare -A SKIP=(
  [screen-stream-eval-prebuilt.test.sh]="opens Screen Sharing.app: runs only on a viewer Mac"
)

# tooling-tests can be placed on a Mac, which has no GNU timeout: every test then exited 127 with an empty log
# (2026-11-19, run 44532537118). Use gtimeout there, else Perl's alarm, which every macOS has.
bounded() {
  if command -v timeout >/dev/null 2>&1; then timeout 600 "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout 600 "$@"
  else perl -e 'alarm shift; exec @ARGV or exit 127' 600 "$@"
  fi
}

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
  else
    echo "FAIL $name (exit $rc):"
    tail -n 20 "$log" | sed 's/^/  /'
    failed=1
  fi
done
exit "$failed"
