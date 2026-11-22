#!/usr/bin/env bash
# The Computer Use behaviour suite under duress, live on a Mac's screen (evals/computer-use,
# `python3 -m cueval duress`). Leo, 2026-11-22: "WHAT THE FUCK IS OUR SUITE TO CHECK THE FUCKING
# CORRECTNESS AND BEHAVIOUR OF THIS. WHERE IS THE FUCKING CURSOR. WHAT FUCKING VERSION OF OUR
# COMPUTER USE DID YOU GUYS EVEN FUCKING USE!?"
#
# It drives cmux NEXT's Computer Use MCP bridge (`acpmux computer-use-mcp`, the one every agent
# session gets) against the eval's scratch form window, under CPU load, while the eval's own
# person window (focused) types in-process. It checks: the frontmost app never changes, no agent
# input reaches the person's window, the agent cursor is drawn, every result names the driver's
# version and build, and classic cmux (com.cmuxterm.app) is never started or brought forward.
#
#   cmux-ci run --class exclusive --measurement --display --label macos-26 \
#     --script scripts/measure/cu-duress-suite.sh --ref SHA \
#     --artifact artifacts/cu-duress-suite.tgz --timeout 1800
#
# The bridge comes from an installed cmux NEXT app (never classic cmux: its bundle id must not be
# com.cmuxterm.app), or CUEVAL_CMUX_CU_COMMAND (a JSON array). Output: DURESS lines, and
# artifacts/cu-duress-suite.tgz with duress.json and the bridge's stderr. Exit: 0 when every
# check passes, 1 when one fails (known reds included), 4 when no NEXT bridge is installed.
set -uo pipefail
root="$(git rev-parse --show-toplevel)"
cd "$root"
out="$root/artifacts/cu-duress-suite"
rm -rf "$out" "$root/artifacts/cu-duress-suite.tgz"
mkdir -p "$out"
finish() { tar -czf "$root/artifacts/cu-duress-suite.tgz" -C "$root/artifacts" cu-duress-suite; }
trap finish EXIT

if [[ -z "${CUEVAL_CMUX_CU_COMMAND:-}" ]]; then
  bridge=""
  for app in /Applications/*.app "$HOME"/Applications/*.app; do
    [[ -x "$app/Contents/Resources/bin/acpmux" ]] || continue
    plist="$app/Contents/Info.plist"
    [[ -f "$plist" ]] || continue
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
    [[ "$id" == com.cmuxterm.* && "$id" != "com.cmuxterm.app" ]] || continue
    bridge="$app/Contents/Resources/bin/acpmux"
    echo "DURESS bridge $bridge ($id)"
    break
  done
  if [[ -z "$bridge" ]]; then
    echo "DURESS blocked: no cmux NEXT app with Contents/Resources/bin/acpmux on this worker" | tee "$out/blocked.txt"
    exit 4
  fi
  CUEVAL_CMUX_CU_COMMAND="$(python3 -c 'import json,sys; print(json.dumps([sys.argv[1], "computer-use-mcp"]))' "$bridge")"
  export CUEVAL_CMUX_CU_COMMAND
fi
cd "$root/evals/computer-use"
python3 -X faulthandler -m cueval duress --out "$out"
