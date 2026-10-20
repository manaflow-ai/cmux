#!/usr/bin/env bash
# Fleet entry for the per-stage tab switch timing (tab-switch-fast): builds a tagged cmux-next app at
# this checkout, then runs scripts/cmux-next/tab-switch-stages.py against it (terminal, Chromium,
# WebKit and Markdown tabs in one pane; Ctrl-Tab, Ctrl-Shift-Tab and strip clicks; per-stage ms).
# Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/tab-switch.sh --ref <sha> [--arg=--rounds=12]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="tabswitch"
out="$(mktemp -d)"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log" | tail -n 40
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "tab-switch: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
exec python3 scripts/cmux-next/tab-switch-stages.py --tag "$tag" --app "$app" --out "$out" "$@"
