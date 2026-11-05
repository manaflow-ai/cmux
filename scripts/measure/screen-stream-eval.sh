#!/usr/bin/env bash
# The screen stream eval (HQ#7146 G0): every stream target through the same fixed scenarios on one
# quiet Mac, host and viewer on that Mac, one table per target. Scenarios, schema and the target
# interface: scripts/measure/screen-stream-eval/README.md. Run alone on a console worker whose step
# processes hold Screen Recording and Accessibility:
#   cmux-ci run --class exclusive --measurement --label measure --label gui-session-v1 --script scripts/measure/screen-stream-eval.sh \
#     --ref SHA --artifact artifacts/screen-stream-eval/results.json [--target-worker W] \
#     [--arg=targets=rd,webrtc] [--arg=samples=200] --timeout 5400
# Output: SCREEN-STREAM-EVAL lines, the summary table, and artifacts/screen-stream-eval/results.json
# (also each target's raw files and the host and viewer frames under that folder). No gate: it
# reports, and exits non-zero only when it could not measure at all (3: no grant; 4: no target ran;
# 5: no target measured a window).
set -uo pipefail
targets="rd,webrtc" samples=200
for arg in "$@"; do
  case "$arg" in
    targets=*) targets="${arg#targets=}" ;;
    samples=*) samples="${arg#samples=}" ;;
    *) echo "screen-stream-eval.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$samples" =~ ^[0-9]+$ ]] || { echo "screen-stream-eval.sh: samples= is a number" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root"
here="$root/scripts/measure/screen-stream-eval"
out="$root/artifacts/screen-stream-eval"
work="$root/.build/screen-stream-eval"
rm -rf "$out" "$work"
mkdir -p "$out" "$work/bin"
chmod 700 "$work"
export EVAL_ROOT="$root" EVAL_BIN="$work/bin"

# The scene's timeline is 81 s from GO (scene.swift), then it holds the ocr screen until STOP; the
# passive window starts at the viewer's first frame, GO follows it, so the window ends inside the hold.
window_s=84
display=$(system_profiler SPDisplaysDataType 2>/dev/null | sed -n 's/^ *Resolution: //p' | head -1)
run_json() {
  python3 -I - "$@" <<'EOF'
import json, sys, datetime
keys = sys.argv[1::2]; values = sys.argv[2::2]
run = dict(zip(keys, values))
run["at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
run["link"] = "loopback: host and viewer on one Mac"
print(json.dumps(run))
EOF
}
run=$(run_json host "$(scutil --get ComputerName 2>/dev/null || hostname)" cpu "$(sysctl -n machdep.cpu.brand_string)" \
  macos "$(sw_vers -productVersion)" rev "$(git rev-parse HEAD)" display "$display" samples "$samples")
echo "SCREEN-STREAM-EVAL-MACHINE $run"

pids=()
cleanup() {
  for pid in ${pids[@]+"${pids[@]}"}; do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

# results.json from whatever the targets wrote; blocked=REASON marks a run that measured nothing.
finish() {
  local blocked="${1:-}"
  python3 -I - "$out" "$run" "$blocked" "$targets" <<'EOF'
import json, sys
from pathlib import Path
out, run, blocked, names = Path(sys.argv[1]), json.loads(sys.argv[2]), sys.argv[3], sys.argv[4].split(",")
if blocked:
    run["blocked"] = blocked
targets = {}
for name in names:
    path = out / name / "target.json"
    targets[name] = json.loads(path.read_text()) if path.exists() else {"ok": False, "errors": [blocked or "did not run"]}
results = {"schema": "cmux.screen-stream-eval/1", "run": run, "scenarios": ["idle", "typing", "scroll", "ocr"], "targets": targets}
(out / "results.json").write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")
EOF
  python3 -I "$here/eval.py" summary "$out/results.json" "$out/summary.md"
  cat "$out/summary.md"
}

echo "SCREEN-STREAM-EVAL-STAGE tools"
for tool in preflight scene ocr; do
  swiftc -O -o "$EVAL_BIN/screen-eval-$tool" "$here/$tool.swift" || { finish "could not build $tool.swift"; exit 4; }
done
swiftc -O -o "$EVAL_BIN/cmux-rd-marker" "$root/cmux-tui/crates/cmux-rd-host/scripts/mac-marker/main.swift" ||
  { finish "could not build the marker"; exit 4; }
grants=$("$EVAL_BIN/screen-eval-preflight")
echo "SCREEN-STREAM-EVAL-GRANTS $grants"
if ! grep -q '"accessibility":true' <<<"$grants" || ! grep -q '"screen_recording":true' <<<"$grants"; then
  finish "the step's processes lack Screen Recording or Accessibility on this worker ($grants)"
  exit 3
fi

ran=0
IFS=',' read -r -a names <<<"$targets"
for name in "${names[@]}"; do
  script="$here/targets/$name.sh"
  dir="$out/$name"
  mkdir -p "$dir"
  export EVAL_STATE="$work/$name"
  mkdir -p "$EVAL_STATE"
  chmod 700 "$EVAL_STATE"
  : >"$dir/errors.txt"
  err() { echo "$*" >>"$dir/errors.txt"; echo "SCREEN-STREAM-EVAL-ERROR $name $*"; }
  if [[ ! -f "$script" ]]; then
    err "no target script $script"
    python3 -I "$here/eval.py" target "$name" "$dir" "$dir/target.json"
    continue
  fi

  echo "SCREEN-STREAM-EVAL-STAGE $name build"
  if ! bash "$script" build >"$dir/build.log" 2>&1; then
    tail -40 "$dir/build.log"
    err "build failed (build.log)"
    python3 -I "$here/eval.py" target "$name" "$dir" "$dir/target.json"
    continue
  fi
  ran=1

  # Latency: the marker (cmux-rd-host/scripts/mac-marker) above everything, then the host.
  echo "SCREEN-STREAM-EVAL-STAGE $name latency"
  export EVAL_MARKER_LOG="$EVAL_STATE/marker.log"
  "$EVAL_BIN/cmux-rd-marker" --verbose >"$EVAL_MARKER_LOG" 2>&1 &
  marker=$!
  pids+=("$marker")
  for _ in $(seq 1 50); do
    grep -q marker-origin "$EVAL_MARKER_LOG" && break
    sleep 0.1 # bounded wait for the marker's geometry line (5 s)
  done
  if bash "$script" host-start; then
    # Pointer first: its click gives the marker key focus for the key run.
    for input in pointer key; do
      bash "$script" latency "$input" "$samples" "$dir/latency-$input.json" || err "latency $input failed"
    done
  else
    err "host did not start for latency"
  fi
  bash "$script" host-stop
  kill "$marker" 2>/dev/null || true
  wait "$marker" 2>/dev/null || true

  # Window: the scene's fixed timeline under one passive viewer.
  echo "SCREEN-STREAM-EVAL-STAGE $name window"
  go="$EVAL_STATE/go" stop="$EVAL_STATE/stop"
  rm -f "$go" "$stop" "$dir/host.png"
  "$EVAL_BIN/screen-eval-scene" "$go" "$stop" "$dir/phases.jsonl" "$dir/host.png" "$dir/truth.txt" >"$EVAL_STATE/scene.log" 2>&1 &
  scene=$!
  pids+=("$scene")
  sleep 2 # the scene's window is up before the host captures its first frame
  if bash "$script" host-start; then
    bash "$script" window "$window_s" "$dir/viewer-frame" "$go" "$dir/window.json" || err "window failed"
  else
    err "host did not start for the window"
  fi
  touch "$stop"
  wait "$scene" || err "scene exited $? ($(tail -1 "$EVAL_STATE/scene.log"))"
  bash "$script" host-stop

  echo "SCREEN-STREAM-EVAL-STAGE $name ocr"
  if [[ -s "$dir/host.png" && -s "$dir/viewer-frame" ]]; then
    "$EVAL_BIN/screen-eval-ocr" "$dir/host.png" "$dir/viewer-frame" "$dir/truth.txt" >"$dir/ocr.json" || err "ocr failed"
  else
    err "ocr: missing $( [[ -s "$dir/host.png" ]] || echo 'host screenshot ')$( [[ -s "$dir/viewer-frame" ]] || echo 'viewer frame')"
  fi
  # The logs, without the WebRTC host's pairing (its link and the QR code of it: the room secret).
  for log in "$EVAL_STATE"/*.log; do
    [[ -f "$log" ]] || continue
    grep -v -E 'cmux-vnc://|[█▀▄]' "$log" >"$dir/$(basename "$log")" || true
  done
  python3 -I "$here/eval.py" target "$name" "$dir" "$dir/target.json"
  echo "SCREEN-STREAM-EVAL-TARGET $name $(python3 -I -c 'import json,sys; t=json.load(open(sys.argv[1])); print(json.dumps({k: t[k] for k in ("ok", "latency", "kbps", "ocr")}))' "$dir/target.json")"
done

if [[ $ran == 0 ]]; then
  finish "no target built"
  exit 4
fi
finish
# A run with no window numbers at all is not a baseline a later run should diff against.
python3 -I -c 'import json, sys; t = json.load(open(sys.argv[1]))["targets"].values(); sys.exit(0 if any(v is not None for x in t for v in (x.get("kbps") or {}).values()) else 5)' "$out/results.json" || exit 5
exit 0
