#!/usr/bin/env bash
# Screen stream eval target: cmux.rd/1 (cmux-tui/crates/cmux-rd-host, the Mac viewer's path), with
# the host at its defaults (no flags beyond loopback) and `cmux-rd bench` as the viewer
# (VideoToolbox decode, the viewer pane's decoder). The interface every target implements is in
# ../README.md; the harness (../../screen-stream-eval.sh) sets EVAL_ROOT, EVAL_BIN, EVAL_STATE and
# EVAL_MARKER_LOG.
set -euo pipefail
verb=$1
shift
crate="$EVAL_ROOT/cmux-tui/crates/cmux-rd-host"
rd="$EVAL_BIN/cmux-rd"
port=4103
netem_port=4104

record_pid() {
  local pid=$1 file=$2
  echo "$pid" >"$file"
  LC_ALL=C ps -p "$pid" -o lstart= >"$file.start" || true
}

same_pid() {
  local file=$1 pid=$2 expected actual
  expected=$(cat "$file.start" 2>/dev/null) || return 1
  [[ -n "$expected" ]] || return 1
  actual=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  [[ "$actual" == "$expected" ]]
}

stop_pid() {
  local file=$1
  [[ -f "$file" ]] || return 0
  local pid
  pid=$(cat "$file")
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  # A reused PID is not the child this run recorded. Never signal it.
  if ! same_pid "$file" "$pid"; then
    rm -f "$file" "$file.start"
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    if ! kill -0 "$pid" 2>/dev/null || ! same_pid "$file" "$pid"; then
      rm -f "$file" "$file.start"
      return 0
    fi
    sleep 0.1
  done
  if same_pid "$file" "$pid" && kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$file" "$file.start"
}

now_ms() {
  python3 -c 'import time; print(time.time_ns() // 1_000_000)'
}

host_start() {
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$EVAL_STATE/token"
  chmod 600 "$EVAL_STATE/token"
  : >"$EVAL_STATE/host.log"
  # Two Macs (EVAL_BIND, a LAN address): the host's own opt-in for a private network, else loopback only.
  host_flags=()
  [[ -n "${EVAL_BIND:-}" ]] && host_flags=(--single-tenant-overlay 1)
  [[ "${EVAL_RD_INPUT_FRAME_NOW:-0}" == 1 ]] && host_flags+=(--input-frame-now 1)
  [[ "${EVAL_RD_LTR:-0}" == 1 ]] && host_flags+=(--ltr 1)
  # A variant target's own host flags (rd-ladder.sh), space-separated.
  if [[ -n "${EVAL_RD_HOST_FLAGS:-}" ]]; then
    read -ra extra <<<"$EVAL_RD_HOST_FLAGS"
    host_flags+=("${extra[@]}")
  fi
  : >"$EVAL_STATE/timing.jsonl"
  rm -f "$EVAL_STATE/timing.offset"
  mkdir -p "$EVAL_STATE/quality"
  chmod 700 "$EVAL_STATE/quality"
  CMUX_RD_EVAL_QUALITY="$EVAL_STATE/quality" CMUX_RD_TIMING_LOG="$EVAL_STATE/timing.jsonl" "$rd" host --owner owner --bind "${EVAL_BIND:-127.0.0.1}" ${host_flags[@]+"${host_flags[@]}"} --port "$port" \
    --token-fd 3 3< <(cat "$EVAL_STATE/token") >>"$EVAL_STATE/host.log" 2>&1 &
  record_pid "$!" "$EVAL_STATE/host.pid"
  for _ in $(seq 1 100); do
    if grep -q listening "$EVAL_STATE/host.log"; then
      if netem_start; then
        return 0
      fi
      stop_pid "$EVAL_STATE/host.pid"
      return 1
    fi
    kill -0 "$(cat "$EVAL_STATE/host.pid")" 2>/dev/null || break
    sleep 0.1 # bounded wait for the host's listening line (10 s)
  done
  echo "rd: the host did not start listening" >&2
  tail -20 "$EVAL_STATE/host.log" >&2
  return 1
}

netem_start() {
  [[ -n "${EVAL_NETEM_RTT_MS:-}" ]] || return 0
  [[ -z "${EVAL_BIND:-}" || "${EVAL_BIND}" == 127.0.0.1 ]] || {
    echo "rd: netem is supported only for the local loopback target (EVAL_BIND=${EVAL_BIND})" >&2
    return 1
  }
  [[ -z "${EVAL_PEER:-}" || "${EVAL_PEER}" == 127.0.0.1 ]] || {
    echo "rd: netem is supported only for the local loopback target (EVAL_PEER=${EVAL_PEER})" >&2
    return 1
  }
  : >"$EVAL_STATE/netem.log"
  python3 -I "$EVAL_ROOT/scripts/measure/screen-stream-eval/netem.py" \
    --listen-host 127.0.0.1 --listen-port "$netem_port" \
    --upstream-host 127.0.0.1 --upstream-port "$port" \
    --rtt-ms "$EVAL_NETEM_RTT_MS" --loss-pct "${EVAL_NETEM_LOSS_PCT:-0}" \
    --seed "${EVAL_NETEM_SEED:-1}" --stats-path "$EVAL_STATE/netem-stats.json" >>"$EVAL_STATE/netem.log" 2>&1 &
  record_pid "$!" "$EVAL_STATE/netem.pid"
  for _ in $(seq 1 100); do
    grep -q 'netem: listening' "$EVAL_STATE/netem.log" && return 0
    kill -0 "$(cat "$EVAL_STATE/netem.pid")" 2>/dev/null || break
    sleep 0.1
  done
  echo "rd: netem relay did not start" >&2
  tail -20 "$EVAL_STATE/netem.log" >&2
  stop_pid "$EVAL_STATE/netem.pid"
  return 1
}

bench() {
  local bench_port=$port
  local eval_flags=()
  if [[ -z "${EVAL_PEER:-}" || "${EVAL_PEER}" == 127.0.0.1 ]]; then
    eval_flags+=(--eval-local 1)
  fi
  if [[ -n "${EVAL_NETEM_RTT_MS:-}" ]]; then
    bench_port=$netem_port
    eval_flags+=(--eval-netem-relay 1)
  fi
  # A variant target's own viewer flags (rd-ladder.sh), space-separated.
  if [[ -n "${EVAL_RD_BENCH_FLAGS:-}" ]]; then
    read -ra extra <<<"$EVAL_RD_BENCH_FLAGS"
    eval_flags+=("${extra[@]}")
  fi
  CMUX_RD_EVAL_QUALITY="$EVAL_STATE/quality" "$rd" bench ${eval_flags[@]+"${eval_flags[@]}"} --addr "${EVAL_PEER:-127.0.0.1}:$bench_port" --user owner --token-fd 3 "$@" 3< <(cat "$EVAL_STATE/token")
}

case "$verb" in
  # The numbers every rd run owes (eval.py OWED): the OCR error and the encoder's skips; the budget
  # bits per pixel too with the resolution ladder on (rd-ladder.sh), the only host that logs it.
  caps)
    printf 'owes-ocr\nowes-skips\n'
    [[ " ${EVAL_RD_HOST_FLAGS:-} " == *" --resolution-ladder "* ]] && echo owes-budget-bpp
    exit 0
    ;;
  build)
    if [[ -n "${EVAL_PREBUILT:-}" ]]; then
      cp "$EVAL_PREBUILT/cmux-rd" "$rd"
      exit 0
    fi
    # From cmux-tui, so rustup takes its rust-toolchain.toml: rustup reads the cwd, not the manifest's
    # folder, and a fleet worker's shared RUSTUP_HOME keeps no default toolchain on purpose
    # (scripts/build-cmux-cua.sh says why).
    (cd "$EVAL_ROOT/cmux-tui" && cargo build --release --manifest-path "$crate/Cargo.toml" --bin cmux-rd)
    cp "$crate/target/release/cmux-rd" "$rd"
    ;;
  host-start) host_start ;;
  host-stop)
    stop_pid "$EVAL_STATE/netem.pid"
    stop_pid "$EVAL_STATE/host.pid"
    ;;
  latency-view)
    # latency-view INPUT SAMPLES RAW: INPUT is key or pointer (a click on the marker's pad).
    input=$1 samples=$2 raw=$3
    geometry=$(grep -m1 marker-origin "$EVAL_MARKER_LOG")
    origin=${geometry#marker-origin }
    origin=${origin%% *}
    at=${geometry##*click-at }
    kind=key
    [[ $input == pointer ]] && kind=click
    bench --input "$kind" --at "$at" --marker-origin "$origin" --samples "$samples" \
      2>"$EVAL_STATE/latency-$input.err" | tail -1 >"$raw"
    ;;
  latency-report)
    # latency-report INPUT RAW OUT. bench's "same clock" times compare the host's capture time with the
    # viewer's: on two Macs they move onto the viewer's clock by the host-minus-viewer CLOCK_MONOTONIC
    # offset (EVAL_PEER_MONO_OFFSET_MS, peer.py).
    # The host's timing log since the last report splits input-to-capture by the frames that followed
    # an input. The host appends to it while this runs, so the report never copies or empties it: it
    # reads the complete lines after the byte offset the last report left in timing.offset.
    input=$1 raw=$2 out=$3
    python3 -I - "$raw" "$out" "${EVAL_PEER_MONO_OFFSET_MS:-0}" "$EVAL_STATE/timing.jsonl" "$EVAL_STATE/timing.offset" <<'EOF'
import json, os, sys
text = open(sys.argv[1]).read().strip()
raw = json.loads(text) if text else {}
offset = float(sys.argv[3])
frames = []
if os.path.exists(sys.argv[4]):
    start = int(open(sys.argv[5]).read() or 0) if os.path.exists(sys.argv[5]) else 0
    with open(sys.argv[4], "rb") as log:
        log.seek(start)
        chunk = log.read()
    whole = chunk[: chunk.rfind(b"\n") + 1]  # a line the host is still writing waits for the next report
    for line in whole.splitlines():
        try:
            frames.append(json.loads(line))
        except ValueError:
            pass
    open(sys.argv[5], "w").write(str(start + len(whole)))
def pct(values, signed=False):
    values = sorted(v for v in values if v is not None and (signed or v >= 0))
    if not values:
        return None
    return {"n": len(values), "p50": round(values[len(values) // 2], 3), "p95": round(values[min(len(values) - 1, int(len(values) * 0.95))], 3)}
def span(f, a, b):
    return (f[b] - f[a]) / 1000 if f.get(a) is not None and f.get(b) is not None else None
after_input = [f for f in frames if f.get("input_us") is not None]
# Where input-to-capture goes, for the first frame after each injected input: render (the input until
# the vsync the window server composited the change for: ScreenCaptureKit's display time), sck
# (signed: the frame reaching the capture callback after that vsync; negative when it arrives before
# the vsync, which is usual), to_arrived (the input until the callback: app, window server and
# ScreenCaptureKit together), pickup (the session loop seeing its damage), gate (the frame gate
# holding it until its interval allows), arrived_to_release (pickup and gate: the callback until the
# encode starts), each as p50/p95 ms on the host's own clock.
signed_parts = {"sck_ms"}
parts = {name: pct((span(f, a, b) for f in after_input), name in signed_parts) for name, a, b in (
    ("render_ms", "input_us", "shown_us"), ("sck_ms", "shown_us", "arrived_us"),
    ("to_arrived_ms", "input_us", "arrived_us"),
    ("pickup_ms", "arrived_us", "damage_us"), ("gate_ms", "damage_us", "release_us"),
    ("arrived_to_release_ms", "arrived_us", "release_us"),
    ("encode_ms", "release_us", "encoded_us"))}
# The same display-to-arrival offset over every frame, not only the first after an input.
parts["sck_all_frames_ms"] = pct((span(f, "shown_us", "arrived_us") for f in frames), signed=True)
# The marker's own draw commits (`commit COUNTER T_US`, protocol clock) split render in two: draw
# (the input until the marker committed its redraw: event delivery and the app's draw) and
# commit_to_vsync (signed: that commit until the frame's display time; negative when the frame
# predates the commit, counted in frame_before_commit). Each input's commit is the first one after
# it, within 100 ms.
commits, refresh_hz = [], None
marker_log = os.environ.get("EVAL_MARKER_LOG")
if marker_log and os.path.exists(marker_log):
    for line in open(marker_log, errors="replace"):
        words = line.split()
        if len(words) == 3 and words[0] == "commit" and words[2].isdigit():
            commits.append(int(words[2]))
        elif len(words) == 2 and words[0] == "refresh-hz" and words[1].isdigit():
            refresh_hz = int(words[1])
commits.sort()
import bisect
for f in after_input:
    i = bisect.bisect_left(commits, f["input_us"])
    if i < len(commits) and commits[i] - f["input_us"] <= 100_000:
        f["commit_us"] = commits[i]
parts["draw_ms"] = pct(span(f, "input_us", "commit_us") for f in after_input)
parts["commit_to_vsync_ms"] = pct((span(f, "commit_us", "shown_us") for f in after_input), signed=True)
parts["frame_before_commit"] = sum(1 for f in after_input if (span(f, "commit_us", "shown_us") or 0) < 0)
parts["refresh_hz"] = refresh_hz
g2g, cap, dec = raw.get("g2g_ms") or {}, raw.get("same_clock_capture_to_decoded_ms") or {}, raw.get("decode_ms") or {}
encode = (raw.get("host_stats_last") or {}).get("encode_ms_p50")
def p50(d): return d.get("p50") if d else None
to_capture = p50(raw.get("same_clock_input_to_capture_ms") or {})
to_capture = to_capture - offset if to_capture is not None else None
transport = None
if p50(cap) is not None and encode is not None and p50(dec) is not None:
    transport = p50(cap) + offset - encode - p50(dec)
json.dump({
    "g2g_ms": g2g, "lost": raw.get("lost"),
    "split": {"input_to_capture_ms": to_capture, "input_to_capture_parts": parts,
              "encode_ms": encode, "transport_ms": transport, "decode_ms": p50(dec),
              "method": "rd: transport = same-clock capture-to-decoded p50 minus the host's encode p50 and the viewer's decode p50 (packetize, send, reassemble and queue; a difference of medians, so it can be slightly negative); on two Macs the host's capture times move onto the viewer's clock by the measured offset"},
    "raw": raw,
}, open(sys.argv[2], "w"))
EOF
    ;;
  window-view)
    # window-view SECONDS SNAPSHOT GO RAW: a passive viewer; GO once the first frame shows.
    seconds=$1 snapshot=$2 go=$3 raw=$4
    ppm="$EVAL_STATE/snapshot.ppm"
    rm -f "$ppm"
    start_ms=$(now_ms)
    export EVAL_WINDOW_START_MS="$start_ms"
    bench --input none --duration-s "$seconds" --snapshot "$ppm" \
      >"$raw" 2>"$EVAL_STATE/window.err" &
    pid=$!
    for _ in $(seq 1 200); do
      if grep -q 'passive: first frame' "$EVAL_STATE/window.err"; then
        first_ms=$(now_ms)
        echo $((first_ms - start_ms)) >"$raw.first"
        break
      fi
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1 # bounded wait for the first frame (20 s)
    done
    touch "$go"
    wait "$pid"
    if [[ -s "$ppm" ]]; then cp "$ppm" "$snapshot"; fi
    ;;
  window-report)
    # window-report RAW OUT: the per-second rows on the host's wall clock (EVAL_PEER_WALL_OFFSET_MS).
    raw=$1 out=$2
    if [[ -f "$EVAL_STATE/netem.pid" ]]; then
      netem_pid=$(cat "$EVAL_STATE/netem.pid")
      if same_pid "$EVAL_STATE/netem.pid" "$netem_pid"; then
        kill -USR1 "$netem_pid"
      fi
    fi
    python3 -I - "$raw" "$out" "${EVAL_PEER_WALL_OFFSET_MS:-0}" <<'EOF'
import json, os, sys
lines = open(sys.argv[1]).read().strip().splitlines()
if not lines:
    sys.exit("rd: the window viewer printed no report")
raw = json.loads(lines[-1])
offset = float(sys.argv[3])
series = [{"unix_ms": round(s["unix_ms"] + offset), "bytes": s["bytes"], "frames": s["frames"],
           "duration_ms": s.get("duration_ms", 1000),
           "decode_ms": (s.get("decode_ms") or {}).get("p50"),
           "encode_ms": (s.get("host_stats") or {}).get("encode_ms_p50")} for s in raw["series"]]
first = None
try:
    if os.path.exists(sys.argv[1] + ".first"):
        first = max(0, int(open(sys.argv[1] + ".first").read().strip()))
except (ValueError, OSError):
    first = None
json.dump({"series": series, "extra": {"first_frame_ms": first, "cpu_pct": raw.get("client_cpu_pct"),
                                       "decode_errors": raw.get("decode_errors"), "client_cpu_pct": raw.get("client_cpu_pct"),
                                       "welcome": raw.get("welcome"), "ended": raw.get("ended")}}, open(sys.argv[2], "w"))
EOF
    python3 -I "$EVAL_ROOT/scripts/measure/screen-stream-eval/rd-metrics.py" \
      "$raw" "$out" "$EVAL_STATE/timing.jsonl"
    ;;
  *) echo "rd.sh: unknown verb $verb" >&2; exit 2 ;;
esac
