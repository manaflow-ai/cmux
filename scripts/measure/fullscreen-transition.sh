#!/usr/bin/env bash
# Fleet entry for the full screen lag and layout run (fullscreen-lag): builds a tagged cmux-next app at
# this checkout, then runs scripts/cmux-next/fullscreen-transition.py against it (enter and leave full
# screen through the action, Ctrl-Cmd-F and the green button; resizes, layout passes, terminal resizes,
# missed frames, and the top row's place before and after). Needs a logged-in console (an owned mini).
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/fullscreen-transition.sh \
#     --ref <sha> --artifact artifacts/fullscreen/report.json [--arg=--rounds=3] [--arg=--spaces]
# To time an older commit, revert the change on a scratch ref of the tip (the script blob must match the reviewed one).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers (GhosttyKit itself comes
# from the pinned cache) and ghostty-next for the bundled cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="fullscreen"
out="$(pwd)/artifacts/fullscreen"
mkdir -p "$out"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log" | tail -n 40
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "fullscreen: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
exec python3 scripts/cmux-next/fullscreen-transition.py --tag "$tag" --app "$app" --out "$out" --json "$out/report.json" "$@"
