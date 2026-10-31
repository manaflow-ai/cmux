#!/usr/bin/env bash
# Scratch (cp/scratch-e2-fix-on-fuzzred, never merge): run ghostty-next's
# libghostty-vt Zig tests at a fork commit on a fleet step.
# usage: scratch-ghostty-vt-zig-test.sh FORK_SHA [TEST_FILTER]
set -euo pipefail
sha="$1"
filter="${2:-}"
root="$(git rev-parse --show-toplevel)"
cd "$root"
git submodule update --init ghostty-next >/dev/null 2>&1 || true
cd "$root/ghostty-next"
git fetch -q origin "$sha" || git fetch -q origin
git checkout -q --detach "$sha"
echo "ghostty-next at $(git rev-parse HEAD); zig $("${ZIG:-zig}" version)"
bash "$root/scripts/ci/fetch-ghostty-zig-packages.sh" "$root/ghostty-next"
args=(build test-lib-vt --summary failures)
[[ -n "$filter" ]] && args+=("-Dtest-filter=$filter")
set +e
"${ZIG:-zig}" "${args[@]}" 2>&1 | tail -300
rc=${PIPESTATUS[0]}
echo "ZIG-TEST-RESULT sha=$sha filter='$filter' rc=$rc"
exit "$rc"
