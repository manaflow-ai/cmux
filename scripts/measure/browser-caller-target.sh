#!/usr/bin/env bash
# Fleet entry for the #26648 two-window check: builds a tagged cmux-next DEBUG app at this checkout,
# then runs scripts/cmux-next/browser-caller-target-e2e.py (an agent terminal in window B drives the
# browser in its own workspace through the real cmux CLI while the person's focused browser is in
# window A). The app runs without activation, as every fleet bench. Runs alone on the worker because it
# launches an app:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/browser-caller-target.sh --ref <sha>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers and ghostty-next for the bundled cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="callertgt"
out="$(mktemp -d)"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "browser-caller-target: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
mkdir -p artifacts/browser-caller-target
status=0
python3 scripts/cmux-next/browser-caller-target-e2e.py --app "$app" --out artifacts/browser-caller-target || status=$?
cat artifacts/browser-caller-target/steps.json 2>/dev/null | head -c 20000 || true
exit "$status"
