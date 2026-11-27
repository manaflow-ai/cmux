#!/usr/bin/env bash
# Fleet entry for the Chromium host bench (hot path `cef-host-input`, scripts/cmux-next/perf-hot-benches.json;
# plans/cmux-next/cef-helper-app-DESIGN.md): builds a tagged Debug cmux-next app at this checkout (the host app
# `<App> Chromium Host.app` is embedded in Debug builds only), then runs scripts/cmux-next/chromium-host-bench.py:
# in process against the host app, key and click to the page's next frame, frame pacing, the wire's round trip
# (`ping_us`), the host's input hop (`hop_us`), the in-process pump share of cmux's main thread, and the kill check.
# Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/chromium-host-bench.sh \
#     --ref <sha> --artifact artifacts/chromium-host-bench.json [--arg=--count=60] [--arg=--stress]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="chromiumhost"
# A fleet step checks out no submodules (only their empty gitlink directories): the app build needs
# Ghostty's headers and the ghostty-next tree, and GhosttyKit.xcframework (a prebuilt download).
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
bun_dir="$PWD/.build/chromium-host-bench-bun"
mkdir -p "$bun_dir"
# Steps run with a per-step HOME; the account's user-level tools (bun and node for the Debug
# build's web bundles) live under its real home (as perf-bench.sh).
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
# The web bundles need the bun webviews/package.json pins; a bench host's shared ~/.bun may hold
# another version (cmux20-bench: none). The step gets its own checked copy, first on PATH.
RUNNER_TEMP="$PWD/.build/chromium-host-bench-bun" GITHUB_PATH="$bun_dir/bun-path" ./scripts/cmux-next/private-bun.sh
PATH="$(tail -n 1 "$bun_dir/bun-path"):$PATH"
export PATH
out="$PWD/artifacts/chromium-host-bench"
mkdir -p "$out"
echo "CHROMIUM-HOST-BENCH-HOST host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) macos=$(sw_vers -productVersion)"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --no-global-cli-links 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "chromium-host-bench: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
exec python3 scripts/cmux-next/chromium-host-bench.py --app "$app" --out "$out" \
  --json "$PWD/artifacts/chromium-host-bench.json" "$@"
