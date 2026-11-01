#!/usr/bin/env bash
# Main-queue wait while a host context menu tracks, opened from a main-queue job (before) or from a
# main run-loop block (after, MainRunLoopBlock), in a real NSApplication run loop:
#   cmux-ci run --class light --script scripts/measure/menu-tracking-main-queue.sh --ref SHA --timeout 900
# Output: MENU-TRACKING lines (median of 7 rounds of a 400 ms menu): the worst and median wait of
# main-queue jobs queued while it was open, and how long their backlog kept the main thread busy
# after it closed (the closing click waits that long). No GUI session needed: the menu is the
# event-tracking-mode run loop NSMenu.popUp runs, without drawing.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${TMPDIR:-/tmp}/menu-tracking-main-queue.$$"
mkdir -p "$out"
trap 'rm -rf "$out"' EXIT
xcrun swiftc -O -o "$out/bench" "$here/menu-tracking-main-queue.swift"
"$out/bench"
