#!/usr/bin/env bash
# Measurement driver on the Linux host VM. Tracks only the PIDs it starts (pidfiles in $STATE).
#   vm-bench.sh up WIDTHxHEIGHT [serve args...]   restart Xvfb :99 and rdhost serve (detached)
#   vm-bench.sh run NAME [client args...]          run one client measurement -> $OUT/NAME.json
#   vm-bench.sh down                               stop what `up` started
set -euo pipefail
BIN=${RDHOST:-/usr/local/bin/rdhost}
STATE=${STATE:-/tmp/rdhost}
OUT=${OUT:-$STATE/results}
mkdir -p "$STATE" "$OUT"

stop_pid() {
  local f="$STATE/$1.pid"
  [ -f "$f" ] || return 0
  local pid; pid=$(cat "$f")
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  fi
  rm -f "$f"
}

# CPU seconds (utime+stime) of a pid, or 0.
cpu_s() {
  local pid=$1
  [ "$pid" != 0 ] && [ -r "/proc/$pid/stat" ] || { echo 0; return; }
  awk -v hz="$(getconf CLK_TCK)" '{print ($14+$15)/hz}' "/proc/$pid/stat"
}

testapp_pid() { pgrep -f "$BIN testapp --display :99" | head -1 || true; }

case "${1:-}" in
  up)
    size=$2; shift 2
    stop_pid serve; stop_pid xvfb
    setsid Xvfb :99 -screen 0 "${size}x24" -nolisten tcp </dev/null >"$STATE/xvfb.log" 2>&1 &
    echo $! >"$STATE/xvfb.pid"
    for _ in $(seq 1 100); do [ -S /tmp/.X11-unix/X99 ] && break; sleep 0.05; done
    setsid "$BIN" serve --display :99 --port 7400 --log-dir "$STATE/sessions" "$@" </dev/null >>"$STATE/serve.log" 2>&1 &
    echo $! >"$STATE/serve.pid"
    for _ in $(seq 1 100); do ss -ltn | grep -q ':7400 ' && break; sleep 0.05; done
    echo "up: Xvfb $(cat "$STATE/xvfb.pid") serve $(cat "$STATE/serve.pid") size $size args: $*"
    ;;
  run)
    name=$2; shift 2
    serve=$(cat "$STATE/serve.pid"); xvfb=$(cat "$STATE/xvfb.pid")
    # Prime: a 1-sample session makes serve start the test app with this run's workload,
    # so the test app PID is stable across the measured run.
    "$BIN" client "$@" --samples 1 --warmup 0 --idle-secs 1 --out "$STATE/prime.json" >/dev/null
    ta=$(testapp_pid)
    t0=$(date +%s.%N); s0=$(cpu_s "$serve"); x0=$(cpu_s "$xvfb"); a0=$(cpu_s "${ta:-0}")
    "$BIN" client "$@" --out "$OUT/$name.json"
    t1=$(date +%s.%N); s1=$(cpu_s "$serve"); x1=$(cpu_s "$xvfb"); a1=$(cpu_s "${ta:-0}")
    python3 - "$OUT/$name.json" "$t0" "$t1" "$s0" "$s1" "$x0" "$x1" "$a0" "$a1" <<'PY'
import json, sys
path, t0, t1, s0, s1, x0, x1, a0, a1 = sys.argv[1:]
wall = float(t1) - float(t0)
pct = lambda a, b: round((float(b) - float(a)) / wall * 100, 1)
d = json.load(open(path))
d["host_process_cpu_pct_over_run"] = {
    "serve": pct(s0, s1),
    "xvfb": pct(x0, x1),
    "testapp": pct(a0, a1),
    "wall_s": round(wall, 2),
    "note": "percent of one core, averaged over the whole client run including connect and first IDR",
}
json.dump(d, open(path, "w"), indent=1)
g = d.get("g2g_ms") or {}
h = d["host"]; v = d["video"]; c = d["host_process_cpu_pct_over_run"]
p = lambda s: (s or {}).get("p50")
print(f"{path.split('/')[-1]}: n={d['samples']} loss={d['losses']} g2g p50={g.get('p50')} p95={g.get('p95')} p99={g.get('p99')} "
      f"min={g.get('min')} max={g.get('max')} | {v['kbit_per_s']:.0f} kbit/s {v['frames_per_s']:.1f} fps key={v['keyframes_total']} "
      f"| dec p50={p(d['decode_ms'])} rtt p50={p(d['rtt_ms'])} | host proc%={p(h['cpu_pct_process'])} sys%={p(h['cpu_pct_system'])} "
      f"enc={p(h['encode_ms_p50'])} | serve%={c['serve']} xvfb%={c['xvfb']} testapp%={c['testapp']}")
PY
    ;;
  down)
    stop_pid serve; stop_pid xvfb
    ;;
  *)
    echo "usage: $0 up WxH [serve args] | run NAME [client args] | down" >&2; exit 2;;
esac
