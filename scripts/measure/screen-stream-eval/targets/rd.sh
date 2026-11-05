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
  # Two Macs (EVAL_BIND, a LAN address): the host's own opt-in for a private network, else loopback only.
  reach=()
  [[ -n "${EVAL_BIND:-}" ]] && reach=(--single-tenant-overlay 1)
  "$rd" host --owner owner --bind "${EVAL_BIND:-127.0.0.1}" ${reach[@]+"${reach[@]}"} --port "$port" \
    --token-fd 3 3< <(cat "$EVAL_STATE/token") >>"$EVAL_STATE/host.log" 2>&1 &
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
  "$rd" bench --addr "${EVAL_PEER:-127.0.0.1}:$port" --user owner --token-fd 3 "$@" 3< <(cat "$EVAL_STATE/token")
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
    input=$1 raw=$2 out=$3
    python3 -I - "$raw" "$out" "${EVAL_PEER_MONO_OFFSET_MS:-0}" <<'EOF'
import json, sys
text = open(sys.argv[1]).read().strip()
raw = json.loads(text) if text else {}
offset = float(sys.argv[3])
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
    "split": {"input_to_capture_ms": to_capture,
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
    bench --input none --duration-s "$seconds" --snapshot "$ppm" \
      >"$raw" 2>"$EVAL_STATE/window.err" &
    pid=$!
    for _ in $(seq 1 200); do
      grep -q 'passive: first frame' "$EVAL_STATE/window.err" && break
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
    python3 -I - "$raw" "$out" "${EVAL_PEER_WALL_OFFSET_MS:-0}" <<'EOF'
import json, sys
lines = open(sys.argv[1]).read().strip().splitlines()
if not lines:
    sys.exit("rd: the window viewer printed no report")
raw = json.loads(lines[-1])
offset = float(sys.argv[3])
series = [{"unix_ms": round(s["unix_ms"] + offset), "bytes": s["bytes"], "frames": s["frames"],
           "decode_ms": (s.get("decode_ms") or {}).get("p50"),
           "encode_ms": (s.get("host_stats") or {}).get("encode_ms_p50")} for s in raw["series"]]
json.dump({"series": series, "extra": {"decode_errors": raw.get("decode_errors"), "client_cpu_pct": raw.get("client_cpu_pct"),
                                       "welcome": raw.get("welcome"), "ended": raw.get("ended")}}, open(sys.argv[2], "w"))
EOF
    ;;
  *) echo "rd.sh: unknown verb $verb" >&2; exit 2 ;;
esac
