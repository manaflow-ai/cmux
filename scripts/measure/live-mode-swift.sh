#!/usr/bin/env bash
# Swift live mode end to end on a fleet Mac (docs/cmux-next/live-code.md, "Live mode"): builds a
# tagged DEV app the normal way (scripts/reload.sh --tag), opens it with three workspaces, then runs
# its driver (scripts/measure/live-mode-swift.py, from the step's checkout): `live-mode.py start`
# builds the live code build of the same commit and restarts into it, a Swift body
# (HomeHostView.updateLayer) is patched in, and `live-mode.py stop` restarts into the normal build.
# result.json has both restart times and whether every workspace, tab and running terminal was kept.
#   scripts/measure/live-mode-swift.sh OUT     (OUT: result.json, the live code log, a snapshot)
set -euo pipefail
out="$(mkdir -p "${1:?usage: live-mode-swift.sh OUT}" && cd "$1" && pwd)"
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
tag="live-mode-e2e"
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
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/normal-build.log" >&2
app="$(awk '/^App path:/{getline; sub(/^ +/, ""); print; exit}' "$out/normal-build.log")"
[ -d "$app" ] || { echo "live-mode-swift: no app path in the build log" >&2; exit 1; }
python3 scripts/measure/live-mode-swift.py --app "$app" --tag "$tag" --out "$out" --build-seconds "$((SECONDS - build_start))"
