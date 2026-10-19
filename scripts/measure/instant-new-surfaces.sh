#!/usr/bin/env bash
# Fleet entry for the instant-create bench (Cmd-N, Cmd-T, Cmd-D, Cmd-Shift-D): builds a tagged
# cmux-next DEBUG app at this checkout, then runs scripts/cmux-next/instant-new-surfaces-bench.py
# (key to visible frame and to daemon confirm, idle and under load). Runs alone on the worker
# because it launches an app and loads every core:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/instant-new-surfaces.sh --ref <sha> [--arg=--runs=12]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="instantnew"
out="$(mktemp -d)"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log" | tail -n 40
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "instant-new-surfaces: the tagged reload printed no app path" >&2
  exit 1
fi
mkdir -p artifacts
exec python3 scripts/cmux-next/instant-new-surfaces-bench.py --tag "$tag" --app "$app" --out "$out" \
  --json artifacts/instant-new-surfaces.json "$@"
