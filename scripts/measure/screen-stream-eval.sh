#!/usr/bin/env bash
# The screen stream eval (HQ#7146 G0): every stream target through the same fixed scenarios on one
# quiet Mac, host and viewer on that Mac, one table per target. Scenarios, schema and the target
# interface: scripts/measure/screen-stream-eval/README.md. Run alone on a console worker whose step
# processes hold Screen Recording and Accessibility:
#   cmux-ci run --class exclusive --measurement --label measure --label gui-session-v1 --script scripts/measure/screen-stream-eval.sh \
#     --ref SHA --artifact artifacts/screen-stream-eval/results.json [--target-worker W] \
#     [--arg=targets=rd,webrtc] [--arg=samples=200] [--arg=repeats=3] --timeout 5400
#     (two Macs on one LAN: README.md, "Two Macs"; lan=IP or viewer-of=IP, with peer-token=HEX)
#   On a Mac that must not build: bash scripts/measure/screen-stream-eval.sh prebuilt=DIR [targets=rd] ...
#     (DIR holds the built tools; README.md, "Prebuilt tools"). They come from a fleet step with
#     --arg=tools-only=1 --artifact artifacts/screen-stream-eval/tools.tar.gz (no console needed).
# Output: SCREEN-STREAM-EVAL lines, the summary table, artifacts/screen-stream-eval/results.json,
# and probe.json (schema cmux.screen-share-fast/1) for the screen-share-fast goal board.
# (also each target's raw files and the host and viewer frames under that folder). No gate: it
# reports, and exits non-zero only when it could not measure at all (3: no grant; 4: no target ran;
# 5: no target measured a window).
set -uo pipefail
targets="rd,webrtc" samples=200 repeats=3 rig="" lan="" viewer_of="" peer_token="" input_frame_now=0 ltr=0 prebuilt="" tools_only=0 scene_marker=0
presented_observer=0 presented_pid="" presented_window="" presented_marker_origin="" presented_cell_size="" presented_input_point="" presented_display=main presented_timeout_ms=1000 presented_seed=1
ocr_host_crop="" ocr_viewer_crop="" ocr_calibration=""
video_path="" video_sha=""
netem_rtt_ms="" netem_loss_pct=0 netem_seed=1
stage_table=""
for arg in "$@"; do
  case "$arg" in
    targets=*) targets="${arg#targets=}" ;;
    samples=*) samples="${arg#samples=}" ;;
    repeats=*) repeats="${arg#repeats=}" ;;
    # Two Macs on one LAN (README.md, "Two Macs"): this Mac hosts at LAN address lan=, and the step on
    # the other Mac runs viewer-of=THAT_ADDRESS; both get the same peer-token= (64 hex).
    lan=*) lan="${arg#lan=}" ;;
    viewer-of=*) viewer_of="${arg#viewer-of=}" ;;
    peer-token=*) peer_token="${arg#peer-token=}" ;;
    # stage-table=LEGS (two Macs): the stage ledger, screen-share-vs.py run --legs LEGS, in place of the targets
    # (README.md, "Stage table on two Macs"): lan= on the shared Mac, viewer-of= on the viewing Mac.
    stage-table=*) stage_table="${arg#stage-table=}" ;;
    # rig=ROOT (screen-share-vs-pair.sh): only the screen-share-vs.py rig at --root ROOT, in this Mac's grants
    # (inside the launcher app below), until the rig's quit or the step ends. No eval runs.
    rig=*) rig="${arg#rig=}" ;;
    # input-frame-now=1: the rd host lifts its frame-rate cap after each input (--input-frame-now 1),
    # for a before/after against the default.
    input-frame-now=*) input_frame_now="${arg#input-frame-now=}" ;;
    # ltr=1: the rd host offers LTR loss recovery (--ltr 1, default off): a lost frame is answered
    # with a refresh P-frame from a reference the viewer acknowledged instead of a keyframe.
    ltr=*) ltr="${arg#ltr=}" ;;
    netem-rtt-ms=*) netem_rtt_ms="${arg#netem-rtt-ms=}" ;;
    netem-loss-pct=*) netem_loss_pct="${arg#netem-loss-pct=}" ;;
    netem-seed=*) netem_seed="${arg#netem-seed=}" ;;
    # prebuilt=DIR: copy the built tools from DIR instead of building any (README.md, "Prebuilt tools").
    prebuilt=*) prebuilt="${arg#prebuilt=}" ;;
    # tools-only=1: build the rd tools for prebuilt= into artifacts/screen-stream-eval/tools.tar.gz, and stop.
    tools-only=*) tools_only="${arg#tools-only=}" ;;
    # Apple always requires a fresh source marker. Other displayed viewers may
    # opt into the same source layout; legacy decode probes keep their layout.
    scene-marker=*) scene_marker="${arg#scene-marker=}" ;;
    ocr-host-crop=*) ocr_host_crop="${arg#ocr-host-crop=}" ;;
    ocr-viewer-crop=*) ocr_viewer_crop="${arg#ocr-viewer-crop=}" ;;
    ocr-calibration=*) ocr_calibration="${arg#ocr-calibration=}" ;;
    video=*) video_path="${arg#video=}" ;;
    video-sha256=*) video_sha="${arg#video-sha256=}" ;;
    # presented-observer=1: run cmux-rd observe on the viewer's visible window; the
    # remaining values are capture-pixel geometry owned by that viewer step.
    presented-observer=*) presented_observer="${arg#presented-observer=}" ;;
    presented-pid=*) presented_pid="${arg#presented-pid=}" ;;
    presented-window=*) presented_window="${arg#presented-window=}" ;;
    presented-marker-origin=*) presented_marker_origin="${arg#presented-marker-origin=}" ;;
    presented-cell-size=*) presented_cell_size="${arg#presented-cell-size=}" ;;
    presented-input-point=*) presented_input_point="${arg#presented-input-point=}" ;;
    presented-display=*) presented_display="${arg#presented-display=}" ;;
    presented-timeout-ms=*) presented_timeout_ms="${arg#presented-timeout-ms=}" ;;
    presented-seed=*) presented_seed="${arg#presented-seed=}" ;;
    *) echo "screen-stream-eval.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$samples" =~ ^[0-9]+$ ]] || { echo "screen-stream-eval.sh: samples= is a number" >&2; exit 2; }
[[ "$input_frame_now" =~ ^[01]$ ]] || { echo "screen-stream-eval.sh: input-frame-now= is 0 or 1" >&2; exit 2; }
[[ "$ltr" =~ ^[01]$ ]] || { echo "screen-stream-eval.sh: ltr= is 0 or 1" >&2; exit 2; }
[[ -z "$netem_rtt_ms" || "$netem_rtt_ms" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "screen-stream-eval.sh: netem-rtt-ms= is non-negative milliseconds" >&2; exit 2; }
[[ "$netem_loss_pct" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "screen-stream-eval.sh: netem-loss-pct= is a percentage" >&2; exit 2; }
[[ "$netem_seed" =~ ^[0-9]+$ ]] || { echo "screen-stream-eval.sh: netem-seed= is a non-negative integer" >&2; exit 2; }
if ! python3 -I - "$netem_loss_pct" <<'PY'
import sys
value = float(sys.argv[1])
if value > 100:
    raise SystemExit("screen-stream-eval.sh: netem-loss-pct= must be in [0, 100]")
PY
then
  exit 2
fi
export EVAL_RD_INPUT_FRAME_NOW="$input_frame_now" EVAL_RD_LTR="$ltr"
export EVAL_NETEM_RTT_MS="$netem_rtt_ms" EVAL_NETEM_LOSS_PCT="$netem_loss_pct" EVAL_NETEM_SEED="$netem_seed"
if [[ -n "$prebuilt" ]]; then
  prebuilt="$(cd "$prebuilt" 2>/dev/null && pwd)" || { echo "screen-stream-eval.sh: prebuilt= is not a directory" >&2; exit 2; }
fi
export EVAL_PREBUILT="$prebuilt"
# The viewer half of a two-Mac run: targets whose viewer proves readiness itself (apple) build its tools.
export EVAL_VIEWER_OF="$viewer_of"
if [[ -n "$video_path$video_sha" ]]; then
  [[ "$video_path" == /* && -f "$video_path" && "$video_sha" =~ ^[0-9a-f]{64}$ ]] || {
    echo "screen-stream-eval.sh: video=ABSOLUTE_PREBUILT_PATH and video-sha256=HEX64 are required together" >&2
    exit 2
  }
fi
export EVAL_VIDEO_PATH="$video_path" EVAL_VIDEO_SHA256="$video_sha"
if [[ -n "$ocr_host_crop$ocr_viewer_crop$ocr_calibration" ]]; then
  rect='^[0-9]+,[0-9]+,[1-9][0-9]*,[1-9][0-9]*$'
  [[ "$ocr_host_crop" =~ $rect && "$ocr_viewer_crop" =~ $rect ]] || {
    echo "screen-stream-eval.sh: explicit ocr-host-crop= and ocr-viewer-crop= X,Y,W,H are required together" >&2
    exit 2
  }
  if [[ -n "$ocr_calibration" ]]; then
    [[ -f "$ocr_calibration" ]] || { echo "screen-stream-eval.sh: OCR calibration file not found" >&2; exit 2; }
    ocr_calibration="$(cd "$(dirname "$ocr_calibration")" && pwd)/$(basename "$ocr_calibration")"
  fi
fi
# The arguments a run inside the launcher app gets: prebuilt= as the absolute path, since the app's cwd is /.
forward=()
for arg in "$@"; do
  case "$arg" in
    prebuilt=*) forward+=("prebuilt=$prebuilt") ;;
    ocr-calibration=*) forward+=("ocr-calibration=$ocr_calibration") ;;
    *) forward+=("$arg") ;;
  esac
done
[[ "$tools_only" =~ ^[01]$ ]] || { echo "screen-stream-eval.sh: tools-only= is 0 or 1" >&2; exit 2; }
[[ "$scene_marker" =~ ^[01]$ ]] || { echo "screen-stream-eval.sh: scene-marker= is 0 or 1" >&2; exit 2; }
[[ "$presented_observer" =~ ^[01]$ ]] || { echo "screen-stream-eval.sh: presented-observer= is 0 or 1" >&2; exit 2; }
if [[ "$presented_observer" == 1 ]]; then
  # The Apple targets launch their own viewer and bind its pid and window, so both are optional;
  # given, they must match what the target launched.
  [[ "$presented_pid" =~ ^([1-9][0-9]*)?$ && "$presented_window" =~ ^([1-9][0-9]*)?$ ]] || {
    echo "screen-stream-eval.sh: presented-pid= and presented-window= are numeric when given" >&2
    exit 2
  }
  [[ "$presented_marker_origin" =~ ^[0-9]+,[0-9]+$ && "$presented_cell_size" =~ ^([2-9]|[1-9][0-9]+)$ && "$presented_input_point" =~ ^[0-9]+,[0-9]+$ ]] || {
    echo "screen-stream-eval.sh: presented observer needs capture-pixel marker origin, cell size >=2 and input point" >&2
    exit 2
  }
  [[ "$presented_timeout_ms" =~ ^[1-9][0-9]*$ && "$presented_seed" =~ ^[0-9]+$ ]] || {
    echo "screen-stream-eval.sh: presented-timeout-ms= must be positive and presented-seed= numeric" >&2
    exit 2
  }
fi
[[ "$repeats" =~ ^[1-9][0-9]*$ ]] || { echo "screen-stream-eval.sh: repeats= is a number from 1" >&2; exit 2; }
ipv4='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
for value in "$lan" "$viewer_of"; do
  [[ -z "$value" || "$value" =~ $ipv4 ]] || { echo "screen-stream-eval.sh: lan= and viewer-of= are IPv4 addresses" >&2; exit 2; }
  # Each octet at most 255, so a typo fails here, not as a peer server that never binds.
  IFS=. read -r -a octets <<<"$value"
  for octet in ${octets[@]+"${octets[@]}"}; do
    (( 10#$octet <= 255 )) || { echo "screen-stream-eval.sh: $value is not an IPv4 address" >&2; exit 2; }
  done
done
if [[ -n "$lan$viewer_of" ]]; then
  [[ "$peer_token" =~ ^[0-9a-f]{64}$ ]] || { echo "screen-stream-eval.sh: two Macs need peer-token= (64 hex)" >&2; exit 2; }
  [[ -z "$lan" || -z "$viewer_of" ]] || { echo "screen-stream-eval.sh: lan= (the host Mac) or viewer-of= (the viewer Mac), not both" >&2; exit 2; }
fi
if [[ -n "$stage_table" ]]; then
  [[ -n "$lan$viewer_of" ]] || { echo "screen-stream-eval.sh: stage-table= runs on two Macs: lan= or viewer-of=, with peer-token=" >&2; exit 2; }
  [[ "$stage_table" =~ ^[a-z0-9=-]+(,[a-z0-9=-]+)*$ ]] || { echo "screen-stream-eval.sh: stage-table= is LINK or LINK=PROFILE, comma-separated" >&2; exit 2; }
fi
[[ -z "$rig" || "$rig" =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "screen-stream-eval.sh: rig= is an absolute path" >&2; exit 2; }
peer_port=4180
# From the script's place, not the cwd: inside the launcher app (below) the cwd is /.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
# The rd host takes options it does not know without a word, so input-frame-now=1 at a commit whose host
# lacks --input-frame-now (before #36690) would measure the default and call it the bypass: refuse it.
if [[ "$input_frame_now" == 1 ]] && ! grep -q 'flag("input-frame-now")' cmux-tui/crates/cmux-rd-host/src/host.rs 2>/dev/null; then
  echo "screen-stream-eval.sh: input-frame-now=1, but this commit's rd host has no --input-frame-now" >&2
  exit 2
fi
if [[ "$ltr" == 1 ]] && ! grep -q 'flag("ltr")' cmux-tui/crates/cmux-rd-host/src/host.rs 2>/dev/null; then
  echo "screen-stream-eval.sh: ltr=1, but this commit's rd host has no --ltr" >&2
  exit 2
fi
here="$root/scripts/measure/screen-stream-eval"
if [[ -n "$rig" ]]; then
  # The rig is what posts the input and starts the host, so it, not the step, needs Screen Recording and
  # Accessibility: inside the launcher app (the step's own processes hold neither) it runs the rig itself.
  vs="$root/cmux-tui/crates/cmux-rd-host/scripts/screen-share-vs.py"
  [[ -n "${CMUX_SCREEN_EVAL_IN_LAUNCHER:-}" ]] && exec /usr/bin/python3 -I "$vs" rig --root "$rig"
  launch="$rig.launcher"
  rm -rf "$launch"
  mkdir -p "$launch"
  app=$(bash "$here/launcher/install.sh" 2>"$launch/install.log") ||
    { echo "screen-stream-eval.sh: rig=: the launcher app did not install ($(tail -1 "$launch/install.log"))" >&2; exit 3; }
  open -W -n -g -a "$app" --stdout "$launch/grants.json" --stderr "$launch/grants.err" --args --status \
    >"$launch/open.log" 2>&1 || true
  grants=$(cat "$launch/grants.json" 2>/dev/null)
  echo "SCREEN-STREAM-EVAL-RIG app=$app grants=${grants:-none}"
  grep -q '"accessibility":true' <<<"$grants" && grep -q '"screen_recording":true' <<<"$grants" || {
    echo "screen-stream-eval.sh: rig=: $app lacks Screen Recording or Accessibility on this Mac; grant both to it once at the console ($grants)" >&2
    exit 3
  }
  env_args=()
  for var in PATH HOME TMPDIR USER LANG $(compgen -e | grep -E '^CMUX_' || true); do
    [[ -n "${!var:-}" ]] && env_args+=(--env "$var=${!var}")
  done
  # The app ends the rig when this process is gone (the step killed it, or the step ended).
  open -W -n -g -a "$app" --stdout "$launch/out.log" --stderr "$launch/err.log" ${env_args[@]+"${env_args[@]}"} \
    --env "CMUX_SCREEN_EVAL_PARENT=$$" --args "$root/scripts/measure/screen-stream-eval.sh" "$launch/status" "rig=$rig" || true
  tail -n 40 "$launch/err.log" 2>/dev/null >&2
  status=$(cat "$launch/status" 2>/dev/null || echo 3)
  rm -rf "$launch"
  exit "$status"
fi
out="$root/artifacts/screen-stream-eval"
work="$root/.build/screen-stream-eval"
# The run starts by removing $out and $work, so prebuilt tools may not live in either.
case "$prebuilt/" in
  "$out"/* | "$work"/*) echo "screen-stream-eval.sh: prebuilt= may not be inside $out or $work (the run removes both)" >&2; exit 2 ;;
esac
# A viewer that opens windows or posts input fights the person at a Mac they use (person_guard.py):
# refuse before anything is removed or started. A tools-only build opens nothing.
if [[ "$tools_only" != 1 ]]; then
  # viewer-of= makes this Mac the viewer only, where apple-rfb is headless.
  guard_role=()
  [[ -n "$viewer_of" ]] && guard_role=(viewer)
  python3 -I "$here/person_guard.py" check "$targets" ${guard_role[@]+"${guard_role[@]}"} || exit 2
fi
rm -rf "$out" "$work"
mkdir -p "$out" "$work/bin"
chmod 700 "$work"
export EVAL_ROOT="$root" EVAL_BIN="$work/bin"
if [[ "$presented_observer" == 1 ]]; then
  export EVAL_PRESENTED_OBSERVER_BIN="$EVAL_BIN/cmux-rd"
  export EVAL_PRESENTED_OBSERVER_PID="$presented_pid" EVAL_PRESENTED_OBSERVER_WINDOW="$presented_window"
  export EVAL_PRESENTED_MARKER_ORIGIN="$presented_marker_origin" EVAL_PRESENTED_CELL_SIZE="$presented_cell_size"
  export EVAL_PRESENTED_INPUT_POINT="$presented_input_point" EVAL_PRESENTED_DISPLAY="$presented_display"
  export EVAL_PRESENTED_TIMEOUT_MS="$presented_timeout_ms" EVAL_PRESENTED_SEED="$presented_seed"
fi

if [[ "$tools_only" == 1 ]]; then
  # The tools a prebuilt= Mac runs, as one folder `tools/` in tools.tar.gz. The Swift tools target
  # macOS 14, so they run on a Mac older than this worker's SDK.
  swift_target="$(uname -m)-apple-macos14.0"
  # window-id and marker-locate: the third-party viewers' tools (gui-viewer.sh), for a prebuilt= viewer Mac.
  for tool in preflight scene ocr window-id marker-locate; do
    swiftc -O -target "$swift_target" -o "$EVAL_BIN/screen-eval-$tool" "$here/$tool.swift" || exit 4
  done
  swiftc -O -target "$swift_target" -o "$EVAL_BIN/cmux-rd-marker" \
    "$root/cmux-tui/crates/cmux-rd-host/scripts/mac-marker/main.swift" || exit 4
  bash "$here/targets/rd.sh" build || exit 4
  git rev-parse HEAD >"$EVAL_BIN/rev"
  mv "$EVAL_BIN" "$work/tools"
  tar -czf "$out/tools.tar.gz" -C "$work" tools || exit 4
  echo "SCREEN-STREAM-EVAL-TOOLS $(cat "$work/tools/rev") $(du -k "$out/tools.tar.gz" | cut -f1) KiB"
  exit 0
fi

# The scene's timeline is 81 s from GO (scene.swift), then it holds the ocr screen until STOP; the
# passive window starts at the viewer's first frame, GO follows it, so the window ends inside the hold.
window_s=84
[[ -n "$video_path" ]] && window_s=104
display=$(system_profiler SPDisplaysDataType 2>/dev/null | sed -n 's/^ *Resolution: //p' | head -1)
run_json() {
  python3 -I - "$@" <<'EOF'
import json, sys, datetime
keys = sys.argv[1::2]; values = sys.argv[2::2]
run = dict(zip(keys, values))
run["at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
run.setdefault("link", "loopback: host and viewer on one Mac")
print(json.dumps(run))
EOF
}
# The commit measured: the checkout's, or with prebuilt= the one DIR/rev names (the tools' build).
rev() {
  if [[ -n "$prebuilt" ]]; then cat "$prebuilt/rev" 2>/dev/null || echo unknown; else git rev-parse HEAD; fi
}
link_arg=()
if [[ "$lan" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]; then
  # A tailnet address (100.64.0.0/10): two Macs on one LAN reach each other directly, inside
  # WireGuard. The fleet needs it, since macOS Local Network privacy refuses launchd-started
  # binaries the LAN addresses (cmuxterm-hq build-fleet/README.md); the label keeps that visible.
  link_arg=(link "lan via tailnet: host at $lan (WireGuard, direct), viewer on a second Mac")
elif [[ -n "$lan" ]]; then
  link_arg=(link "lan: host at $lan, viewer on a second Mac")
fi
run=$(run_json host "$(scutil --get ComputerName 2>/dev/null || hostname)" cpu "$(sysctl -n machdep.cpu.brand_string)" \
  macos "$(sw_vers -productVersion)" rev "$(rev)" display "$display" samples "$samples" repeats "$repeats" \
  rd_input_frame_now "$input_frame_now" rd_ltr "$ltr" netem_rtt_ms "$netem_rtt_ms" netem_loss_pct "$netem_loss_pct" netem_seed "$netem_seed" \
  ${link_arg[@]+"${link_arg[@]}"})
echo "SCREEN-STREAM-EVAL-MACHINE $run"

pids=()
cleanup() {
  for pid in ${pids[@]+"${pids[@]}"}; do kill "$pid" 2>/dev/null || true; done
  # A run cut short leaves the current target's host (and iphone-sim's simulator) running: its
  # host-stop ends them. host-stop is a no-op for a host that already stopped.
  if [[ -n "${script:-}" && -f "${script:-}" && -n "${EVAL_STATE:-}" ]]; then
    bash "$script" host-stop >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
# A signal ends the run through EXIT, so cleanup runs then too.
trap 'exit 143' TERM
trap 'exit 130' INT

# results.json from whatever the targets wrote; blocked=REASON marks a run that measured nothing.
finish() {
  local blocked="${1:-}"
  python3 -I - "$out" "$run" "$blocked" "$targets" "$here" "$video_path" "$work/peer/agent.json" <<'EOF'
import json, sys
from pathlib import Path
out, run, blocked, names = Path(sys.argv[1]), json.loads(sys.argv[2]), sys.argv[3], sys.argv[4].split(",")
peer = Path(sys.argv[7])
if peer.exists():
    try:
        run["viewer"] = json.loads(peer.read_text()).get("host")
    except (OSError, ValueError):
        pass
sys.path.insert(0, sys.argv[5])
from eval import SCHEMA, empty_target
if blocked:
    run["blocked"] = blocked
targets = {}
for name in names:
    path = out / name / "target.json"
    targets[name] = json.loads(path.read_text()) if path.exists() else empty_target([blocked or "did not run"])
scenarios = ["idle", "typing", "scroll"] + (["video"] if sys.argv[6] else []) + ["ocr"]
results = {"schema": SCHEMA, "run": run, "scenarios": scenarios, "targets": targets}
(out / "results.json").write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")
EOF
  python3 -I "$here/eval.py" summary "$out/results.json" "$out/summary.md"
  python3 -I "$here/probe.py" "$out/results.json" "$out/probe.json"
  cat "$out/summary.md"
  # Includes only explicit eval outputs, never the host's authentication token (nor the copy an
  # earlier call left in $out).
  rm -f "$out/evidence.tar.gz"
  tar -czf "$work/evidence.tar.gz" -C "$out" .
  cp "$work/evidence.tar.gz" "$out/evidence.tar.gz"
}

# The viewer Mac of a two-Mac run: no scene or marker here. It builds each target and serves the host
# Mac's view verbs. cmux's own viewers only receive and send input over the network, so they need no
# grants; a third-party viewer measured from outside (gui-viewer.sh: observe posts input and captures
# the display) does, and its target's `caps` says `viewer-grants`. Then the viewer half takes the same
# grant check, and the same launcher, as a host run below before it serves.
serve_viewer() {
  printf '%s\n' "$peer_token" >"$work/peer-token"
  chmod 600 "$work/peer-token"
  IFS=',' read -r -a names <<<"$targets"
  for name in "${names[@]}"; do
    echo "SCREEN-STREAM-EVAL-STAGE viewer $name build"
    mkdir -p "$out/$name"
    bash "$here/targets/$name.sh" build >"$out/$name/build.log" 2>&1 || { tail -40 "$out/$name/build.log"; echo "SCREEN-STREAM-EVAL-ERROR viewer $name build failed"; }
  done
  echo "SCREEN-STREAM-EVAL-STAGE viewer serving $viewer_of:$peer_port"
  python3 -I "$here/peer.py" agent "$viewer_of" "$peer_port" "$work/peer-token" "$root"
  status=$?
  finish "the viewer Mac of a two-Mac run (host $viewer_of): the host Mac's step has the results"
  exit "$status"
}
viewer_grants=0
IFS=',' read -r -a names <<<"$targets"
for name in "${names[@]}"; do
  bash "$here/targets/$name.sh" caps 2>/dev/null | grep -qx viewer-grants && viewer_grants=1
done
[[ -n "$viewer_of" && "$viewer_grants" == 0 && -z "$stage_table" ]] && serve_viewer

echo "SCREEN-STREAM-EVAL-STAGE tools"
if [[ -n "$prebuilt" ]]; then
  for tool in screen-eval-preflight screen-eval-scene screen-eval-ocr cmux-rd-marker; do
    cp "$prebuilt/$tool" "$EVAL_BIN/$tool" || { finish "prebuilt=: no $tool in $prebuilt"; exit 4; }
  done
  # marker-locate places the source marker for calibrated OCR; older tool folders lack it (OCR then says why).
  [[ ! -x "$prebuilt/screen-eval-marker-locate" ]] || cp "$prebuilt/screen-eval-marker-locate" "$EVAL_BIN/"
else
  for tool in preflight scene ocr marker-locate; do
    swiftc -O -o "$EVAL_BIN/screen-eval-$tool" "$here/$tool.swift" || { finish "could not build $tool.swift"; exit 4; }
  done
  swiftc -O -o "$EVAL_BIN/cmux-rd-marker" "$root/cmux-tui/crates/cmux-rd-host/scripts/mac-marker/main.swift" ||
    { finish "could not build the marker"; exit 4; }
fi
granted() { grep -q '"accessibility":true' <<<"$1" && grep -q '"screen_recording":true' <<<"$1"; }
# follow_log LOG DONE: print LOG from its start as it grows, and end at its end once the file DONE exists, so the
# caller waits for the follower itself to have printed every last line.
follow_log() {
  python3 -I -c 'import os, sys, time
log, done = sys.argv[1], sys.argv[2]
with open(log, "rb") as f:
    while True:
        finished = os.path.exists(done)  # before the read: what was written before DONE is read
        chunk = f.read(65536)
        if chunk:
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
        elif finished:
            break
        else:
            time.sleep(0.1)' "$1" "$2"
}
grants=$("$EVAL_BIN/screen-eval-preflight")
echo "SCREEN-STREAM-EVAL-GRANTS $grants"
if ! granted "$grants" && [[ -z "${CMUX_SCREEN_EVAL_IN_LAUNCHER:-}" ]]; then
  # The step's own processes hold no grants (a step's binaries change every commit). Run this whole
  # eval again inside CmuxScreenEvalLauncher.app (launcher/), a stable app granted once at the console,
  # whose children get its grants. Its files live outside $work, which the inner run starts by removing.
  if [[ -n "$prebuilt" ]]; then
    # Installing the launcher compiles it, which a prebuilt= Mac does not do: it must be there already.
    home=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
    if [[ ! -x "$home/Applications/CmuxScreenEvalLauncher.app/Contents/MacOS/CmuxScreenEvalLauncher" ]]; then
      finish "prebuilt=: this Mac's processes lack Screen Recording or Accessibility, and it has no CmuxScreenEvalLauncher.app to run in ($grants)"
      exit 3
    fi
  fi
  launch="$root/.build/screen-stream-eval-launcher"
  rm -rf "$launch"
  mkdir -p "$launch"
  install_status=0
  if [[ -n "$prebuilt" ]]; then
    # The prebuilt route is for a bench Mac that must not compile anything. The
    # installed launcher is checked above and already carries its console grants.
    app="$home/Applications/CmuxScreenEvalLauncher.app"
  else
    app=$(bash "$here/launcher/install.sh" 2>"$launch/install.log") || install_status=$?
  fi
  if [[ "$install_status" == 0 ]]; then
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
      rm -f "$launch/out.done"
      follow_log "$launch/out.log" "$launch/out.done" &
      follow=$!
      pids+=("$follow")
      open -W -n -g -a "$app" --stdout "$launch/out.log" --stderr "$launch/err.log" ${env_args[@]+"${env_args[@]}"} \
        --env "CMUX_SCREEN_EVAL_PARENT=$$" --args "$root/scripts/measure/screen-stream-eval.sh" "$launch/status" ${forward[@]+"${forward[@]}"} || true
      # Until the follower has printed the last lines and ended, 10 s.
      : >"$launch/out.done"
      for _ in $(seq 1 100); do kill -0 "$follow" 2>/dev/null || break; sleep 0.1; done
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
    finish "the step's processes lack Screen Recording or Accessibility, and the launcher app did not install ($(tail -1 "$launch/install.log" 2>/dev/null))"
  fi
  exit 3
fi
if ! granted "$grants"; then
  finish "the step's processes lack Screen Recording or Accessibility on this worker ($grants)"
  exit 3
fi
# stage-table=: the stage ledger in place of the targets, both halves inside this process's grants.
if [[ -n "$stage_table" ]]; then
  printf '%s\n' "$peer_token" >"$work/peer-token"
  chmod 600 "$work/peer-token"
  status=0
  if [[ -n "$lan" ]]; then
    bash "$here/stage-table.sh" host "$lan" "$work/peer-token" "$out/stage-table" || status=$?
  else
    bash "$here/stage-table.sh" viewer "$viewer_of" "$work/peer-token" "$out/stage-table" "$stage_table" || status=$?
  fi
  finish "stage-table=$stage_table: the ledger is in stage-table/ (ledger.jsonl, table.txt)"
  exit "$status"
fi
[[ -n "$viewer_of" ]] && serve_viewer

if [[ -n "$lan" ]]; then
  printf '%s\n' "$peer_token" >"$work/peer-token"
  chmod 600 "$work/peer-token"
  python3 -I "$here/peer.py" serve "$lan" "$peer_port" "$work/peer-token" "$work/peer" >"$work/peer.log" 2>&1 &
  server=$!
  pids+=("$server")
  echo "SCREEN-STREAM-EVAL-STAGE peer waiting for the viewer Mac at $lan:$peer_port"
  # Once: does the server answer on the LAN address from this Mac? (403 without the token is an answer.)
  # First until its port takes a connection (or it exits), 10 s; the check below reports either way.
  for _ in $(seq 1 100); do
    kill -0 "$server" 2>/dev/null || break
    python3 -I -c 'import socket, sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=0.5).close()' \
      "$lan" "$peer_port" 2>/dev/null && break
    sleep 0.1
  done
  echo "SCREEN-STREAM-EVAL-PEER-SELF $(python3 -I -c 'import sys, urllib.request
try:
    urllib.request.urlopen(f"http://{sys.argv[1]}:{sys.argv[2]}/clock", timeout=5)
    print("answered")
except urllib.error.HTTPError as e:
    print(f"answered {e.code}")
except OSError as e:
    print(f"no answer: {e!r}")' "$lan" "$peer_port")"
  for _ in $(seq 1 360); do
    [[ -s "$work/peer/agent.json" ]] && break
    # A server that could not bind (an address this Mac lacks, a port in use) ends at once: say so.
    if ! kill -0 "$server" 2>/dev/null; then
      finish "two Macs: the peer server on $lan:$peer_port stopped ($(tail -1 "$work/peer.log" 2>/dev/null))"
      exit 4
    fi
    sleep 5 # bounded wait for the viewer Mac's step to start and build (30 min)
  done
  if [[ ! -s "$work/peer/agent.json" ]]; then
    finish "two Macs: the viewer Mac's step never reached $lan:$peer_port ($(tail -1 "$work/peer.log" 2>/dev/null))"
    exit 4
  fi
  echo "SCREEN-STREAM-EVAL-PEER $(cat "$work/peer/agent.json")"
  export EVAL_BIND="$lan"
fi
# view VERB ARG... RAW: a target's view verb, on this Mac or (two Macs) on the viewer Mac.
view() {
  if [[ -n "$lan" ]]; then
    EVAL_PEER_STREAM_TOKEN="$EVAL_STATE/token" \
      CMUX_VNC_STREAM_LINK="$(grep -m1 -o 'cmux-vnc://pair[^ ]*' "$EVAL_STATE/host.log" 2>/dev/null)" \
      python3 -I "$here/peer.py" call "$work/peer" "$name" "$@"
  else
    # RAW.span, the view's start and end on this Mac's wall clock, as peer.py writes it for a LAN
    # view: the reports cut the host's shared logs (WebRTC's encode samples) to this view's.
    local raw="${*: -1}" start rc=0
    start=$(python3 -I -c 'import time; print(time.time_ns() // 1_000_000)')
    bash "$script" "$@" || rc=$?
    python3 -I -c 'import json, sys, time
json.dump({"start_unix_ms": int(sys.argv[2]), "end_unix_ms": time.time_ns() // 1_000_000}, open(sys.argv[1], "w"))' "$raw.span" "$start"
    return "$rc"
  fi
}
# with_offsets RAW CMD...: CMD with the clock offsets peer.py measured for RAW's view (none on one Mac).
with_offsets() {
  local clock="$1.clock" mono=0 wall=0
  shift
  if [[ -s "$clock" ]]; then
    mono=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["mono_ms"])' "$clock")
    wall=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["wall_ms"])' "$clock")
    echo "SCREEN-STREAM-EVAL-PEER $name $(basename "${clock%.clock}") $(cat "$clock")"
  fi
  EVAL_PEER_MONO_OFFSET_MS=$mono EVAL_PEER_WALL_OFFSET_MS=$wall "$@"
}

ran=0
done_any=0
IFS=',' read -r -a names <<<"$targets"
for name in "${names[@]}"; do
  # results.json as it stands before each later target, so a run the step's timeout or a signal cuts
  # short in a slow target (iphone-sim builds an app) still hands back the targets before it; the
  # ones not reached read "did not run". The last call of finish, after the loop, replaces it.
  [[ "$done_any" == 1 ]] && finish >/dev/null 2>&1
  done_any=1
  unset EVAL_SCENE_NONCE EVAL_SCENE_GEOMETRY
  script="$here/targets/$name.sh"
  dir="$out/$name"
  mkdir -p "$dir"
  # Keep the requested repeat count even when build or host setup fails before a
  # window-N/ocr-N artifact exists; eval.py must not infer completeness from the
  # subset of repeats that happened to start.
  python3 -I - "$dir/repeats-requested.json" "$repeats" <<'PY'
import json, sys
json.dump({"count": int(sys.argv[2])}, open(sys.argv[1], "w"))
PY
  if [[ -n "$video_path" ]]; then
    python3 -I - "$dir/video-requested.json" "$video_sha" <<'PY'
import json, sys
json.dump({"sha256": sys.argv[2], "duration_s": 20}, open(sys.argv[1], "w"))
PY
  fi
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

  # A target whose `caps` verb prints window-only (cu-png, rd-window: no input path to time) skips
  # the latency stage, and eval.py then judges it on its window rows alone. Every other target
  # answers `caps` with nothing or an error and runs both stages. latency-only (iphone-sim: its
  # viewer has no passive window yet) is the other way round: latency, and no window or OCR repeats.
  window_only=0 latency_only=0
  caps=$(bash "$script" caps 2>/dev/null || true)
  if grep -qx window-only <<<"$caps"; then
    window_only=1
    : >"$dir/window-only"
  elif grep -qx latency-only <<<"$caps"; then
    latency_only=1
    : >"$dir/latency-only"
  fi

  # Latency: the marker (cmux-rd-host/scripts/mac-marker) above everything, then the host.
  if [[ "$window_only" == 0 ]]; then
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
      raw="$EVAL_STATE/latency-$input.raw"
      rm -f "$raw" "$raw.first" "$raw.clock" "$raw.span"
      view latency-view "$input" "$samples" "$raw" || err "latency $input failed"
      with_offsets "$raw" bash "$script" latency-report "$input" "$raw" "$dir/latency-$input.json" || err "latency $input: no report"
    done
  else
    err "host did not start for latency: $why"
  fi
  bash "$script" host-stop
  kill "$marker" 2>/dev/null || true
  wait "$marker" 2>/dev/null || true
  fi

  # Window and OCR: the scene's fixed timeline under one passive viewer, $repeats times (a fresh host
  # each time); eval.py reports each number's median and keeps every repeat's.
  for rep in $(seq 1 "$repeats"); do
    [[ "$latency_only" == 1 ]] && break
    echo "SCREEN-STREAM-EVAL-STAGE $name window $rep/$repeats"
    go="$EVAL_STATE/go" stop="$EVAL_STATE/stop"
    rm -f "$go" "$stop" "$dir/host-$rep.png"
    unset EVAL_SCENE_NONCE EVAL_SCENE_GEOMETRY EVAL_SCENE_READY_FILE EVAL_VIDEO_METADATA
    if [[ "$scene_marker" == 1 || "$name" == apple-* || -n "$video_path" ]]; then
      nonce=$(python3 -I -c 'import secrets; print(secrets.token_hex(16))') || {
        err "window $rep: could not create fresh source nonce"
        continue
      }
      export EVAL_SCENE_NONCE="$nonce" EVAL_SCENE_GEOMETRY="$dir/source-scene-$rep.json"
      export EVAL_SCENE_READY_FILE="$EVAL_STATE/source-ready-$rep"
      rm -f "$EVAL_SCENE_READY_FILE"
    fi
    [[ -n "$video_path" ]] && export EVAL_VIDEO_METADATA="$dir/video-media-$rep.json"
    "$EVAL_BIN/screen-eval-scene" "$go" "$stop" "$dir/phases-$rep.jsonl" "$dir/host-$rep.png" "$dir/truth.txt" >"$EVAL_STATE/scene.log" 2>&1 &
    scene=$!
    pids+=("$scene")
    if [[ -n "${EVAL_SCENE_READY_FILE:-}" ]]; then
      for _ in $(seq 1 300); do
        [[ -e "$EVAL_SCENE_READY_FILE" ]] && break
        kill -0 "$scene" 2>/dev/null || break
        sleep 0.1 # bounded source preparation (including pinned-asset validation)
      done
      if [[ ! -e "$EVAL_SCENE_READY_FILE" ]]; then
        err "window $rep: source did not prepare within 30 s ($(tail -1 "$EVAL_STATE/scene.log"))"
        touch "$stop"
        kill "$scene" 2>/dev/null || true
        wait "$scene" 2>/dev/null || true
        continue
      fi
    else
      sleep 2 # legacy scene binary; unchanged source layout
    fi
    if why=$(host_start); then
      raw="$EVAL_STATE/window-$rep.raw"
      rm -f "$raw" "$raw.clock" "$raw.span"
      view window-view "$window_s" "$dir/viewer-frame-$rep" "$go" "$raw" || err "window $rep failed"
      with_offsets "$raw" bash "$script" window-report "$raw" "$dir/window-$rep.json" || err "window $rep: no report"
    else
      err "host did not start for window $rep: $why"
      # STOP cancels the scene's readiness wait without ever authorizing GO.
      touch "$stop"
    fi
    touch "$stop"
    wait "$scene" || err "scene $rep exited $? ($(tail -1 "$EVAL_STATE/scene.log"))"
    bash "$script" host-stop
    if [[ "$name" == rd ]]; then
      evidence="$dir/rd-evidence-$rep"
      mkdir -p "$evidence"
      for file in "$raw" "$EVAL_STATE/timing.jsonl" "$EVAL_STATE/netem-stats.json"; do
        [[ ! -f "$file" ]] || cp "$file" "$evidence/"
      done
      [[ ! -d "$EVAL_STATE/quality" ]] || cp -R "$EVAL_STATE/quality" "$evidence/"
    fi

    echo "SCREEN-STREAM-EVAL-STAGE $name ocr $rep/$repeats"
    if [[ -n "$ocr_host_crop" && -s "$dir/host-$rep.png" && -s "$dir/viewer-frame-$rep" ]]; then
      crop_args=(--host-crop "$ocr_host_crop" --viewer-crop "$ocr_viewer_crop")
      [[ -n "$ocr_calibration" ]] && crop_args+=(--calibration "$ocr_calibration")
      [[ -s "$dir/source-scene-$rep.json" ]] && crop_args+=(--source-geometry "$dir/source-scene-$rep.json")
      [[ -s "$raw.readiness.json" ]] && crop_args+=(--readiness "$raw.readiness.json")
      "$EVAL_BIN/screen-eval-ocr" "$dir/host-$rep.png" "$dir/viewer-frame-$rep" "$dir/truth.txt" "${crop_args[@]}" >"$dir/ocr-$rep.json" || err "ocr $rep: invalid calibrated crop"
    elif [[ "$name" == apple-rfb && -s "$dir/source-scene-$rep.json" && -s "$dir/host-$rep.png" && -s "$dir/viewer-frame-$rep" ]] &&
      crop=$(python3 -I - "$dir/source-scene-$rep.json" "$dir/host-$rep.png" "$dir/viewer-frame-$rep" <<'PY'
import json, struct, sys
# rfb-viewer's frame is the host's framebuffer: the same display in the same pixels as the host's
# screenshot, so one crop, the text below the marker strip, fits both. Refuse when sizes differ.
def size(path):
    head = open(path, "rb").read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(1)
    return struct.unpack("!II", head[16:24])
scene = json.load(open(sys.argv[1]))
host, viewer = size(sys.argv[2]), size(sys.argv[3])
if host != viewer:
    raise SystemExit(1)
scale = host[0] / scene["display_size_points"][0]
x, y, w, h = (round(v * scale) for v in scene["content_rect_points"])
print(f"{y} {x} {min(h, host[1] - y)} {min(w, host[0] - x)}")
PY
      ); then
      # Same pixels on both sides, so no calibration: crop both to the text and compare them whole.
      read -r cy cx ch cw <<<"$crop"
      for side in host viewer; do
        src="$dir/host-$rep.png"
        [[ "$side" == viewer ]] && src="$dir/viewer-frame-$rep"
        sips --cropOffset "$cy" "$cx" --cropToHeightWidth "$ch" "$cw" "$src" --out "$EVAL_STATE/ocr-$side-$rep.png" >/dev/null 2>&1 ||
          err "ocr $rep: could not crop the $side image"
      done
      "$EVAL_BIN/screen-eval-ocr" "$EVAL_STATE/ocr-host-$rep.png" "$EVAL_STATE/ocr-viewer-$rep.png" "$dir/truth.txt" \
        >"$dir/ocr-$rep.json" || err "ocr $rep failed"
      # The crop receipt: same pixels on both sides, sizes checked above.
      python3 -I "$here/same_pixels.py" "$dir/ocr-$rep.json" "$dir/host-$rep.png" "$dir/viewer-frame-$rep" "$cx,$cy,$cw,$ch" ||
        err "ocr $rep: same-pixel receipt failed"
    elif [[ "$name" == apple-* && "$name" != apple-rfb && -x "$EVAL_BIN/screen-eval-marker-locate" &&
      -s "$dir/source-scene-$rep.json" && -s "$raw.readiness.json" && -s "$dir/host-$rep.png" && -s "$dir/viewer-frame-$rep" ]]; then
      # Screen Sharing shows the host's display scaled and offset in its window: locate the source
      # marker on both sides, map the scene's content rect through each, and bind the result to this
      # repeat's source and selected window (ocr_calibration.py). Verified only when both markers read.
      host_marker=$("$EVAL_BIN/screen-eval-marker-locate" "$dir/host-$rep.png" 2>/dev/null) || host_marker=""
      viewer_marker=$("$EVAL_BIN/screen-eval-marker-locate" "$dir/viewer-frame-$rep" 2>/dev/null) || viewer_marker=""
      if crops=$(python3 -I "$here/ocr_calibration.py" "$dir/source-scene-$rep.json" "$raw.readiness.json" \
        "$dir/host-$rep.png" "$dir/viewer-frame-$rep" "$host_marker" "$viewer_marker" "$dir/ocr-calibration-$rep.json" \
        2>"$EVAL_STATE/ocr-calibration-$rep.err"); then
        read -r host_crop viewer_crop <<<"$crops"
        "$EVAL_BIN/screen-eval-ocr" "$dir/host-$rep.png" "$dir/viewer-frame-$rep" "$dir/truth.txt" \
          --host-crop "$host_crop" --viewer-crop "$viewer_crop" --calibration "$dir/ocr-calibration-$rep.json" \
          --source-geometry "$dir/source-scene-$rep.json" --readiness "$raw.readiness.json" >"$dir/ocr-$rep.json" ||
          err "ocr $rep: invalid calibrated crop"
      else
        python3 -I -c 'import json, sys; print(json.dumps({"cer": None, "comparison_ready": False, "reason": "OCR calibration not verified: " + json.load(open(sys.argv[1])).get("reason", "unknown")}))' \
          "$dir/ocr-calibration-$rep.json" >"$dir/ocr-$rep.json" 2>/dev/null ||
          printf '{"cer":null,"comparison_ready":false,"reason":"OCR calibration failed"}\n' >"$dir/ocr-$rep.json"
      fi
    elif [[ -n "${EVAL_SCENE_NONCE:-}" ]]; then
      # The common marker reserves a region above the text. Full-window OCR
      # would include it and Apple chrome; calibrated pixel crops are required.
      printf '{"cer":null,"comparison_ready":false,"reason":"common source marker requires calibrated host/viewer OCR crops"}\n' >"$dir/ocr-$rep.json"
    elif [[ -s "$dir/host-$rep.png" && -s "$dir/viewer-frame-$rep" ]]; then
      "$EVAL_BIN/screen-eval-ocr" "$dir/host-$rep.png" "$dir/viewer-frame-$rep" "$dir/truth.txt" >"$dir/ocr-$rep.json" || err "ocr $rep failed"
      # An rd viewer frame is the host display decoded at the host's size, and with no source
      # marker the whole display is the scene's text: the two images are comparable whole once
      # their sizes match (same_pixels.py checks, and says why not when they differ).
      if [[ "$name" == rd || "$name" == rd-* ]]; then
        python3 -I "$here/same_pixels.py" "$dir/ocr-$rep.json" "$dir/host-$rep.png" "$dir/viewer-frame-$rep" ||
          err "ocr $rep: same-pixel receipt failed"
      fi
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

[[ -n "$lan" ]] && python3 -I "$here/peer.py" done "$work/peer"
if [[ $ran == 0 ]]; then
  finish "no target built"
  exit 4
fi
finish
# A run with no successful measured target is not a baseline a later run should
# diff against. Apple transport kbps, decoded FPS and first-frame latency can be
# unavailable; its OCR or sampled-change evidence still counts when the target
# itself completed successfully. A latency-only target (iphone-sim) counts by its latency.
python3 -I -c 'import json, sys; t = json.load(open(sys.argv[1]))["targets"].values(); measured = lambda x: x.get("ok") and (any(v is not None for v in (x.get("kbps") or {}).values()) or any(v is not None for v in (x.get("fps") or {}).values()) or any(v is not None for v in (x.get("sampled_fps") or {}).values()) or (x.get("extra") or {}).get("first_frame_ms") is not None or (x.get("ocr") or {}).get("cer") is not None or any(((x.get("latency") or {}).get(k) or {}).get("p50_ms") is not None for k in ("key", "pointer"))); sys.exit(0 if any(measured(x) for x in t) else 5)' "$out/results.json" || exit 5
exit 0
