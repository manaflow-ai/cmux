#!/usr/bin/env bash
# scripts/measure/quiet-host.sh: refuses a measurement outside its list and runs only on the fleet; a dry run marks
# the checkout for Spotlight and prints both CPU records. Builds nothing. Run: bash scripts/measure/tests/quiet-host.test.sh
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/quiet-host.sh"
fail=0

run() { set +e; out="$(env -u CMUX_CI_STEP_KEY "$@" 2>&1)"; status=$?; set -e; }
check() { if ! eval "$1"; then echo "FAIL: $2 (exit $status)"; echo "$out" | sed 's/^/    /'; fail=1; fi; }

run bash "$script"
check '[ $status -eq 2 ] && [[ "$out" == *usage* ]]' "no argument is refused"
run bash "$script" evil.sh
check '[ $status -eq 2 ] && [[ "$out" == *"is not a measurement"* ]]' "an unlisted script is refused"
run bash "$script" ../ci/package-test-lane.sh
check '[ $status -eq 2 ] && [[ "$out" == *"is not a measurement"* ]]' "a path outside scripts/measure is refused"
run bash "$script" instant-new-surfaces.sh --runs=1
check '[ $status -eq 2 ] && [[ "$out" == *"runs only on the build fleet"* ]]' "a listed script outside the fleet stops at the guard"

repo="$(cd "$(dirname "$script")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
run env QUIET_HOST_DRY_RUN=1 TMPDIR="$tmp" bash "$script" instant-new-surfaces.sh --commands=new_tab
check '[ $status -eq 0 ]' "a dry run passes"
check '[[ "$out" == *"QUIET-HOST-CPU before:"* && "$out" == *"QUIET-HOST-CPU after:"* ]]' "both CPU records are printed"
check '[[ "$out" == *"would run scripts/measure/instant-new-surfaces.sh --commands=new_tab"* ]]' "the arguments pass through"
check '[ -f "$tmp/.metadata_never_index" ] && [ -f "$repo/artifacts/.metadata_never_index" ]' "TMPDIR and artifacts/ are marked"

[ "$fail" = 0 ] && echo "quiet-host.test.sh: all checks passed"
exit "$fail"
