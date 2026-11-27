#!/usr/bin/env bash
# scripts/measure/launch-ready-preflight.sh: a system indexer over the threshold fails with its name; a busy compiler
# alone passes; the threshold argument is honored; cmux-ci's CMUX_CI_HOST_NOISY=1 fails it; top's first sample (no
# interval behind it) is not counted.
# top and sysctl are stubs on PATH. Run: bash scripts/measure/tests/launch-ready-preflight.test.sh
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/launch-ready-preflight.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
printf '#!/bin/sh\necho "{ 12.40 9.10 6.00 }"\n' >"$tmp/bin/sysctl"
printf '#!/bin/sh\ncat "$LR_TEST_TOP"\n' >"$tmp/bin/top"
chmod +x "$tmp/bin/sysctl" "$tmp/bin/top"
fail=0

# sample HEADER_ROWS...: one `top -l` sample as macOS prints it, header then "PID %CPU COMMAND" rows.
sample() {
  printf 'Processes: 612 total, 4 running, 608 sleeping, 3120 threads\n2026/11/17 10:00:00\nLoad Avg: 12.40, 9.10, 6.00\n\n'
  printf 'PID    %%CPU  COMMAND\n'
  printf '%s\n' "$@"
}

# The first sample is all noise (mediaanalysisd 900 %): the check reads only the second and third.
{ sample "123    900.0 mediaanalysisd" "77     0.0   rustc"
  sample "123    118.0 mediaanalysisd" "88     40.0  mds" "601    20.0  mdworker_shared" "602    25.0  mdworker_shared" "900    3.0   cmux NEXT Helper"
  sample "123    122.0 mediaanalysisd" "88     38.0  mds" "601    10.0  mdworker_shared" "900    1.0   cmux NEXT Helper"
} >"$tmp/hot.txt"
{ sample "77     0.0   rustc"
  sample "77     380.0 rustc" "78     95.0  swift-frontend" "88     4.0   mds" "500    2.0   WindowServer"
  sample "77     360.0 rustc" "78     105.0 swift-frontend" "88     6.0   mds" "500    2.0   WindowServer"
} >"$tmp/build.txt"

run() { set +e; out="$(env -u CMUX_CI_HOST_NOISY PATH="$tmp/bin:$PATH" LR_TEST_TOP="$tmp/$1" bash "$script" "${@:2}" 2>&1)"; status=$?; set -e; }
check() { if ! eval "$1"; then echo "FAIL: $2 (exit $status)"; echo "$out" | sed 's/^/    /'; fail=1; fi; }

run hot.txt
check '[ $status -eq 1 ]' "a hot indexer fails"
check '[[ "$out" == *"LR-HOT-HOST mediaanalysisd=120.0,mds=39.0 (threshold 30%) host_noisy=0 load_1m=12.40"* ]]' "the hot indexers are named with their mean CPU and the load"
check '[[ "$out" == *"LR-HOT-HOST top5 mediaanalysisd=120.0,mds=39.0,mdworker_shared=27.5,cmux_NEXT_Helper=2.0"* ]]' "the top CPU users follow, mdworker_shared summed per sample"

run build.txt
check '[ $status -eq 0 ]' "a busy compiler with no indexer passes"
check '[[ "$out" == "LR-PREFLIGHT ok host_noisy=0 load_1m=12.40 top=rustc=370.0,swift-frontend=100.0,mds=5.0" ]]' "the pass line names the top 3"

run hot.txt 150
check '[ $status -eq 0 ] && [[ "$out" == "LR-PREFLIGHT ok "* ]]' "threshold 150 passes mediaanalysisd at 120"
run hot.txt 25
check '[ $status -eq 1 ] && [[ "$out" == *"mds=39.0,mdworker_shared=27.5 (threshold 25%)"* ]]' "threshold 25 also names mdworker_shared"
run hot.txt abc
check '[ $status -eq 2 ]' "a threshold that is not a number is refused"

export CMUX_CI_HOST_NOISY=1
run() { set +e; out="$(env PATH="$tmp/bin:$PATH" LR_TEST_TOP="$tmp/$1" bash "$script" "${@:2}" 2>&1)"; status=$?; set -e; }
run build.txt
check '[ $status -eq 1 ] && [[ "$out" == *"LR-HOT-HOST none (threshold 30%) host_noisy=1 load_1m=12.40"* ]]' "cmux-ci's noisy mark fails a host with no hot indexer"
: >"$tmp/empty.txt"
run empty.txt
check '[ $status -eq 1 ] && [[ "$out" == "LR-HOT-HOST host_noisy=1 "* ]]' "the noisy mark fails even when top is unread"
unset CMUX_CI_HOST_NOISY
run() { set +e; out="$(env -u CMUX_CI_HOST_NOISY PATH="$tmp/bin:$PATH" LR_TEST_TOP="$tmp/$1" bash "$script" "${@:2}" 2>&1)"; status=$?; set -e; }

run empty.txt
check '[ $status -eq 0 ] && [[ "$out" == "LR-PREFLIGHT unread"* ]]' "no samples from top passes as unread"

[ "$fail" = 0 ] && echo "launch-ready-preflight.test.sh: all checks passed"
exit "$fail"
