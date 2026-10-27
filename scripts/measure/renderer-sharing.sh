#!/usr/bin/env bash
# Fleet entry for the Chromium renderer sharing bench (plans/cmux-next/tab-lifecycle.md, "Renderer
# sharing"; Lawrence 2026-10-24: "copy Chrome: max 2 same-site tabs per renderer"): builds a tagged
# cmux-next DEV app at this checkout, then runs scripts/cmux-next/bench_renderer_sharing.py: 100
# Chromium tabs over 20 sites (siteN.test on one local server), each shown and timed from the open
# action to its title; then renderers, tabs per renderer, footprint (renderers, app, total, shared).
# Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/renderer-sharing.sh \
#     --ref <sha> --artifact artifacts/renderer-sharing/report.json [--arg=--tabs=100] [--arg=--sites=20]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers (GhosttyKit itself comes
# from the pinned cache) and ghostty-next for the bundled cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="rsharing"
out="$PWD/artifacts/renderer-sharing"
mkdir -p "$out"
echo "PERF-RENDERERS-HOST host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion)"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --no-global-cli-links 2>&1 | tee "$out/reload.log" | tail -n 40
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "renderer-sharing: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
# A fleet step has no LaunchServices session: run the app binary itself (bench_memory.launch).
CMUX_BENCH_LAUNCH=direct python3 scripts/cmux-next/bench_renderer_sharing.py --app "$app" --out "$out/report.json" "$@"
