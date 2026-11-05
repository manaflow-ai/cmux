#!/usr/bin/env bash
# Fleet entry for the CEF pump wakes bench (HOT PATH AUDIT browser; SWITCH FRAMES STATUS 9946: the Chromium message
# pump woke the main thread 8 -> 74 -> 104 times/s as busy hidden terminals went 0 -> 8 -> 24, with no browser tab):
# builds a tagged DEV app at this checkout, then runs scripts/cmux-next/cef-pump-wakes-bench.py: busy hidden terminals
# of three kinds (print only, spawn only, both), the pump's main-thread wakes per requesting Chromium thread, and with
# --trace the tasks Chromium ran on its UI thread by posting location. Measures only; no gate.
# Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/cef-pump-wakes.sh \
#     --ref <sha> --artifact artifacts/cef-pump-wakes.json [--arg=--trace] [--arg=--counts=0,8,24]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers (GhosttyKit itself comes
# from the pinned cache) and ghostty-next for the bundled cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="cefpumpwakes"
out="$PWD/artifacts/cef-pump-wakes"
mkdir -p "$out"
echo "CEF-PUMP-WAKES-HOST host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) macos=$(sw_vers -productVersion)"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --no-global-cli-links 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "cef-pump-wakes: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
exec python3 scripts/cmux-next/cef-pump-wakes-bench.py --app "$app" --out "$out" --json "$PWD/artifacts/cef-pump-wakes.json" "$@"
