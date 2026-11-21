#!/usr/bin/env bash
# The dev-loop ceiling (cmuxterm-hq goals/dev-loop-ceiling.md): runs each loop's measurement on this Mac, then
# scripts/measure/dev-loop/bound.py, which writes OUT/report.json with each loop's p50 over its simulated stage-floor
# bound and the worst of them (the goal holds it at 2x or under). Leo: "Dev loop at its theoretical ceiling: a
# measured and simulated bound for edit-to-running (web swap, daemon restart, Swift inject, startup-time loop)
# published, and the measured p50 within 2x of that bound".
#   scripts/measure/dev-loop-ceiling.sh OUT [N] [LOOPS]
# N: edit rounds per loop (default 5). LOOPS: comma list (default all four). A loop whose script is missing or fails
# is reported UNMEASURED (its log is OUT/<loop>.log) and the others still run. Exit 0 only when every loop measured.
set -uo pipefail
out="${1:?usage: dev-loop-ceiling.sh OUT [N] [LOOPS]}"
n="${2:-5}"
loops="${3:-web_swap,daemon_restart,swift_inject,startup_loop}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
here="$root/scripts/measure/dev-loop"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
cd "$root"
IFS=, read -ra list <<<"$loops"
for loop in "${list[@]}"; do
  script="$here/$loop.sh"
  if [[ ! -x "$script" ]]; then
    printf '{"schema":"dev-loop-ceiling/loop/v1","loop":"%s","error":"no script %s"}\n' "$loop" "${script#"$root"/}" >"$out/$loop.json"
    echo "dev-loop-ceiling: $loop: no script" >&2
    continue
  fi
  start=$(date +%s)
  echo "dev-loop-ceiling: $loop (n=$n)"
  if ! "$script" "$out" "$n" >"$out/$loop.log" 2>&1; then
    echo "dev-loop-ceiling: $loop failed after $(( $(date +%s) - start )) s; last lines:" >&2
    tail -20 "$out/$loop.log" >&2
    [[ -s "$out/$loop.json" ]] || printf '{"schema":"dev-loop-ceiling/loop/v1","loop":"%s","error":"exited nonzero with no json"}\n' "$loop" >"$out/$loop.json"
  else
    echo "dev-loop-ceiling: $loop done in $(( $(date +%s) - start )) s"
  fi
done
python3 "$here/bound.py" "$out" --loops "$loops"
