#!/usr/bin/env bash
# Repro: rapid OSC 0/2 title updates saturate the main thread and starve scroll.
#
# Run this inside a cmux DEV terminal pane, then try to scroll a large file in
# another pane (e.g. `cat ~/some-large-log` in a split, then mouse-wheel through
# its scrollback). On a build without coalescing, scroll is jerky while this
# loop runs. With the fix, scroll stays smooth.
#
# Stops on Ctrl-C.

set -u

i=0
while true; do
  printf '\033]0;t-%d\a' "$i"
  i=$((i + 1))
done
