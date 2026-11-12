#!/usr/bin/env bash
# Screen stream eval target: the scene's window alone as a cmux.rd/1 stream at the computer-use
# preview's thumbnail rung (`cmux-rd host --display window:ID --max-width 360`, hq#9837 fix 2), with
# `cmux-rd bench` as the viewer, as rd.sh does for the whole display. EVAL_RDWIN_FPS caps its rate
# (default 6, the preview's rate today; rd-window-30.sh runs it at 30). The window rows also report
# the host process's CPU over the view (extra.process_cpu_pct), which cu-png reports for its own.
set -euo pipefail
verb=$1
shift
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rd="$EVAL_BIN/cmux-rd"
port=4103
case "$verb" in
  build)
    bash "$here/rd.sh" build
    swiftc -O -o "$EVAL_BIN/screen-eval-window-id" "$here/../window-id.swift"
    ;;
  host-start)
    window=$("$EVAL_BIN/screen-eval-window-id" screen-eval-scene) ||
      { echo "rd-window: no scene window (this target measures the window rows only)" >&2; exit 1; }
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$EVAL_STATE/token"
    chmod 600 "$EVAL_STATE/token"
    : >"$EVAL_STATE/host.log"
    "$rd" host --owner owner --bind 127.0.0.1 --port "$port" --display "window:$window" \
      --max-width "${EVAL_RDWIN_LONG_SIDE:-360}" --max-fps "${EVAL_RDWIN_FPS:-6}" \
      --token-fd 3 3< <(cat "$EVAL_STATE/token") >>"$EVAL_STATE/host.log" 2>&1 &
    echo $! >"$EVAL_STATE/host.pid"
    for _ in $(seq 1 100); do
      grep -q listening "$EVAL_STATE/host.log" && exit 0
      kill -0 "$(cat "$EVAL_STATE/host.pid")" 2>/dev/null || break
      sleep 0.1 # bounded wait for the host's listening line (10 s)
    done
    echo "rd-window: the host did not start listening" >&2
    tail -20 "$EVAL_STATE/host.log" >&2
    exit 1
    ;;
  host-stop) bash "$here/rd.sh" host-stop ;;
  latency-view | latency-report) exit 0 ;;
  window-view)
    # The host's CPU time across the view: ps cputime before and after, over the wall time between.
    pid=$(cat "$EVAL_STATE/host.pid")
    cpu() { ps -o cputime= -p "$pid" | awk -F'[:.]' '{ n = NF; s = $(n-1) + $(n-2) * 60 + (n > 3 ? $(n-3) * 3600 : 0); print s * 1000 + $n * 10 }'; }
    c0=$(cpu) t0=$(python3 -I -c 'import time; print(time.time_ns() // 1_000_000)')
    bash "$here/rd.sh" window-view "$@"
    c1=$(cpu) t1=$(python3 -I -c 'import time; print(time.time_ns() // 1_000_000)')
    echo "{\"cpu_ms\": $((c1 - c0)), \"wall_ms\": $((t1 - t0))}" >"$4.cpu"
    ;;
  window-report)
    raw=$1 out=$2
    bash "$here/rd.sh" window-report "$raw" "$out"
    python3 -I - "$raw.cpu" "$out" "$EVAL_STATE/host.log" <<'PY'
import json, os, re, sys
out = json.load(open(sys.argv[2]))
extra = out.setdefault("extra", {})
if os.path.exists(sys.argv[1]):
    cpu = json.load(open(sys.argv[1]))
    if cpu.get("wall_ms"):
        extra["process_cpu_pct"] = round(cpu["cpu_ms"] / cpu["wall_ms"] * 100, 2)
m = re.search(r"capturing (window \d+ \(\d+x\d+ px)", open(sys.argv[3]).read()) if os.path.exists(sys.argv[3]) else None
extra["captured"] = m.group(1) + ")" if m else None
json.dump(out, open(sys.argv[2], "w"))
PY
    ;;
  *) echo "rd-window.sh: unknown verb $verb" >&2; exit 2 ;;
esac
