#!/usr/bin/env bash
# build-progress.sh's measure_quiet keeps a quiet build's step printing (the controller stops a measurement silent for
# 45 minutes), returns the build's own status, sends the build's output only to its log, and leaves nothing holding a
# $(...) caller's pipe. launch-ready.sh's copy of nightly-fresh-launch.sh (main removed, in a scratch folder inside the
# checkout) defines it along with build_dmg.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

cd "$here"
# shellcheck source=scripts/measure/build-progress.sh
source scripts/measure/build-progress.sh
export MEASURE_BUILD_PROGRESS_S=1
exec 9>"$tmp/step.out" # the step's stdout, as sourcing saved it

out="$(measure_quiet "T ok" "$tmp/ok.log" bash -c 'for i in 1 2 3; do echo line$i; sleep 1; done')"
[[ -z "$out" ]] || fail "the build's own output reached stdout: $out"
grep -q '^T ok: still building, [0-9]*s: line' "$tmp/step.out" || fail "no progress line: $(cat "$tmp/step.out")"
[[ "$(cat "$tmp/ok.log")" == $'line1\nline2\nline3' ]] || fail "log: $(cat "$tmp/ok.log")"

status=0
measure_quiet "T fail" "$tmp/fail.log" bash -c 'echo boom; exit 7' >/dev/null || status=$?
[[ "$status" == 7 ]] || fail "status $status, want 7"

# Inside a $(...) whose stdout is thrown away the progress still reaches fd 9, and the $(...) ends with the build.
start=$SECONDS
got="$(measure_quiet "T sub" "$tmp/sub.log" sleep 2.5 >/dev/null 2>&1; echo captured)"
[[ "$got" == captured ]] || fail "captured '$got'"
grep -q '^T sub: still building' "$tmp/step.out" || fail "no progress from inside the \$(...): $(cat "$tmp/step.out")"
(( SECONDS - start <= 5 )) || fail "the \$(...) waited $((SECONDS - start))s on a leftover ticker"

lib="$here/.build/build-progress-test-$$"
mkdir -p "$lib"
trap 'rm -rf "$tmp" "$lib"' EXIT
sed '/^main "\$@"; exit \$?$/d' scripts/measure/nightly-fresh-launch.sh >"$lib/nightly-fresh-launch-lib.sh"
(unset -f measure_quiet; source "$lib/nightly-fresh-launch-lib.sh"; declare -F build_dmg measure_quiet >/dev/null) \
  || fail "launch-ready.sh's copy of nightly-fresh-launch.sh does not define build_dmg and measure_quiet"
echo PASS
