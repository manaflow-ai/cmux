#!/usr/bin/env bash
# Screen stream eval target: WebRTC (Packages/Shared/CmuxVNCWebRTC ScreenStreamHost, the iPhone's
# path): `cmux-vnc-host --capture` at its defaults, signaling through the default device hub, and
# the package's own test viewers (RdMarkerClickLatencyTests for latency, StreamWindowTests for a
# passive window) as the viewer. The interface every target implements is in ../README.md.
set -euo pipefail
verb=$1
shift
package="$EVAL_ROOT/Packages/Shared/CmuxVNCWebRTC"

host_start() {
  # Its pairing (a secret) lives in a home of its own inside the target's state directory.
  mkdir -p "$EVAL_STATE/home"
  chmod 700 "$EVAL_STATE/home"
  : >"$EVAL_STATE/host.log"
  CFFIXED_USER_HOME="$EVAL_STATE/home" HOME="$EVAL_STATE/home" \
    "$EVAL_BIN/cmux-vnc-host" --capture --name "screen stream eval" >>"$EVAL_STATE/host.log" 2>&1 &
  echo $! >"$EVAL_STATE/host.pid"
  for _ in $(seq 1 300); do
    grep -q "waiting for a viewer" "$EVAL_STATE/host.log" && return 0
    kill -0 "$(cat "$EVAL_STATE/host.pid")" 2>/dev/null || break
    sleep 0.1 # bounded wait for the host's ready line (30 s: it registers with the device hub)
  done
  echo "webrtc: the host did not get ready" >&2
  tail -20 "$EVAL_STATE/host.log" >&2
  return 1
}

link() { grep -m1 -o 'cmux-vnc://pair[^ ]*' "$EVAL_STATE/host.log"; }

# viewer FILTER LOG: one test viewer from the built test bundle, with the caller's env.
viewer() {
  CMUX_VNC_STREAM_LINK=$(link) swift test --skip-build --package-path "$package" --filter "$1" >"$2" 2>&1
}

# The host's `video:` lines (every 3 s) carry libwebrtc's encode time averaged since the stream
# started and the frames encoded so far; a watcher stamps each with the Unix ms it appeared at
# (encode.jsonl), and per_interval turns consecutive lines into each interval's own mean.
watch_encode() {
  python3 -I -u -c '
import json, os, re, sys, time
path, parent = sys.argv[1], os.getppid()
with open(path) as log:
    log.seek(0, os.SEEK_END)
    while os.getppid() == parent:  # ends with the target script that started it
        line = log.readline()
        if not line:
            time.sleep(0.2)  # follow the host log
            continue
        m = re.search(r" encoded (\d+) .* encode ([0-9.]+) ms ", line)
        if m:
            print(json.dumps({"unix_ms": int(time.time() * 1000), "encoded": int(m.group(1)), "mean_ms": float(m.group(2))}), flush=True)
' "$EVAL_STATE/host.log" >"$EVAL_STATE/encode.jsonl" &
  echo $! >"$EVAL_STATE/encode-watch.pid"
}
stop_watch() {
  [[ -f "$EVAL_STATE/encode-watch.pid" ]] && kill "$(cat "$EVAL_STATE/encode-watch.pid")" 2>/dev/null || true
  rm -f "$EVAL_STATE/encode-watch.pid"
}

case "$verb" in
  build)
    swift build -c release --package-path "$package" --product cmux-vnc-host
    cp "$(swift build -c release --package-path "$package" --show-bin-path)/cmux-vnc-host" "$EVAL_BIN/cmux-vnc-host"
    swift build --package-path "$package" --build-tests
    ;;
  host-start) host_start ;;
  host-stop)
    if [[ -f "$EVAL_STATE/host.pid" ]]; then
      pid=$(cat "$EVAL_STATE/host.pid")
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 50); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1 # bounded wait for the host to exit and free its port or room (5 s)
      done
      kill -9 "$pid" 2>/dev/null || true
      rm -f "$EVAL_STATE/host.pid"
    fi
    ;;
  latency)
    input=$1 samples=$2 out=$3
    # The marker logs its geometry in cmux.rd stream pixels (that stream is capped at 3840 px wide)
    # and in points. The WebRTC host captures the display at its native size, so the reader gets
    # fractions of the frame, which do not depend on either stream's scale: one cell is cell_pt
    # over the display's width in points, and the marker's top is its rd origin over the rd height.
    geometry=$(grep -m1 "stream width" "$EVAL_MARKER_LOG")
    width=${geometry#*stream width }
    width=${width%% *}
    cell=${geometry#*cell }
    cell=${cell%% pt*}
    origin=$(grep -m1 marker-origin "$EVAL_MARKER_LOG")
    top=${origin#marker-origin 0,}
    top=${top%% *}
    display=${geometry#*display \(}
    display=${display%\)*}
    fractions=$(python3 -I -c '
import sys
width, cell, top = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
dw, dh = map(float, sys.argv[4].split(","))
print(cell / dw, top / (int(width * dh / dw) & ~1))' "$width" "$cell" "$top" "$display")
    cell_fraction=${fractions% *}
    origin_fraction=${fractions#* }
    kind=key
    [[ $input == pointer ]] && kind=click
    watch_encode
    CMUX_RD_MARKER_CELL_FRACTION=$cell_fraction CMUX_RD_MARKER_ORIGIN_Y=$origin_fraction \
      CMUX_RD_MARKER_SAMPLES=$samples CMUX_RD_MARKER_INPUT=$kind \
      viewer RdMarkerClickLatencyTests "$EVAL_STATE/latency-$input.log" || true
    stop_watch
    sed -n 's/^rdmarker: //p' "$EVAL_STATE/latency-$input.log" | tail -1 >"$EVAL_STATE/latency-$input.raw.json"
    python3 -I - "$EVAL_STATE/latency-$input.raw.json" "$out" "$EVAL_STATE/encode.jsonl" <<'EOF'
import json, sys
text = open(sys.argv[1]).read().strip()
raw = json.loads(text) if text else {}
lines = [json.loads(l) for l in open(sys.argv[3]) if l.strip()]
# The run's own encode mean: the first and last cumulative lines' difference.
encode = None
if len(lines) >= 2 and lines[-1]["encoded"] > lines[0]["encoded"]:
    a, b = lines[0], lines[-1]
    encode = (b["mean_ms"] * b["encoded"] - a["mean_ms"] * a["encoded"]) / (b["encoded"] - a["encoded"])
rtt, jitter = raw.get("rtt_ms"), raw.get("jitter_buffer_ms")
transport = rtt / 2 + max(jitter, 0) if isinstance(rtt, (int, float)) and rtt >= 0 and isinstance(jitter, (int, float)) else None
decode = raw.get("decode_ms_mean")
json.dump({
    "g2g_ms": raw.get("g2g_ms") or {}, "lost": raw.get("lost"),
    "split": {"input_to_capture_ms": None, "encode_ms": encode, "transport_ms": transport,
              "decode_ms": decode if isinstance(decode, (int, float)) and decode >= 0 else None,
              "method": "webrtc: encode = host totalEncodeTime/framesEncoded over the run, transport = rtt/2 + the viewer's jitter buffer (mostly playout delay on loopback), decode = viewer totalDecodeTime/framesDecoded over the run"},
    "raw": raw,
}, open(sys.argv[2], "w"))
EOF
    ;;
  window)
    seconds=$1 snapshot=$2 go=$3 out=$4
    watch_encode
    log="$EVAL_STATE/window.log"
    : >"$log"
    CMUX_EVAL_WINDOW_S=$seconds CMUX_EVAL_SNAPSHOT=$snapshot viewer StreamWindowTests "$log" &
    pid=$!
    for _ in $(seq 1 600); do
      grep -q 'streamwindow: first frame' "$log" && break
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1 # bounded wait for the first frame (60 s: the test viewer starts, then connects)
    done
    touch "$go"
    wait "$pid" || true
    stop_watch
    python3 -I - "$log" "$out" "$EVAL_STATE/encode.jsonl" <<'EOF'
import json, sys
lines = [l[len("streamwindow: "):] for l in open(sys.argv[1]) if l.startswith("streamwindow: {")]
if not lines:
    sys.exit("webrtc: the window viewer printed no report")
raw = json.loads(lines[-1])
# Each 3 s interval's own encode mean, from consecutive cumulative lines, given to the seconds it covers.
stamps = [json.loads(l) for l in open(sys.argv[3]) if l.strip()]
intervals = []
for a, b in zip(stamps, stamps[1:]):
    if b["encoded"] > a["encoded"]:
        intervals.append((a["unix_ms"], b["unix_ms"], (b["mean_ms"] * b["encoded"] - a["mean_ms"] * a["encoded"]) / (b["encoded"] - a["encoded"])))
def encode_at(ms):
    return next((v for start, end, v in intervals if start < ms <= end), None)
series = [{"unix_ms": s["unix_ms"], "bytes": s["bytes"], "frames": s["frames"],
           "decode_ms": s["decode_ms_mean"] if s["decode_ms_mean"] >= 0 else None,
           "encode_ms": encode_at(s["unix_ms"]), "rtt_ms": s.get("rtt_ms"), "jitter_buffer_ms": s.get("jitter_buffer_ms")} for s in raw["series"]]
json.dump({"series": series,
           "extra": {k: raw.get(k) for k in ("codec", "decoder", "packets_lost", "frames_dropped", "freezes")}}, open(sys.argv[2], "w"))
EOF
    ;;
  *) echo "webrtc.sh: unknown verb $verb" >&2; exit 2 ;;
esac
