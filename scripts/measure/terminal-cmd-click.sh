#!/usr/bin/env bash
# Fleet entry for the terminal Cmd-click live check (cx-7xss): builds a tagged
# cmux-next app at this checkout, then runs scripts/cmux-next/terminal-cmd-click-e2e.py
# against it (Cmd-click through debug.mouse; no main-thread stall over 50 ms).
# Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/terminal-cmd-click.sh --ref <sha> [--arg=--file]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="cmdclick"
out="$(mktemp -d)"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "terminal-cmd-click: the tagged reload printed no app path" >&2
  exit 1
fi
exec python3 scripts/cmux-next/terminal-cmd-click-e2e.py --tag "$tag" --app "$app" --out "$out" "$@"
