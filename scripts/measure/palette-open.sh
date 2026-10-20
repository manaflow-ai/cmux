#!/usr/bin/env bash
# Fleet entry for the palette open timing (palette-open-latency): builds a tagged cmux-next app at this checkout,
# then runs scripts/cmux-next/palette-open-stages.py against it (Cmd-Shift-P and Cmd-P from a terminal, a Chromium
# page, a WebKit page, Markdown and Home; key-down to the committed first frame, per stage).
# Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/palette-open.sh --ref <sha> [--arg=--rounds=10] [--arg=--no-gate]
# To time an older commit, cherry-pick the harness commit onto it (the script blob must match the reviewed one).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="palopen"
out="$(mktemp -d)"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log" | tail -n 40
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "palette-open: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
exec python3 scripts/cmux-next/palette-open-stages.py --tag "$tag" --app "$app" --out "$out" --json "$PWD/palette-open.json" "$@"
