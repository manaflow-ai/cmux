#!/usr/bin/env bash
# Fleet entry for the window live-resize feel films (Leo 2026-11-22, #50940: "chat bubbles lag behind the edge and
# re-wrap late"): builds a tagged cmux-next app at this checkout, then runs scripts/measure/window-resize-feel.py
# once per arm, each a fresh launch with its own CMUX_CEF_* resize-sync settings, and returns the films:
#   cmux-ci run --class exclusive --measurement --label measure --label gui-session-v1 --display \
#     --script scripts/measure/window-resize-feel.sh --ref <sha> [--arg=--config=bench] \
#     [--arg=--arms=NAME:LIVE_MS:DRAG_MS:FRAME_SHARE,...] [--arg=--mode=window|pane|both] [--arg=--cpu-load=AVG] \
#     --artifact window-resize-feel.tar
# An arm sets CMUX_CEF_LIVE_RESIZE_SYNC_MS (window live resize), CMUX_CEF_DRAG_RESIZE_SYNC_MS (pane drag) and
# CMUX_CEF_RESIZE_SYNC_FRAME_SHARE (the deadline's cap as a share of a frame) for the app; a build that reads none of
# them runs every arm the same. Default arms: base:0:0:0.5. Every other argument goes to window-resize-feel.py.
# --cpu-load=AVG films under load (Leo 2026-11-23: "i want all our resizing at any cpu to be able to happen in
# lockstep"): ceil(AVG/4) spinners of scripts/measure/qos-load-bench/spin.c, 4 threads each, as split-spring.sh
# runs them, and waits up to 240 s for the 1-minute load average to reach 90% of AVG before the first arm.
# The artifact: <arm>/report.json, <arm>/feel-<mode>-<n>.mov, <arm>/run.log. Judges nothing.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="rszfeel"
for sub in ghostty ghostty-next; do
  [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub"
done
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh
fi
out="$(mktemp -d)"
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
RUNNER_TEMP="$out" GITHUB_PATH="$out/bun-path" ./scripts/cmux-next/private-bun.sh
PATH="$(tail -n 1 "$out/bun-path"):$PATH"
export PATH
reload_config=() feel_args=() arms="base:0:0:0.5" load_target="" spin_pids=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --arms=*) arms="${arg#--arms=}" ;;
    --cpu-load=*) load_target="${arg#--cpu-load=}" ;;
    *) feel_args+=("$arg") ;;
  esac
done
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "window-resize-feel: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
# shellcheck disable=SC2329 # run by the trap below
cleanup() {
  local pid
  for pid in ${spin_pids[@]+"${spin_pids[@]}"}; do kill "$pid" 2>/dev/null || true; done  # the spinners this script started, by PID
  for pid in ${spin_pids[@]+"${spin_pids[@]}"}; do wait "$pid" 2>/dev/null || true; done
  python3 scripts/cmux-next/tag_teardown.py "$app" || true
}
trap cleanup EXIT
mkdir -p "$out/films"
if [[ -n "$load_target" ]]; then
  [[ "$load_target" =~ ^[0-9]+$ ]] || { echo "window-resize-feel: --cpu-load wants a whole load average, got $load_target" >&2; exit 2; }
  spinners=$(( (load_target + 3) / 4 ))
  cc -O2 -o "$out/spin" scripts/measure/qos-load-bench/spin.c
  for _ in $(seq "$spinners"); do "$out/spin" & spin_pids+=($!); done
  loadavg=0
  for _ in $(seq 240); do
    loadavg="$(sysctl -n vm.loadavg | awk '{print $2}')"
    awk -v l="$loadavg" -v t="$load_target" 'BEGIN { exit !(l >= 0.9 * t) }' && break
    sleep 1
  done
  echo "window-resize-feel: CPU-LOAD $spinners spinners, $((spinners * 4)) threads on $(sysctl -n hw.ncpu) cores; target $load_target, 1-minute load average $loadavg"
  printf '{"target": %s, "spinners": %s, "loadavg_at_start": %s}\n' "$load_target" "$spinners" "$loadavg" > "$out/films/cpu-load.json"
fi
made=0
IFS=',' read -r -a arm_list <<< "$arms"
for arm in "${arm_list[@]}"; do
  IFS=':' read -r name live drag share <<< "$arm"
  dir="$out/films/$name"
  mkdir -p "$dir"
  echo "window-resize-feel: arm $name live=${live}ms drag=${drag}ms share=$share"
  if CMUX_CEF_LIVE_RESIZE_SYNC_MS="$live" CMUX_CEF_DRAG_RESIZE_SYNC_MS="$drag" CMUX_CEF_RESIZE_SYNC_FRAME_SHARE="$share" \
      python3 scripts/measure/window-resize-feel.py --app "$app" --out "$dir" ${feel_args[@]+"${feel_args[@]}"} > "$dir/run.log" 2>&1; then
    made=$((made + 1))
  fi
  tail -n 30 "$dir/run.log" | cut -c1-400
  python3 scripts/cmux-next/tag_teardown.py "$app" > /dev/null 2>&1 || true
  sleep 3  # the last arm's helpers exit before the next launch
done
(cd "$out/films" && find . \( -name 'report.json' -o -name 'cpu-load.json' -o -name 'run.log' -o -name '*.mov' \) -print0 \
  | tar -cf "$OLDPWD/window-resize-feel.tar" --null -T -) || true
echo "window-resize-feel: $made of ${#arm_list[@]} arms ran; artifact $(du -h window-resize-feel.tar 2>/dev/null | cut -f1)"
[[ "$made" -gt 0 ]]
