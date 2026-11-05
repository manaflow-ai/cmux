#!/usr/bin/env bash
# Live code in the app, end to end on a fleet Mac (Packages/macOS/CmuxNext/Sources/CmuxNextLiveCode):
# builds the bench configuration with CMUX_LIVE_CODE_BUILD=1, launches it with a live folder,
# shows the right sidebar's vault, then edits VaultListView.swift twice (its background red, then
# blue), compiles each edit into a patch (scripts/live-code/patch.py) and times the edit to the
# redraw. The window's snapshots before and after each patch are counted for red and blue pixels.
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
# A failed build is reported below, from its log, so the pipeline's status is not the step's.
CMUX_LIVE_CODE_BUILD=1 CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --config bench 2>&1 | tee "$out/reload.log" || true
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
log="$(sed -n 's/^==> log: //p' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "live-code-app: the reload printed no app path" >&2
  [[ -n "$log" && -f "$log" ]] && grep -E "\.swift:[0-9]+:[0-9]+: error|error: " "$log" | head -n 40 >&2
  exit 1
fi
echo "live-code-app: built in $((SECONDS - build_start)) s"
# The patch compiles from this log; keep CmuxNextApp's lines with the results.
grep -E -- "-module-name CmuxNextApp " "$log" > "$out/cmuxnextapp-commands.log" || true
python3 scripts/measure/live-code-app.py --app "$app" --log "$log" --out "$out" --build-seconds "$((SECONDS - build_start))"
