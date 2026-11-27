#!/usr/bin/env bash
# quit-gamut's A/B setup must identify and bound a silent fetch or build. The 2026-11-27 receipt
# stopped after GAMUT host because the old heartbeat began only after the unbounded fetch.
# Run: bash scripts/measure/tests/quit-gamut-step-bounds.test.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
script="$root/scripts/measure/quit-gamut.sh"
fail() { echo "FAIL quit-gamut-step-bounds: $*" >&2; exit 1; }

bash -n "$script" || fail "quit-gamut.sh is not valid bash"
grep -q 'GAMUT fetch ' "$script" || fail "fetch step has no visible start line"
grep -q 'GAMUT_FETCH_TIMEOUT_S' "$script" || fail "fetch step has no hard bound"
grep -q -- '--depth=1' "$script" || fail "fetch is not shallow"
grep -q 'GAMUT build .* start' "$script" || fail "build step has no visible start line"
grep -q 'GAMUT_BUILD_TIMEOUT_S' "$script" || fail "build step has no hard bound"
grep -q 'tail -n 20' "$script" || fail "build/fetch tails are not emitted on completion"
if grep -q 'git fetch --quiet' "$script"; then
  fail "quit-gamut still has an unbounded quiet fetch"
fi
if grep -q 'build_with_heartbeat' "$script"; then
  fail "quit-gamut still uses the unbounded heartbeat wrapper"
fi
echo "quit-gamut-step-bounds: ok"
