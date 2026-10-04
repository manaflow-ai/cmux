#!/usr/bin/env bash
# check-action-surfaces.sh runs `swift test` (cmux-next's test host); it runs
# only as a fleet CI step (`cmux-ci run`, which sets CMUX_CI_STEP_KEY) or on a
# GitHub runner, never on a developer Mac (two agents ran it on the laptop on
# 2026-10-04). A stub `swift` records whether it was reached.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/pkg"
printf '#!/bin/sh\necho ran >"%s/ran"\n' "$TMP" > "$TMP/bin/swift"; chmod +x "$TMP/bin/swift"
run() { env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" "$@" /bin/bash "$ROOT/scripts/cmux-next/check-action-surfaces.sh" "$TMP/pkg" 2>&1; }
out=$(run) && { echo "FAIL: ran on a non-fleet host"; exit 1; }
[[ ! -e "$TMP/ran" ]] || { echo "FAIL: swift test started on a non-fleet host"; exit 1; }
grep -q 'cmux-ci run --class light --script scripts/cmux-next/check-action-surfaces.sh' <<<"$out" || { printf 'FAIL: message does not name the fleet path:\n%s\n' "$out"; exit 1; }
run CMUX_CI_STEP_KEY=k1 >/dev/null || { echo "FAIL: refused as a fleet step"; exit 1; }
[[ -e "$TMP/ran" ]] || { echo "FAIL: fleet step did not run swift test"; exit 1; }
rm -f "$TMP/ran"
run GITHUB_ACTIONS=true >/dev/null && [[ -e "$TMP/ran" ]] || { echo "FAIL: refused on a GitHub runner"; exit 1; }
printf 'check-action-surfaces fleet-only tests: ok\n'
