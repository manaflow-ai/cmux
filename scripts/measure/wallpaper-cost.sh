#!/usr/bin/env bash
# What a live wallpaper costs (plans/cmux-next/live-wallpapers.md, "Cost"): the app's CPU time per second, the
# wallpaper's GPU time per second and the app's phys_footprint, 60 s each, for a painting (the baseline), each
# live wallpaper (the pointer moving over the window), idle, occluded, minimized and Low Power Mode.
# Builds a tagged app at this checkout (reload.sh) and runs scripts/measure/wallpaper-cost.py on it.
# Run alone on a fleet Mac nobody is using (it launches an app and moves the pointer):
#   cmux-ci run --class exclusive --measurement --label measure \
#     --script scripts/measure/wallpaper-cost.sh --ref SHA [--arg=measure=60] [--arg=ids=orbits,metal] \
#     [--arg=frame_rate=30] [--arg=picture=van-gogh-starry-night]
# Output: WALLPAPER-COST lines (scripts/bench/benches/wallpaper_cost.py reads them); JSON under .build/wallpaper-cost.
set -euo pipefail
measure=60 ids="" frame_rate=30 picture=""
reload_config=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    measure=*) measure="${arg#measure=}" ;;
    ids=*) ids="${arg#ids=}" ;;
    frame_rate=*) frame_rate="${arg#frame_rate=}" ;;
    picture=*) picture="${arg#picture=}" ;;
    *) echo "wallpaper-cost.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
cd "$root"
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
"${driver[@]}"
