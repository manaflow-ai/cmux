#!/usr/bin/env bash
# The perf goals' always-available reading on a fleet VM: a recorded transcript replayed into the real pane
# (webviews/bench/replay-under-load.bench.ts, read through the #50373 frame tally) while `stress-ng --cpu $((4*nproc))`
# loads the machine, the load Leo's goals name ("while the Mac's load is at least 4x its cores").
#
# Leo, 2026-11-23 (relayed): "Run the #50373 frame tally against a replayed transcript in a headless nightly on a GCP
# VM with stress-ng at 4x cores, and get frame_p95_ms and renderer_main_busy_pct publishing from there on every sensor
# pass, with the [his Mac's] reading as a second series."
#
#   scripts/measure/replay-under-load.sh [--out FILE] [--cores N] [--seconds 60] [--rate 40] [--log FILE]
#
# --cores N runs the load and the replay on the first N CPUs only (taskset), so a shared VM gives up N cores, not all
# of them; nproc inside is N and stress-ng runs 4*N workers there. Without it the whole machine is loaded: only a VM
# that runs nothing else (never Leo's Macs: no load or suites there).
# Writes one JSON document (perf-vm-replay/v1) to --out (default artifacts/replay-under-load/reading.json): the
# bench's reading plus load_1m, cores (the CPUs the run had), load_per_core (the stress workers and the run's own
# threads over those CPUs, sampled from /proc while the replay ran), stressors, commit, host. Exit 0 with a reading,
# 1 when the bench failed (the document then has `error`), 2 on bad arguments.
set -uo pipefail
root="$(git rev-parse --show-toplevel)"
out="$root/artifacts/replay-under-load/reading.json"
cores=""
bench_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --cores) cores="$2"; shift 2 ;;
    --seconds|--rate|--log|--warm) bench_args+=("$1" "$2"); shift 2 ;;
    *) echo "usage: replay-under-load.sh [--out FILE] [--cores N] [--seconds 60] [--rate 40] [--log FILE]" >&2; exit 2 ;;
  esac
done
if [ -n "$cores" ] && [ -z "${REPLAY_UNDER_LOAD_PINNED:-}" ]; then
  [[ "$cores" =~ ^[1-9][0-9]*$ ]] || { echo "replay-under-load.sh: --cores takes a positive count" >&2; exit 2; }
  export REPLAY_UNDER_LOAD_PINNED=1
  exec taskset -c "0-$((cores - 1))" "$0" --out "$out" ${bench_args[@]+"${bench_args[@]}"}
fi
mkdir -p "$(dirname "$out")"
work="$(mktemp -d)"
stress_pid=""
cleanup() {
  [ -n "$stress_pid" ] && kill "$stress_pid" 2>/dev/null && wait "$stress_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

if ! command -v stress-ng >/dev/null 2>&1; then
  sudo -n apt-get install -y stress-ng >"$work/apt.log" 2>&1 || true
fi
command -v stress-ng >/dev/null 2>&1 || { echo "replay-under-load.sh: no stress-ng (apt-get install stress-ng)" >&2; exit 1; }
n="$(nproc)"
stressors=$((4 * n))
cd "$root/webviews" || exit 1
[ -d node_modules ] || bash ../scripts/ci/bun-install.sh --frozen-lockfile >"$work/install.log" 2>&1 \
  || { tail -20 "$work/install.log" >&2; exit 1; }
# The pages' generated/strings.json files are gitignored and written only by the install's best-effort postinstall,
# so a kept node_modules (the timer's every run after the first) builds without them. Write them every run.
bun scripts/pages/gen-strings.mjs >"$work/strings.log" 2>&1 || { tail -20 "$work/strings.log" >&2; exit 1; }

# The load first, by PID (this script started it; cleanup stops only it), and enough of it to be running before the
# replay's warm-up ends.
stress-ng --cpu "$stressors" --cpu-method matrixprod --timeout 900s --quiet >"$work/stress.log" 2>&1 &
stress_pid=$!
sleep 10
# Runnable threads on our CPUs while the replay runs: every 5 s, the threads of this run's process tree in state R,
# over nproc. /proc/loadavg is the host's, which on a --cores run also counts what the rest of the VM runs.
(
  while :; do
    r=0
    for task in /proc/[0-9]*/task/[0-9]*/stat; do
      read -r line 2>/dev/null <"$task" || continue
      rest="${line##*) }"
      [ "${rest:0:1}" = "R" ] || continue
      pid="${task#/proc/}"; pid="${pid%%/*}"
      grep -qs "^Cpus_allowed_list:[[:space:]]*0-$((n - 1))\$" "/proc/$pid/status" && r=$((r + 1))
    done
    echo "$r" >>"$work/runnable"
    sleep 5
  done
) &
sampler=$!
status=0
bun bench/replay-under-load.bench.ts --out "$work/bench.json" ${bench_args[@]+"${bench_args[@]}"} >"$work/bench.log" 2>&1 || status=1
kill "$sampler" 2>/dev/null; wait "$sampler" 2>/dev/null
read -r load1 _ </proc/loadavg
tail -3 "$work/bench.log"
python3 -I - "$work" "$out" "$n" "$stressors" "$load1" "$status" "$(git rev-parse HEAD)" "$(hostname -s)" \
  "${REPLAY_UNDER_LOAD_PINNED:+pinned}" <<'PY'
import datetime, json, os, sys
work, out, n, stressors, load1, status, commit, host, pinned = sys.argv[1:10]
n, stressors, load1 = int(n), int(stressors), float(load1)
try:
    bench = json.load(open(os.path.join(work, "bench.json")))
except (OSError, ValueError):
    bench = {"error": (open(os.path.join(work, "bench.log"), errors="replace").read()[-800:] or "no bench output")}
try:
    samples = [int(x) for x in open(os.path.join(work, "runnable")).read().split()]
except (OSError, ValueError):
    samples = []
# On the whole machine the load average is the reading; on a --cores slice, the run's runnable threads over its CPUs.
per_core = (sum(samples) / len(samples) / n) if (pinned and samples) else load1 / n
doc = {**bench, "schema": "perf-vm-replay/v1", "bench_schema": bench.get("schema"), "host": host, "commit": commit,
       "cores": n, "stressors": stressors, "load_1m": load1, "load_per_core": round(per_core, 2),
       "load_basis": "runnable threads on the run's CPUs" if pinned else "/proc/loadavg over nproc",
       "at": bench.get("at") or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
if status != "0" and "error" not in doc:
    doc["error"] = "the bench exited nonzero"
json.dump(doc, open(out, "w"), indent=1)
print(json.dumps({k: doc.get(k) for k in ("frame_p95_ms", "renderer_main_busy_pct", "load_per_core", "cores", "error")}))
PY
exit "$status"
