#!/usr/bin/env bash
# Fleet entry for the omnibar mouse-down bench (omnibar-mousedown-latency): builds a tagged cmux-next
# DEBUG app at this checkout, then runs scripts/cmux-next/omnibar-click-bench.py (one click on the
# omnibar of a Chromium and a WebKit tab at rest, to the display frame that shows focus and the
# whole address selected; idle and under load), with the app active so key windows are real. Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/omnibar-click.sh --ref <sha> [--arg=--runs=20]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="omniclick"
out="$(mktemp -d)"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log" | tail -n 40
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "omnibar-click: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
mkdir -p artifacts
exec python3 scripts/cmux-next/omnibar-click-bench.py --tag "$tag" --app "$app" --out "$out" \
  --json artifacts/omnibar-click.json --activate "$@"
