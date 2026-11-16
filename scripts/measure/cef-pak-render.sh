#!/usr/bin/env bash
# Fleet entry for the CEF pak render check: builds a tagged cmux-next app at this checkout
# (its embed trims the CEF paks with cef-pak-drop.py), then runs
# scripts/cmux-next/cef-pak-render-check.py against it and packs its report and screenshots.
# Runs alone on a display worker because it launches an app:
#   cmux-ci run --class exclusive --display --label measure --script scripts/measure/cef-pak-render.sh --ref <sha> --artifact artifacts/cef-pak-render.tgz
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="cefpak"
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
out="$(mktemp -d)"
# Steps run with a per-step HOME; the account's user-level tools (bun and node for the Debug
# build's web bundles) live under its real home (as perf-bench.sh).
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
# The web bundles need the bun webviews/package.json pins; a bench host's shared ~/.bun may hold
# another version (cmux20-bench: none). The step gets its own checked copy, first on PATH.
RUNNER_TEMP="$out" GITHUB_PATH="$out/bun-path" ./scripts/cmux-next/private-bun.sh
PATH="$(tail -n 1 "$out/bun-path"):$PATH"
export PATH
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "cef-pak-render: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
mkdir -p artifacts
status=0
python3 scripts/cmux-next/cef-pak-render-check.py --tag "$tag" --app "$app" --out "$out/render" "$@" || status=$?
tar -czf artifacts/cef-pak-render.tgz -C "$out" render
exit "$status"
