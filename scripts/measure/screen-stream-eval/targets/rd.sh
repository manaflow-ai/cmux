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

host_start() {
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$EVAL_STATE/token"
  chmod 600 "$EVAL_STATE/token"
  : >"$EVAL_STATE/host.log"
  "$rd" host --owner owner --bind 127.0.0.1 --port "$port" --token-fd 3 3<"$EVAL_STATE/token" \
    >>"$EVAL_STATE/host.log" 2>&1 &
  echo $! >"$EVAL_STATE/host.pid"
  for _ in $(seq 1 100); do
    grep -q listening "$EVAL_STATE/host.log" && return 0
    kill -0 "$(cat "$EVAL_STATE/host.pid")" 2>/dev/null || break
    sleep 0.1 # bounded wait for the host's listening line (10 s)
  done
  echo "rd: the host did not start listening" >&2
  tail -20 "$EVAL_STATE/host.log" >&2
  return 1
}

bench() {
  "$rd" bench --addr "127.0.0.1:$port" --user owner --token-fd 3 "$@" 3<"$EVAL_STATE/token"
}

case "$verb" in
  build)
    # From cmux-tui, so rustup takes its rust-toolchain.toml: rustup reads the cwd, not the manifest's
    # folder, and a fleet worker's shared RUSTUP_HOME keeps no default toolchain on purpose
    # (scripts/build-cmux-cua.sh says why).
    (cd "$EVAL_ROOT/cmux-tui" && cargo build --release --manifest-path "$crate/Cargo.toml" --bin cmux-rd)
    cp "$crate/target/release/cmux-rd" "$rd"
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
    # latency INPUT SAMPLES OUT: INPUT is key or pointer (a click on the marker's pad).
    input=$1 samples=$2 out=$3
    geometry=$(grep -m1 marker-origin "$EVAL_MARKER_LOG")
    origin=${geometry#marker-origin }
    origin=${origin%% *}
    at=${geometry##*click-at }
    kind=key
    [[ $input == pointer ]] && kind=click
    bench --input "$kind" --at "$at" --marker-origin "$origin" --samples "$samples" \
      2>"$EVAL_STATE/latency-$input.err" | tail -1 >"$EVAL_STATE/latency-$input.raw.json"
    python3 -I - "$EVAL_STATE/latency-$input.raw.json" "$out" <<'EOF'
import json, sys
raw = json.load(open(sys.argv[1]))
g2g, cap, dec = raw.get("g2g_ms") or {}, raw.get("same_clock_capture_to_decoded_ms") or {}, raw.get("decode_ms") or {}
encode = (raw.get("host_stats_last") or {}).get("encode_ms_p50")
def p50(d): return d.get("p50") if d else None
transport = None
if p50(cap) is not None and encode is not None and p50(dec) is not None:
    transport = p50(cap) - encode - p50(dec)
json.dump({
    "g2g_ms": g2g, "lost": raw.get("lost"),
    "split": {"input_to_capture_ms": p50(raw.get("same_clock_input_to_capture_ms") or {}),
              "encode_ms": encode, "transport_ms": transport, "decode_ms": p50(dec),
              "method": "rd: transport = same-clock capture-to-decoded p50 minus the host's encode p50 and the viewer's decode p50 (packetize, send, reassemble and queue; a difference of medians, so it can be slightly negative)"},
    "raw": raw,
}, open(sys.argv[2], "w"))
EOF
    ;;
  window)
    # window SECONDS SNAPSHOT GO_FILE OUT: a passive viewer; GO_FILE once the first frame shows.
    seconds=$1 snapshot=$2 go=$3 out=$4
    ppm="$EVAL_STATE/snapshot.ppm"
    bench --input none --duration-s "$seconds" --snapshot "$ppm" \
      >"$EVAL_STATE/window.raw.json" 2>"$EVAL_STATE/window.err" &
    pid=$!
    for _ in $(seq 1 200); do
      grep -q 'passive: first frame' "$EVAL_STATE/window.err" && break
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1 # bounded wait for the first frame (20 s)
    done
    touch "$go"
    wait "$pid"
    cp "$ppm" "$snapshot"
    python3 -I - "$EVAL_STATE/window.raw.json" "$out" <<'EOF'
import json, sys
raw = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
series = [{"unix_ms": s["unix_ms"], "bytes": s["bytes"], "frames": s["frames"],
           "decode_ms": (s.get("decode_ms") or {}).get("p50"),
           "encode_ms": (s.get("host_stats") or {}).get("encode_ms_p50")} for s in raw["series"]]
json.dump({"series": series, "extra": {"decode_errors": raw.get("decode_errors"), "client_cpu_pct": raw.get("client_cpu_pct"),
                                       "welcome": raw.get("welcome"), "ended": raw.get("ended")}}, open(sys.argv[2], "w"))
EOF
    ;;
  *) echo "rd.sh: unknown verb $verb" >&2; exit 2 ;;
esac
