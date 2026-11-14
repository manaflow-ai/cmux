#!/usr/bin/env bash
# The view and report verbs for a third-party viewer: an app on the viewer Mac that cmux did not
# write (Moonlight, Screen Sharing.app, Windows App), measured from outside so every contender is
# timed the same way as cmux. A target sources this file and calls these with its viewer's process
# name once that viewer is connected and shows the host's display full screen on the main display.
#
# - Latency: `cmux-rd observe`, the protocol-agnostic glass-to-glass meter (cmux-rd-host
#   src/mac/observe.rs): it posts each key or click to the viewer's process and times it to the
#   ScreenCaptureKit frame of this display in which the host's marker counter changed. It ends at
#   the compositor, not the panel, like every other target's number. screen-eval-marker-locate finds
#   where the viewer draws the marker first.
# - Window rows: kbps from the viewer process's own received bytes (`nettop`, all its sockets, so
#   headers, FEC and retransmissions count, as rd's datagram count does); frames from what the
#   viewer presented, read by sampling its window 10 times a second (`sampled_changes`, a floor for
#   the frames it showed). The viewer's decode and encode times are not exposed: null.
# - OCR: the viewer window's last capture, against the host's screenshot.

gv_build() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -n "${EVAL_PREBUILT:-}" ]]; then
    for tool in cmux-rd screen-eval-window-id screen-eval-marker-locate; do
      cp "$EVAL_PREBUILT/$tool" "$EVAL_BIN/$tool" || { echo "gui-viewer: prebuilt= has no $tool" >&2; return 1; }
    done
    return 0
  fi
  bash "$here/targets/rd.sh" build
  swiftc -O -o "$EVAL_BIN/screen-eval-window-id" "$here/window-id.swift"
  swiftc -O -o "$EVAL_BIN/screen-eval-marker-locate" "$here/marker-locate.swift"
}

# gv_pid NAME: the viewer's process id (exit 1 when it is not running).
gv_pid() { pgrep -nx "$1"; }

# gv_wait_window NAME SECONDS: the viewer's largest on-screen window id, once it has one.
gv_wait_window() {
  local id
  for _ in $(seq 1 $(($2 * 10))); do
    if id=$("$EVAL_BIN/screen-eval-window-id" "$1" 2>/dev/null) && [[ "$id" =~ ^[0-9]+$ ]]; then
      echo "$id"
      return 0
    fi
    sleep 0.1 # bounded wait for the viewer's window (SECONDS)
  done
  return 1
}

# gv_latency NAME INPUT SAMPLES RAW: observe through the viewer; RAW gets observe's JSON with the
# marker's place on this display, or {"error"} when it could not run.
gv_latency() {
  local name=$1 input=$2 samples=$3 raw=$4 pid window place kind=key
  [[ $input == pointer ]] && kind=click
  pid=$(gv_pid "$name") || { printf '{"error":"%s is not running"}\n' "$name" >"$raw"; return 1; }
  window=$(gv_wait_window "$name" 30) || { printf '{"error":"%s has no window"}\n' "$name" >"$raw"; return 1; }
  # The marker's first frames take a moment to cross: retry the locate for 10 s.
  for _ in $(seq 1 20); do
    screencapture -x -D 1 "$EVAL_STATE/locate.png" 2>/dev/null &&
      place=$("$EVAL_BIN/screen-eval-marker-locate" "$EVAL_STATE/locate.png" 2>"$EVAL_STATE/locate.err") && break
    sleep 0.5 # bounded wait for the marker to show in the viewer (10 s)
  done
  if [[ -z "${place:-}" ]]; then
    printf '{"error":"no marker visible through %s (%s)"}\n' "$name" "$(tail -1 "$EVAL_STATE/locate.err" 2>/dev/null)" >"$raw"
    return 1
  fi
  # origin X,Y cell C at X,Y
  read -r _ origin _ cell _ at <<<"$place"
  echo "gui-viewer: $name pid $pid window $window marker $place" >>"$EVAL_STATE/view.log"
  if ! "$EVAL_BIN/cmux-rd" observe --pid "$pid" --window "$window" --input "$kind" --samples "$samples" \
    --cell-size "$cell" --marker-origin "$origin" --at "$at" >"$raw.observe" 2>"$EVAL_STATE/observe-$input.err"; then
    printf '{"error":"observe: %s"}\n' "$(tail -1 "$EVAL_STATE/observe-$input.err" | tr -d '"\\')" >"$raw"
    return 1
  fi
  cp "$raw.observe" "$raw"
}

# gv_latency_report INPUT RAW OUT METHOD: observe's JSON in the latency schema (../README.md).
gv_latency_report() {
  python3 -I - "$2" "$3" "$4" <<'EOF'
import json, sys
try:
    raw = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    raw = {"error": "no observe output"}
ok = raw.get("complete") is True
g2g = {"n": raw.get("n"), "p50": raw.get("p50_ms"), "p95": raw.get("p95_ms")} if ok else {}
json.dump({"g2g_ms": g2g, "lost": 0 if ok else None,
           "split": {"input_to_capture_ms": None, "encode_ms": None, "transport_ms": None, "decode_ms": None,
                     "method": sys.argv[3]},
           "raw": {k: v for k, v in raw.items() if k != "samples_us"}}, open(sys.argv[2], "w"))
if not ok:
    sys.exit(f"gui-viewer: {raw.get('error', 'observe did not complete')}")
EOF
}

# gv_window_view NAME SECONDS SNAPSHOT GO RAW: the passive window. GO once the viewer's window
# shows; then one row a second of the viewer's received bytes and its sampled frame changes.
gv_window_view() {
  local name=$1 seconds=$2 snapshot=$3 go=$4 raw=$5 pid window
  pid=$(gv_pid "$name") || { echo "gui-viewer: $name is not running" >&2; touch "$go"; return 1; }
  window=$(gv_wait_window "$name" 60) || { echo "gui-viewer: $name has no window" >&2; touch "$go"; return 1; }
  touch "$go"
  python3 -I - "$pid" "$window" "$seconds" "$snapshot" "$raw" "$EVAL_STATE" <<'EOF'
import hashlib, json, subprocess, sys, time
pid, window, seconds, snapshot, raw, state = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6]

def received() -> int | None:
    # nettop's one sample: a header, then `time,PROCESS.PID,BYTES_IN,` for the process, all its sockets.
    try:
        out = subprocess.run(["nettop", "-P", "-L", "1", "-n", "-x", "-J", "bytes_in", "-p", pid],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    for line in reversed(out.splitlines()):
        fields = line.split(",")
        if len(fields) >= 3 and fields[2].isdigit():
            return int(fields[2])
    return None

def cpu() -> float | None:
    out = subprocess.run(["ps", "-o", "%cpu=", "-p", pid], capture_output=True, text=True).stdout.strip()
    try:
        return float(out)
    except ValueError:
        return None

frame = f"{state}/window.png"
series, cpus, last_hash, changes, start = [], [], None, 0, time.time()
last_bytes, second_end = received(), start + 1
while time.time() < start + seconds:
    if subprocess.run(["screencapture", "-x", "-o", "-l", window, frame], capture_output=True).returncode == 0:
        digest = hashlib.sha256(open(frame, "rb").read()).hexdigest()
        changes += last_hash is not None and digest != last_hash
        last_hash = digest
    now = time.time()
    if now >= second_end:
        total = received()
        bytes_ = total - last_bytes if total is not None and last_bytes is not None else None
        series.append({"unix_ms": int(now * 1000), "bytes": bytes_, "frames": None, "sampled_changes": changes,
                       "decode_ms": None, "encode_ms": None})
        last_bytes, changes, second_end = total, 0, second_end + 1
        if (c := cpu()) is not None:
            cpus.append(c)
    time.sleep(max(0.0, 0.1 - (time.time() - now)))  # about 10 samples a second
subprocess.run(["screencapture", "-x", "-o", "-l", window, snapshot], capture_output=True)
json.dump({"series": series, "extra": {
    "viewer_cpu_pct": round(sum(cpus) / len(cpus), 1) if cpus else None,
    "bytes_method": "nettop bytes_in of the viewer process, all sockets",
    "frames_method": "frames not exposed; sampled_changes counts window captures (10/s) that differ from the last"}}, open(raw, "w"))
EOF
  [[ -s "$snapshot" ]] || { echo "gui-viewer: no window capture of $name" >&2; return 1; }
}

# gv_window_report RAW OUT: the rows on the host's wall clock (EVAL_PEER_WALL_OFFSET_MS).
gv_window_report() {
  python3 -I - "$1" "$2" "${EVAL_PEER_WALL_OFFSET_MS:-0}" <<'EOF'
import json, sys
raw = json.load(open(sys.argv[1]))
offset = float(sys.argv[3])
series = [{**row, "unix_ms": round(row["unix_ms"] + offset)} for row in raw.get("series") or []]
json.dump({"series": series, "extra": raw.get("extra") or {}}, open(sys.argv[2], "w"))
EOF
}
