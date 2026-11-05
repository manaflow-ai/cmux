#!/usr/bin/env bash
# The screen stream eval (HQ#7146 G0): every stream target through the same fixed scenarios on one
# quiet Mac, host and viewer on that Mac, one table per target. Scenarios, schema and the target
# interface: scripts/measure/screen-stream-eval/README.md. Run alone on a console worker whose step
# processes hold Screen Recording and Accessibility:
#   cmux-ci run --class exclusive --measurement --label measure --label gui-session-v1 --script scripts/measure/screen-stream-eval.sh \
#     --ref SHA --artifact artifacts/screen-stream-eval/results.json [--target-worker W] \
#     [--arg=targets=rd,webrtc] [--arg=samples=200] [--arg=repeats=3] --timeout 5400
# Output: SCREEN-STREAM-EVAL lines, the summary table, and artifacts/screen-stream-eval/results.json
# (also each target's raw files and the host and viewer frames under that folder). No gate: it
# reports, and exits non-zero only when it could not measure at all (3: no grant; 4: no target ran;
# 5: no target measured a window).
set -uo pipefail
targets="rd,webrtc" samples=200 repeats=3
for arg in "$@"; do
  case "$arg" in
    targets=*) targets="${arg#targets=}" ;;
    samples=*) samples="${arg#samples=}" ;;
    repeats=*) repeats="${arg#repeats=}" ;;
    *) echo "screen-stream-eval.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$samples" =~ ^[0-9]+$ ]] || { echo "screen-stream-eval.sh: samples= is a number" >&2; exit 2; }
[[ "$repeats" =~ ^[1-9][0-9]*$ ]] || { echo "screen-stream-eval.sh: repeats= is a number from 1" >&2; exit 2; }
# From the script's place, not the cwd: inside the launcher app (below) the cwd is /.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
  macos "$(sw_vers -productVersion)" rev "$(git rev-parse HEAD)" display "$display" samples "$samples" repeats "$repeats")
echo "SCREEN-STREAM-EVAL-MACHINE $run"

pids=()
cleanup() {
  for pid in ${pids[@]+"${pids[@]}"}; do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

# results.json from whatever the targets wrote; blocked=REASON marks a run that measured nothing.
finish() {
  local blocked="${1:-}"
  python3 -I - "$out" "$run" "$blocked" "$targets" "$here" <<'EOF'
import json, sys
from pathlib import Path
out, run, blocked, names = Path(sys.argv[1]), json.loads(sys.argv[2]), sys.argv[3], sys.argv[4].split(",")
sys.path.insert(0, sys.argv[5])
from eval import empty_target
if blocked:
    run["blocked"] = blocked
targets = {}
for name in names:
    path = out / name / "target.json"
    targets[name] = json.loads(path.read_text()) if path.exists() else empty_target([blocked or "did not run"])
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
granted() { grep -q '"accessibility":true' <<<"$1" && grep -q '"screen_recording":true' <<<"$1"; }
grants=$("$EVAL_BIN/screen-eval-preflight")
echo "SCREEN-STREAM-EVAL-GRANTS $grants"
if ! granted "$grants" && [[ -z "${CMUX_SCREEN_EVAL_IN_LAUNCHER:-}" ]]; then
  # The step's own processes hold no grants (a step's binaries change every commit). Run this whole
  # eval again inside CmuxScreenEvalLauncher.app (launcher/), a stable app granted once at the console,
  # whose children get its grants. Its files live outside $work, which the inner run starts by removing.
  launch="$root/.build/screen-stream-eval-launcher"
  rm -rf "$launch"
  mkdir -p "$launch"
  if app=$(bash "$here/launcher/install.sh" 2>"$launch/install.log"); then
    # --request also lists the app under Privacy & Security, where the grant is made.
    open -W -n -g -a "$app" --stdout "$launch/grants.json" --stderr "$launch/grants.err" --args --request \
      >"$launch/open.log" 2>&1 || echo "open exited $?" >>"$launch/open.log"
    grants=$(cat "$launch/grants.json" 2>/dev/null)
    echo "SCREEN-STREAM-EVAL-LAUNCHER app=$app grants=${grants:-none} open=$(tr '\n' ' ' <"$launch/open.log" | cut -c1-300) err=$(tr '\n' ' ' <"$launch/grants.err" 2>/dev/null | cut -c1-300)"
    if granted "$grants"; then
      # An app LaunchServices starts gets launchd's environment, not ours: pass what the build needs.
      env_args=()
      for var in PATH HOME TMPDIR USER LANG DEVELOPER_DIR CARGO_HOME RUSTUP_HOME $(compgen -e | grep -E '^CMUX_' || true); do
        [[ -n "${!var:-}" ]] && env_args+=(--env "$var=${!var}")
      done
      # The app ends the run when this process is gone (a killed step), and the step log follows its output.
      : >"$launch/out.log"
      tail -n +1 -F "$launch/out.log" &
      follow=$!
      pids+=("$follow")
      open -W -n -g -a "$app" --stdout "$launch/out.log" --stderr "$launch/err.log" ${env_args[@]+"${env_args[@]}"} \
        --env "CMUX_SCREEN_EVAL_PARENT=$$" --args "$root/scripts/measure/screen-stream-eval.sh" "$launch/status" "$@" || true
      sleep 1 # the last lines reach the follower
      kill "$follow" 2>/dev/null || true
      tail -n 80 "$launch/err.log" 2>/dev/null >&2
      status=$(cat "$launch/status" 2>/dev/null || echo 4)
      if [[ ! -s "$out/results.json" ]]; then
        mkdir -p "$out"
        finish "the run inside $app ended (status $status) without results ($(tail -1 "$launch/err.log" 2>/dev/null))"
        [[ "$status" == 0 ]] && status=4
      fi
      exit "$status"
    fi
    finish "this worker's step processes lack Screen Recording or Accessibility, and so does $app; grant both to it once at the console (System Settings > Privacy & Security, where it is listed) ($grants)"
  else
    finish "the step's processes lack Screen Recording or Accessibility, and the launcher app did not install ($(tail -1 "$launch/install.log"))"
  fi
  exit 3
fi
if ! granted "$grants"; then
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
  # host_start: the target's host-start, its own words kept (only results.json leaves the worker),
  # without the WebRTC host's pairing (its link and the QR code of it: the room secret).
  host_start() {
    bash "$script" host-start 2>"$EVAL_STATE/host-start.err" && return 0
    LC_ALL=en_US.UTF-8 grep -v -E 'cmux-vnc://|[█▀▄]' "$EVAL_STATE/host-start.err" | tail -8 | tr '\n' ' ' | cut -c1-600
    return 1
  }
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
  if why=$(host_start); then
    # Pointer first: its click gives the marker key focus for the key run.
    for input in pointer key; do
      bash "$script" latency "$input" "$samples" "$dir/latency-$input.json" || err "latency $input failed"
    done
  else
    err "host did not start for latency: $why"
  fi
  bash "$script" host-stop
  kill "$marker" 2>/dev/null || true
  wait "$marker" 2>/dev/null || true

  # Window and OCR: the scene's fixed timeline under one passive viewer, $repeats times (a fresh host
  # each time); eval.py reports each number's median and keeps every repeat's.
  for rep in $(seq 1 "$repeats"); do
    echo "SCREEN-STREAM-EVAL-STAGE $name window $rep/$repeats"
    go="$EVAL_STATE/go" stop="$EVAL_STATE/stop"
    rm -f "$go" "$stop" "$dir/host-$rep.png"
    "$EVAL_BIN/screen-eval-scene" "$go" "$stop" "$dir/phases-$rep.jsonl" "$dir/host-$rep.png" "$dir/truth.txt" >"$EVAL_STATE/scene.log" 2>&1 &
    scene=$!
    pids+=("$scene")
    sleep 2 # the scene's window is up before the host captures its first frame
    if why=$(host_start); then
      bash "$script" window "$window_s" "$dir/viewer-frame-$rep" "$go" "$dir/window-$rep.json" || err "window $rep failed"
    else
      err "host did not start for window $rep: $why"
      touch "$go" # lets the scene run out its timeline instead of waiting 120 s for GO
    fi
    touch "$stop"
    wait "$scene" || err "scene $rep exited $? ($(tail -1 "$EVAL_STATE/scene.log"))"
    bash "$script" host-stop

    echo "SCREEN-STREAM-EVAL-STAGE $name ocr $rep/$repeats"
    if [[ -s "$dir/host-$rep.png" && -s "$dir/viewer-frame-$rep" ]]; then
      "$EVAL_BIN/screen-eval-ocr" "$dir/host-$rep.png" "$dir/viewer-frame-$rep" "$dir/truth.txt" >"$dir/ocr-$rep.json" || err "ocr $rep failed"
    else
      err "ocr $rep: missing $( [[ -s "$dir/host-$rep.png" ]] || echo 'host screenshot ')$( [[ -s "$dir/viewer-frame-$rep" ]] || echo 'viewer frame')"
    fi
  done
  # The logs, without the WebRTC host's pairing (its link and the QR code of it: the room secret).
  for log in "$EVAL_STATE"/*.log; do
    [[ -f "$log" ]] || continue
    LC_ALL=en_US.UTF-8 grep -v -E 'cmux-vnc://|[█▀▄]' "$log" >"$dir/$(basename "$log")" || true
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
