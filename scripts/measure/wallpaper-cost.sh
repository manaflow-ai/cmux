#!/usr/bin/env bash
# What a moving wallpaper costs (plans/cmux-next/live-wallpapers.md, "Cost"): the app's CPU time per second, the
# wallpaper's GPU time per second and the app's phys_footprint, 60 s each, for a painting (the baseline), each
# live wallpaper (the pointer moving over the window), local test videos (videos=1080p30,4k60, made on the host) and
# a YouTube wallpaper (youtube=ID, youtube_qualities=default,720); then idle, occluded, covered, minimized and Low
# Power Mode for the first live wallpaper, each video and each YouTube one. Every phase also has the app's helper
# processes (WebKit, VTDecoderXPCService), WindowServer, the GPU's utilization and network bytes.
# Builds a tagged app at this checkout (reload.sh) and runs scripts/measure/wallpaper-cost.py on it.
# Run alone on a fleet Mac nobody is using (it launches an app and moves the pointer):
#   cmux-ci run --class exclusive --measurement --label measure \
#     --script scripts/measure/wallpaper-cost.sh --ref SHA [--arg=measure=60] [--arg=ids=orbits,metal] \
#     [--arg=frame_rate=30] [--arg=picture=van-gogh-starry-night] [--arg=videos=1080p30,4k60] \
#     [--arg=youtube=aqz-KE-bpKQ] [--arg=youtube_qualities=default,720] [--arg=holds=orbits,video-4k60] \
#     [--arg=hold_phases=idle,occluded,covered,minimized,low-power] [--arg=idle_pause=20] [--arg=settle=10] \
#     --artifact .build/wallpaper-cost/rows.json
# Output: WALLPAPER-COST lines (scripts/bench/benches/wallpaper_cost.py reads them) and a Markdown table between
# WALLPAPER-COST-TABLE-BEGIN and -END; JSON in .build/wallpaper-cost/rows.json.
set -euo pipefail
measure=60 ids="" frame_rate=30 picture="" videos="" youtube="" youtube_qualities="" holds="" hold_phases="" idle_pause="" settle=""
reload_config=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    measure=*) measure="${arg#measure=}" ;;
    ids=*) ids="${arg#ids=}" ;;
    frame_rate=*) frame_rate="${arg#frame_rate=}" ;;
    picture=*) picture="${arg#picture=}" ;;
    videos=*) videos="${arg#videos=}" ;;
    youtube=*) youtube="${arg#youtube=}" ;;
    youtube_qualities=*) youtube_qualities="${arg#youtube_qualities=}" ;;
    holds=*) holds="${arg#holds=}" ;;
    hold_phases=*) hold_phases="${arg#hold_phases=}" ;;
    idle_pause=*) idle_pause="${arg#idle_pause=}" ;;
    settle=*) settle="${arg#settle=}" ;;
    *) echo "wallpaper-cost.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
work="$root/.build/wallpaper-cost"
rm -rf "$work"
mkdir -p "$work"
echo "WALLPAPER-COST-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) macos=$(sw_vers -productVersion) gpu=\"$(system_profiler SPDisplaysDataType 2>/dev/null | sed -n 's/^ *Chipset Model: //p' | head -n 1)\""
# A fleet step checks out no submodules: the app build needs Ghostty's headers and GhosttyKit.xcframework.
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
tag="wallpapercost"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$work/reload.log" || { tail -n 80 "$work/reload.log"; exit 1; }
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$work/reload.log" | tail -n 1)"
[[ -n "$app" && -d "$app" ]] || { echo "wallpaper-cost: reload printed no app path" >&2; tail -n 40 "$work/reload.log"; exit 1; }
driver=(python3 scripts/measure/wallpaper-cost.py --app "$app" --measure "$measure" --frame-rate "$frame_rate" --out "$work/rows.json")
[ -n "$ids" ] && driver+=(--ids "$ids")
[ -n "$picture" ] && driver+=(--picture "$picture")
[ -n "$videos" ] && driver+=(--videos "$videos")
[ -n "$youtube" ] && driver+=(--youtube "$youtube")
[ -n "$youtube_qualities" ] && driver+=(--youtube-qualities "$youtube_qualities")
[ -n "$holds" ] && driver+=(--holds "$holds")
[ -n "$hold_phases" ] && driver+=(--hold-phases "$hold_phases")
[ -n "$idle_pause" ] && driver+=(--idle-pause "$idle_pause")
[ -n "$settle" ] && driver+=(--settle "$settle")
driver+=(--work "$work/work")
# The test videos are made once per worker and kept in its shared cache (they depend on nothing in the checkout).
[ -n "${CI_SHARED_CACHE_DIR:-}" ] && driver+=(--clips "$CI_SHARED_CACHE_DIR/wallpaper-cost-clips")
# A fleet step has no LaunchServices session (`open` starts nothing there): launch the app as a child
# (bench_memory.py `launch`), which also attributes the WebKit processes it starts to it.
export CMUX_BENCH_LAUNCH="${CMUX_BENCH_LAUNCH:-direct}"
"${driver[@]}"
