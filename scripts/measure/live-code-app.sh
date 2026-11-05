#!/usr/bin/env bash
# Live code in the app, end to end on a fleet Mac (Packages/macOS/CmuxNext/Sources/CmuxNextLiveCode):
# builds the bench configuration as a live code build (scripts/live-code/build.sh), launches it with
# a live folder (it opens on Home), then edits HomeHostView.updateLayer: Home's background red,
# then blue, then red again as a bad patch, which a dropped `*.rollback` file undoes (blue again).
# Each edit is compiled into a patch (scripts/live-code/patch.py) and timed from the edit to the
# redraw, the rollback from the drop to the redraw; each generation's window snapshot is counted
# for red and blue pixels (cmuxterm-hq#7149 L3 and L4).
#   scripts/measure/live-code-app.sh OUT     (OUT: the log, the snapshots and result.json)
set -euo pipefail
out="$(mkdir -p "${1:?usage: live-code-app.sh OUT}" && cd "$1" && pwd)"
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
tag="live-code"
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
build_start=$SECONDS
app="$(scripts/live-code/build.sh "$out" "$tag" bench CMUX_DEV_BACKEND_MODE=local | tail -n 1)"
log="$out/xcodebuild.log"
python3 scripts/measure/live-code-app.py --app "$app" --log "$log" --out "$out" --build-seconds "$((SECONDS - build_start))"
