#!/usr/bin/env bash
# Fleet entry for the Cmd-Shift-Enter terminal zoom run (pane-zoom): builds a tagged cmux-next app at this
# checkout, then runs scripts/cmux-next/pane-zoom-terminal.py against it (zoom and unzoom of terminals in
# 1x2, 2x2 and 2x4 layouts with scrollback, optionally streaming; missed frames, layout work, grids sent to
# the PTY owner, hangs). Needs a logged-in console (an owned mini).
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/pane-zoom.sh \
#     --ref <sha> --artifact artifacts/pane-zoom/report.json [--arg=--rounds=3] [--arg=--stream] [--arg=--gate]
# To time an older commit, revert the change on a scratch ref of the tip (the script blob must match the reviewed one).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="pane-zoom"
out="$(pwd)/artifacts/pane-zoom"
mkdir -p "$out"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log" | tail -n 40
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "pane-zoom: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
exec python3 scripts/cmux-next/pane-zoom-terminal.py --tag "$tag" --app "$app" --out "$out" --json "$out/report.json" "$@"
