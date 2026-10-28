#!/usr/bin/env bash
# Fleet entry for the Chromium renderer sharing bench (plans/cmux-next/tab-lifecycle.md, "Renderer
# sharing"; Lawrence 2026-10-24: "copy Chrome: max 2 same-site tabs per renderer"): builds a tagged
# cmux-next DEV app at this checkout, then runs scripts/cmux-next/bench_renderer_sharing.py: 100
# Chromium tabs over 20 sites (siteN.test on one local server), each shown and timed from the open
# action to its title; then renderers, tabs per renderer, footprint (renderers, app, total, shared).
# An agent's CDP session stays on the first tab (--agent-cdp; --arg=--no-agent-cdp drops it): the run
# fails unless same-site tabs still share, 2 main frames per renderer below the limit, which needs fork
# API 29 and cmux-process-reuse-per-renderer-devtools (p07-memory 046).
# --arg=--memory-cap-mb=256 (p07-memory 111) starts Chromium with a 256 MiB shared-renderer memory cap and
# grows a page past it: the next tab of that site must start a new renderer below the limit (a fork with
# cmux_shared_renderer_memory_cap).
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
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --no-global-cli-links 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "renderer-sharing: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
# The bench runs the app binary as its child (bench_launch.BenchApp): a fleet step has no LaunchServices session.
python3 scripts/cmux-next/bench_renderer_sharing.py --app "$app" --out "$out/report.json" --agent-cdp "$@"
