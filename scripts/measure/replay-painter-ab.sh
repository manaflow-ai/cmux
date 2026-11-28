#!/usr/bin/env bash
# The painter A/B for goal visible-frame-p95-under-load, in one call: replay-under-load.sh once per viewport painter
# arm (react, dom-floor, worker; webviews/bench/support/viewportPainter.ts, #60405), interleaved over --runs rounds
# on the same CPUs, then one table of frame p95 per arm. It answers whether taking the visible chat viewport off the
# renderer main thread can reach the goal's 16.7 ms under 4x-cores load at all (worker), what a minimal main-thread
# painter reaches (dom-floor), and what the real pane reaches today (react).
#
#   scripts/measure/replay-painter-ab.sh [--runs 3] [--cores N] [--seconds 60] [--arms react,dom-floor,worker] [--dir DIR]
#
# Each arm's reading lands as DIR/ARM-ROUND.json (default $FAST_CHECKS_OUT or artifacts/replay-painter-ab); the
# table goes to stdout and DIR/summary.json. Arms interleave (react, dom-floor, worker, react, ...) so a drift in the
# machine's own load lands on every arm, not one. Exit 0 when every arm gave at least one reading.
#
# REPLAY_FRAME_TRACE=1 (measuring only): each run also records a Chrome trace with the frame pipeline's categories and
# writes DIR/ARM-ROUND.trace.json.frames.json, what filled each slow frame on each thread (replay-frame-trace.py), and
# the main-thread attribution beside it. Tracing costs the page time, so that run's p95 and busy % are not the number.
set -uo pipefail
root="$(git rev-parse --show-toplevel)"
runs=3
arms="react,dom-floor,worker"
dir="${FAST_CHECKS_OUT:-$root/artifacts/replay-painter-ab}"
pass=()
while [ $# -gt 0 ]; do
  case "$1" in
    --runs) runs="$2"; shift 2 ;;
    --arms) arms="$2"; shift 2 ;;
    --dir) dir="$2"; shift 2 ;;
    --cores|--seconds|--rate) pass+=("$1" "$2"); shift 2 ;;
    *) echo "usage: replay-painter-ab.sh [--runs 3] [--cores N] [--seconds 60] [--rate 40] [--arms a,b] [--dir DIR]" >&2; exit 2 ;;
  esac
done
[[ "$runs" =~ ^[1-9][0-9]*$ ]] || { echo "replay-painter-ab.sh: --runs takes a positive count" >&2; exit 2; }
mkdir -p "$dir"
IFS=, read -r -a arm_list <<<"$arms"
for ((round = 1; round <= runs; round++)); do
  for arm in "${arm_list[@]}"; do
    echo "replay-painter-ab: round $round arm $arm" >&2
    trace=()
    [ "${REPLAY_FRAME_TRACE:-0}" = 1 ] && trace=(--trace "$dir/$arm-$round.trace.json" --trace-frames)
    "$root/scripts/measure/replay-under-load.sh" --out "$dir/$arm-$round.json" --painter "$arm" ${pass[@]+"${pass[@]}"} \
      ${trace[@]+"${trace[@]}"} >&2 || true
  done
done
python3 -I - "$dir" "$arms" <<'PY'
import glob, json, os, statistics, sys
d, arms = sys.argv[1], sys.argv[2].split(",")
summary, ok = {}, True
print(f"{'arm':<10} {'runs':>4} {'p95 ms (each)':<24} {'median':>7} {'react p95':>10} {'main busy %':>11} {'load/core':>9}")
for arm in arms:
    rows = []
    for path in sorted(glob.glob(os.path.join(d, f"{arm}-*.json"))):
        try:
            rows.append(json.load(open(path)))
        except (OSError, ValueError):
            pass
    p95 = [r["frame_p95_ms"] for r in rows if r.get("frame_p95_ms") is not None]
    react = [r["react_frame_p95_ms"] for r in rows if r.get("react_frame_p95_ms") is not None]
    busy = [r["renderer_main_busy_pct"] for r in rows if r.get("renderer_main_busy_pct") is not None]
    load = [r["load_per_core"] for r in rows if r.get("load_per_core") is not None]
    errors = [r["error"][:200] for r in rows if r.get("error")]
    med = lambda xs: round(statistics.median(xs), 1) if xs else None
    summary[arm] = {"frame_p95_ms": p95, "median_p95_ms": med(p95), "react_frame_p95_ms": react,
                    "renderer_main_busy_pct": busy, "load_per_core": load, "errors": errors}
    ok = ok and bool(p95)
    print(f"{arm:<10} {len(p95):>4} {'/'.join(str(x) for x in p95):<24} {str(med(p95)):>7} {str(med(react)):>10} "
          f"{str(med(busy)):>11} {str(med(load)):>9}")
    for e in errors:
        print(f"  {arm} error: {e}")
json.dump(summary, open(os.path.join(d, "summary.json"), "w"), indent=1)
sys.exit(0 if ok else 1)
PY
