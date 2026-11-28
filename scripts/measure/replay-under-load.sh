#!/usr/bin/env bash
# The perf goals' always-available reading on a fleet VM: a recorded transcript replayed into the real pane
# (webviews/bench/replay-under-load.bench.ts, read through the #50373 frame tally) while `stress-ng --cpu $((4*nproc))`
# loads the machine, the load Leo's goals name ("while the Mac's load is at least 4x its cores").
#
# Leo, 2026-11-23 (relayed): "Run the #50373 frame tally against a replayed transcript in a headless nightly on a GCP
# VM with stress-ng at 4x cores, and get frame_p95_ms and renderer_main_busy_pct publishing from there on every sensor
# pass, with the [his Mac's] reading as a second series."
#
#   scripts/measure/replay-under-load.sh [--out FILE] [--cores N] [--seconds 60] [--rate 40] [--log FILE] [--profile] [--trace FILE]
#     [--painter react|dom-floor|worker|native] [--history-rows N]   (bench-only viewport painter A/B: webviews/bench/support/viewportPainter.ts; native = Experiments nativeTranscript)
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
profile=0
trace=""
bench_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --cores) cores="$2"; shift 2 ;;
    --seconds|--rate|--log|--warm|--painter|--history-rows) bench_args+=("$1" "$2"); shift 2 ;;
    --trace) trace="$(realpath -m "$2")"; bench_args+=("$1" "$trace"); shift 2 ;;
    --profile) bench_args+=("$1"); profile=1; shift ;;
    *) echo "usage: replay-under-load.sh [--out FILE] [--cores N] [--seconds 60] [--rate 40] [--log FILE] [--profile] [--trace FILE] [--painter ARM] [--history-rows N]" >&2; exit 2 ;;
  esac
done
if [ -n "$cores" ] && [ -z "${REPLAY_UNDER_LOAD_PINNED:-}" ]; then
  [[ "$cores" =~ ^[1-9][0-9]*$ ]] || { echo "replay-under-load.sh: --cores takes a positive count" >&2; exit 2; }
  export REPLAY_UNDER_LOAD_PINNED=1
  exec taskset -c "0-$((cores - 1))" "$0" --out "$out" ${bench_args[@]+"${bench_args[@]}"}
fi
# One run at a time per machine: two runs on the same CPUs load each other (2x the stress workers, two Chromiums), so
# each reads the other's load as its own (2026-11-27: two A/B copies overlapped on CPUs 0-7 and read load_per_core
# 3.2 to 6.1 and p95 66.7 to 83.3 between arms of one change). Every run, the sensor timer's too, waits here for the
# one before it. A caller already holding the lock on fd 9 (`( flock 9; replay-under-load.sh ... ) 9>LOCK`) has it.
lock="${REPLAY_UNDER_LOAD_LOCK:-/tmp/replay-under-load.lock}"
if [ "$(readlink "/proc/$$/fd/9" 2>/dev/null)" = "$lock" ] && flock -n 9; then
  :
else
  exec 9>>"$lock"
  flock -w "${REPLAY_UNDER_LOAD_LOCK_WAIT:-3600}" 9 || { echo "replay-under-load.sh: another run held $lock past the wait" >&2; exit 1; }
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
# A runner with neither stress-ng nor root to install it (the fleet's CI runners) loads its CPUs with plain shell busy
# loops instead: the same 4*nproc runnable threads, without matrixprod's cache pressure. The reading names which ran
# (ported from cmux#56545, whose lane went idle).
load_tool=stress-ng
command -v stress-ng >/dev/null 2>&1 || load_tool=busy-loops
n="$(nproc)"
stressors=$((4 * n))
cd "$root/webviews" || exit 1
# A node_modules that exists but lacks the bench's deps (a partial projection link, an interrupted install) is not installed.
[ -d node_modules/playwright ] || bash ../scripts/ci/bun-install.sh --frozen-lockfile >"$work/install.log" 2>&1 \
  || { tail -20 "$work/install.log" >&2; exit 1; }
# The pages' generated/strings.json files are gitignored and written only by the install's best-effort postinstall,
# so a kept node_modules (the timer's every run after the first) builds without them. Write them every run.
bun scripts/pages/gen-strings.mjs >"$work/strings.log" 2>&1 || { tail -20 "$work/strings.log" >&2; exit 1; }

# The load first, by PID (this script started it; cleanup stops only it), and enough of it to be running before the
# replay's warm-up ends.
if [ "$load_tool" = stress-ng ]; then
  stress-ng --cpu "$stressors" --cpu-method matrixprod --timeout 900s --quiet >"$work/stress.log" 2>&1 &
else
  # One parent for every loop: cleanup's kill of this PID makes it stop its own jobs and nothing else.
  bash -c 'trap "kill \$(jobs -p) 2>/dev/null; exit 0" TERM INT
    for _ in $(seq "$1"); do (while :; do :; done) & done
    sleep 900 & wait $!; kill $(jobs -p) 2>/dev/null' _ "$stressors" \
    >"$work/stress.log" 2>&1 &
fi
stress_pid=$!
sleep 10
# Runnable threads on our CPUs while the replay runs: every 5 s, the threads of this run's process tree in state R,
# over nproc. /proc/loadavg is the host's, which on a --cores run also counts what the rest of the VM runs.
# A thread is ours when its CPU list is this run's, read from this shell: a caller may pin the run to any CPUs (the
# VM sensor pins to the quietest ones, e.g. 3,5,9-14), and a fixed 0-(n-1) then matched nothing and read 0.0.
allowed="$(sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' /proc/$$/status)"
(
  while :; do
    r=0
    for task in /proc/[0-9]*/task/[0-9]*/stat; do
      read -r line 2>/dev/null <"$task" || continue
      rest="${line##*) }"
      [ "${rest:0:1}" = "R" ] || continue
      pid="${task#/proc/}"; pid="${pid%%/*}"
      grep -qsxF "Cpus_allowed_list:	$allowed" "/proc/$pid/status" && r=$((r + 1))
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
# --trace: the stress load stops first, then the attribution reads the trace here (streamed, so a big trace stays out
# of memory), and the trace is kept gzipped beside it (TRACE.gz) for a fleet step's --artifact.
if [ -n "$trace" ] && [ -s "$trace" ]; then
  [ -n "$stress_pid" ] && kill "$stress_pid" 2>/dev/null && wait "$stress_pid" 2>/dev/null
  stress_pid=""
  ls -l "$trace" >&2
  python3 -I "$root/scripts/measure/replay-attribution.py" "$trace" --json "$trace.attribution.json" || status=1
  gzip -f -1 "$trace"
fi
if [ "$profile" -eq 1 ]; then
  cat "$work/bench.log"
else
  # A failed build's log ends on stack frames (a Babel error ends on gensync frames, 2026-11-26), so its cause line,
  # the bench's "FAILED:" line, goes first.
  [ "$status" -ne 0 ] && grep -m1 -F 'replay-under-load: FAILED:' "$work/bench.log" | cut -c1-600 >&2
  grep -v -F '[BABEL] Note:' "$work/bench.log" | tail -3
fi
python3 -I - "$work" "$out" "$n" "$stressors" "$load1" "$status" "$(git rev-parse HEAD)" "$(hostname -s)" \
  "${REPLAY_UNDER_LOAD_PINNED:+pinned}" "$load_tool" <<'PY'
import datetime, json, os, sys
work, out, n, stressors, load1, status, commit, host, pinned, load_tool = sys.argv[1:11]
n, stressors, load1 = int(n), int(stressors), float(load1)
try:
    bench = json.load(open(os.path.join(work, "bench.json")))
except (OSError, ValueError):
    # Babel's "deoptimised the styling" notes print on every build of the 500 KB App.tsx, so a failed run's tail was
    # those notes and the sensor's head_error never reached its cause (2026-11-27, head 4d193af): drop them first.
    log = "\n".join(l for l in open(os.path.join(work, "bench.log"), errors="replace").read().splitlines()
                    if not l.startswith("[BABEL] Note:"))
    # The cause first: the bench's FAILED line (or the first line naming an error), then the log's tail.
    lines = [line.strip() for line in log.splitlines() if line.strip()]
    cause = next((l for l in lines if l.startswith("replay-under-load: FAILED:")), "") or next(
        (l for l in lines if "Error" in l and not l.startswith("at ")), "")
    tail = log[-500:]
    bench = {"error": ((cause[:400] + " ... " + tail) if cause and cause not in tail else log[-800:]) or "no bench output"}
try:
    samples = [int(x) for x in open(os.path.join(work, "runnable")).read().split()]
except (OSError, ValueError):
    samples = []
# On the whole machine the load average is the reading; on a --cores slice, the run's runnable threads over its CPUs.
per_core = (sum(samples) / len(samples) / n) if (pinned and samples) else load1 / n
doc = {**bench, "schema": "perf-vm-replay/v1", "bench_schema": bench.get("schema"), "host": host, "commit": commit,
       "cores": n, "stressors": stressors, "load_tool": load_tool, "load_1m": load1, "load_per_core": round(per_core, 2),
       "load_basis": "runnable threads on the run's CPUs" if pinned else "/proc/loadavg over nproc",
       "at": bench.get("at") or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
if status != "0" and "error" not in doc:
    doc["error"] = "the bench exited nonzero"
json.dump(doc, open(out, "w"), indent=1)
print(json.dumps({k: doc.get(k) for k in ("frame_p95_ms", "renderer_main_busy_pct", "load_per_core", "cores", "error")}))
PY
exit "$status"
