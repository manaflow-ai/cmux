#!/usr/bin/env bash
# Fleet entry for cursor-look: macOS's own pointer next to the screen-sharing viewer's drawing of the
# same cursor (scripts/measure/cursor-look/CursorLook.swift), light and dark, one enlarged image each.
# It shows a window and moves the pointer, so it needs a logged-in console: a display step.
#   cmux-ci run --class light --display --script scripts/measure/cursor-look.sh --ref <sha> \
#     --artifact artifacts/cursor-look [--arg arrow --arg ibeam --arg hand]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
out="$(pwd)/artifacts/cursor-look"
mkdir -p "$out"
swiftc -O -o "$out/CursorLook" scripts/measure/cursor-look/CursorLook.swift
"$out/CursorLook" "$out/light" "$@"
"$out/CursorLook" "$out/dark" --dark "$@"
rm -f "$out/CursorLook"
ls -l "$out"/light/cursor-look.png "$out"/dark/cursor-look.png
