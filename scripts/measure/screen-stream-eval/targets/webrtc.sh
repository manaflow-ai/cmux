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

# The host's mean encode ms over its `video:` lines (every 3 s) since line FROM of its log.
encode_ms() {
  tail -n "+$1" "$EVAL_STATE/host.log" | sed -n 's/.* encode \([0-9.]*\) ms .*/\1/p' |
    python3 -I -c 'import sys, statistics; v=[float(x) for x in sys.stdin if x.strip()]; print(statistics.median(v) if v else "null")'
}

case "$verb" in
  build)
    swift build -c release --package-path "$package" --product cmux-vnc-host
    cp "$(swift build -c release --package-path "$package" --show-bin-path)/cmux-vnc-host" "$EVAL_BIN/cmux-vnc-host"
    swift build --package-path "$package" --build-tests
    ;;
  host-start) host_start ;;
  host-stop)
    [[ -f "$EVAL_STATE/host.pid" ]] && kill "$(cat "$EVAL_STATE/host.pid")" 2>/dev/null || true
    rm -f "$EVAL_STATE/host.pid"
    ;;
  latency)
    input=$1 samples=$2 out=$3
    # The marker reports its geometry in stream pixels at the display's full width (mac-compare.sh).
    geometry=$(grep -m1 "stream width" "$EVAL_MARKER_LOG")
    width=${geometry#*stream width }
    width=${width%% *}
    origin=$(grep -m1 marker-origin "$EVAL_MARKER_LOG")
    top=${origin#marker-origin 0,}
    top=${top%% *}
    display=${geometry#*display \(}
    display=${display%\)*}
    height=$(python3 -I -c 'import sys; w=float(sys.argv[1]); dw, dh = map(float, sys.argv[2].split(",")); print(int(w * dh / dw) & ~1)' "$width" "$display")
    kind=key
    [[ $input == pointer ]] && kind=click
    from=$(($(wc -l <"$EVAL_STATE/host.log") + 1))
    CMUX_RD_MARKER_CELL_FRACTION=$(python3 -I -c 'import sys; print(32/float(sys.argv[1]))' "$width") \
      CMUX_RD_MARKER_ORIGIN_Y=$(python3 -I -c 'import sys; print(int(sys.argv[1])/int(sys.argv[2]))' "$top" "$height") \
      CMUX_RD_MARKER_SAMPLES=$samples CMUX_RD_MARKER_INPUT=$kind \
      viewer RdMarkerClickLatencyTests "$EVAL_STATE/latency-$input.log" || true
    sed -n 's/^rdmarker: //p' "$EVAL_STATE/latency-$input.log" | tail -1 >"$EVAL_STATE/latency-$input.raw.json"
    python3 -I - "$EVAL_STATE/latency-$input.raw.json" "$out" "$(encode_ms "$from")" <<'EOF'
import json, sys
text = open(sys.argv[1]).read().strip()
raw = json.loads(text) if text else {}
encode = None if sys.argv[3] == "null" else float(sys.argv[3])
rtt, jitter = raw.get("rtt_ms"), raw.get("jitter_buffer_ms")
network = rtt / 2 + max(jitter, 0) if isinstance(rtt, (int, float)) and rtt >= 0 and isinstance(jitter, (int, float)) else None
decode = raw.get("decode_ms_mean")
json.dump({
    "g2g_ms": raw.get("g2g_ms") or {}, "lost": raw.get("lost"),
    "split": {"input_to_capture_ms": None, "encode_ms": encode, "network_ms": network,
              "decode_ms": decode if isinstance(decode, (int, float)) and decode >= 0 else None,
              "method": "libwebrtc stats: host encode = median of totalEncodeTime/framesEncoded per 3 s, network = rtt/2 + jitter buffer, decode = viewer totalDecodeTime/framesDecoded"},
    "raw": raw,
}, open(sys.argv[2], "w"))
EOF
    ;;
  window)
    seconds=$1 snapshot=$2 go=$3 out=$4
    from=$(($(wc -l <"$EVAL_STATE/host.log") + 1))
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
    python3 -I - "$log" "$out" "$(encode_ms "$from")" <<'EOF'
import json, sys
lines = [l[len("streamwindow: "):] for l in open(sys.argv[1]) if l.startswith("streamwindow: {")]
if not lines:
    sys.exit("webrtc: the window viewer printed no report")
raw = json.loads(lines[-1])
encode = None if sys.argv[3] == "null" else float(sys.argv[3])
series = [{"unix_ms": s["unix_ms"], "bytes": s["bytes"], "frames": s["frames"],
           "decode_ms": s["decode_ms_mean"] if s["decode_ms_mean"] >= 0 else None,
           "encode_ms": None, "rtt_ms": s.get("rtt_ms"), "jitter_buffer_ms": s.get("jitter_buffer_ms")} for s in raw["series"]]
json.dump({"series": series, "encode_ms_window": encode,
           "extra": {k: raw.get(k) for k in ("codec", "decoder", "packets_lost", "frames_dropped", "freezes")}}, open(sys.argv[2], "w"))
EOF
    ;;
  *) echo "webrtc.sh: unknown verb $verb" >&2; exit 2 ;;
esac
