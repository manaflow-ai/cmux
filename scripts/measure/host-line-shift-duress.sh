#!/usr/bin/env bash
# How far the agent pane's chat rows and composer move when its link drops and comes back, under duress (Leo,
# 2026-11-22: "always. testing under duress. you should also be able to simulate duress "offline""): a long chat
# (chat-sim --long 1000, or a recorded one with REPLAY=fixture.ndjson) streaming a chunk every 4 ms while each host
# line state is swapped in, optionally on a machine kept busy with one `yes` per core (LOAD=1). The bench is
# webviews/bench/host-line-shift-duress.bench.ts, run at each commit with bench-at-commits.sh, so a before and an
# after come from the same harness on the same machine.
#
#   cmux-ci test --setup webviews -- bash -c 'scripts/measure/host-line-shift-duress.sh SHA... [LOAD=1] [REPLAY=test/fixtures/chat-sim/replay-lane-session.ndjson]'
#
# Prints "BENCH-AT <sha>" then `HOST-LINE-SHIFT-DURESS {"max_px":…,"states":{…},"chunks":…,"rows":…}` per commit, and
# the load average when LOAD=1. 05ca1989a98 (before the connection chip, #49415) reads 26.19 px; feat-cmux-next 0.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
shas=()
load=0
env_pairs=()
for arg in "$@"; do
  case "$arg" in
    LOAD=*) load="${arg#LOAD=}" ;;
    REPLAY=*) env_pairs+=("DURESS_REPLAY=${arg#REPLAY=}") ;;
    *=*) echo "host-line-shift-duress.sh: unknown knob $arg" >&2; exit 2 ;;
    *) shas+=("$arg") ;;
  esac
done
[[ ${#shas[@]} -gt 0 ]] || { echo "usage: host-line-shift-duress.sh SHA... [LOAD=1] [REPLAY=fixture]" >&2; exit 2; }
loaders=()
stop_load() { [[ ${#loaders[@]} -gt 0 ]] && kill ${loaders[@]+"${loaders[@]}"} 2>/dev/null; }
trap stop_load EXIT
if [[ "$load" == 1 ]]; then
  for _ in $(seq "$(nproc)"); do yes >/dev/null & loaders+=($!); done
  sleep 5
  echo "LOAD $(cut -d' ' -f1-3 /proc/loadavg) on $(nproc) cores"
fi
cd "$here/../../webviews" && { bun install --frozen-lockfile >/dev/null 2>&1 || bun install >/dev/null 2>&1; }
ENV="$(IFS=,; echo "${env_pairs[*]-}")" "$here/bench-at-commits.sh" bench/host-line-shift-duress.bench.ts ${shas[@]+"${shas[@]}"}
status=$?
[[ "$load" == 1 ]] && echo "LOAD $(cut -d' ' -f1-3 /proc/loadavg) at the end"
exit "$status"
