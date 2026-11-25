#!/usr/bin/env bash
# DOGFOOD BENCH idle-CPU command (cmux-ad m9 item 3): idle-cpu-bench.sh BUILD_JOB MINI [MINUTES] [OUT]
# Launches the fleet build BUILD_JOB fresh on perf mini MINI through the mini scheduler, leaves it idle MINUTES
# (default 10), and prints ONE JSON line last: {"app"|"acpmux"|"cmux_tui": {"n", "cpu_pct", "wakeups_per_s"},
# "processes": [...], "busiest": {"kind", "pid", "cpu_pct", "top_frame"}, "verdict", "build", "job", "mini"}.
# Each value is the mean over the last 60 s (one measured window after the idle time). If nothing was measured, the
# last line is the reason in plain text. OUT, when given, gets idle.json (that line) and the full log.
# Fleet host only (cmux-orchestrator-1): it writes a mini-scheduler spec; never run it on a person's Mac.
# The service form (dogfood-bench/idle-cpu.cmd): bash <checkout>/scripts/cmux-next/idle-cpu-bench.sh {job} {mini} 10 {out}
set -uo pipefail
job="${1:?usage: idle-cpu-bench.sh BUILD_JOB MINI [MINUTES] [OUT]}"
mini="${2:?usage: idle-cpu-bench.sh BUILD_JOB MINI [MINUTES] [OUT]}"
minutes="${3:-10}"
out="${4:-}"
here="$(cd "$(dirname "$0")" && pwd)"
[[ "$minutes" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "idle CPU not measured: MINUTES must be a number"; exit 2; }
log="$(mktemp -t idle-cpu-bench.XXXXXX)"
runner=""
# The service ends a bench after 3 h with SIGTERM: the runner then withdraws a spec that has not started.
trap '[[ -n "$runner" ]] && kill -TERM "$runner" 2>/dev/null && wait "$runner"; tail -n 1 "$log"; rm -f "$log"; exit 3' TERM INT
python3 -I "$here/idle-cpu-run.py" --build "$job" --mini "$mini" --minutes "$minutes" --windows 1 --window 60 \
  --label "bench-${job:0:8}" --wait --wait-hours 2.75 --json >"$log" 2>&1 &
runner=$!
wait "$runner"
status=$?
runner=""
if [[ -n "$out" ]]; then
  mkdir -p "$out" && cp "$log" "$out/idle-cpu.log"
  tail -n 1 "$log" | python3 -I -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null && tail -n 1 "$log" >"$out/idle.json"
fi
sed "\$d" "$log" | grep -v "^{" | tail -n 40
tail -n 1 "$log"
rm -f "$log"
exit $status
