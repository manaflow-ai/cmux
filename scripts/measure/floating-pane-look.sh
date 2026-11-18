#!/usr/bin/env bash
# Fleet entry for the floating pane look: builds a tagged cmux-next app at this checkout, then runs
# scripts/cmux-next/floating-pane-look.py against it. The driver makes a pane float (it sends the daemon's
# `float-pane`, which no action and no key of the app sends), sets the Debug Settings knob `Background opacity`
# (floatingPane.backgroundOpacity) to 1 and to a value below 1, and takes the app's own picture of its window for
# each state: a terminal pane and a page pane, with a background picture and without. The pictures are a record
# for a person to look at; nothing here judges a picture.
# Runs alone on the worker because it launches an app and shows a window:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/floating-pane-look.sh --ref <sha> \
#     --artifact floating-pane-look.tar [--arg=--opacity=0.5]
# Every argument goes to the driver. The artifact: report.json (each reply, the screen's floating list, the shown
# panes' frames), 01 to 06 .png and the app's log.
# Exit: the driver's. 0 when report.json and at least 1 picture are written (the report says which step failed);
# 3 when no picture was written; 1 when the build printed no app.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="floatlook"
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
app=""
# shellcheck disable=SC2317,SC2329 # run by the trap below
cleanup() {
  if [[ -n "$app" && -d "$app" ]]; then python3 scripts/cmux-next/tag_teardown.py "$app" || true; fi
  rm -rf -- "$out"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Steps run with a per-step HOME; the account's user-level tools (bun and node for the Debug
# build's web bundles) live under its real home (as clear-cache-look.sh).
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
# The web bundles need the bun webviews/package.json pins; the step gets its own checked copy, first on PATH.
RUNNER_TEMP="$out" GITHUB_PATH="$out/bun-path" ./scripts/cmux-next/private-bun.sh
PATH="$(tail -n 1 "$out/bun-path"):$PATH"
export PATH
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "floating-pane-look: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
status=0
python3 scripts/cmux-next/floating-pane-look.py --tag "$tag" --app "$app" --out "$out/look" "$@" || status=$?
if [ -f "$out/look/report.json" ]; then
  (cd "$out/look" && find . -maxdepth 1 \( -name 'report.json' -o -name '*.png' -o -name '*.log' \) -print0 \
    | tar -cf "$OLDPWD/floating-pane-look.tar" --null -T -) || true
  echo "floating-pane-look: artifact $(du -h floating-pane-look.tar 2>/dev/null | cut -f1)"
fi
exit "$status"
