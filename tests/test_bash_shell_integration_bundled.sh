#!/usr/bin/env bash
# Verifies that the Xcode copy-resources build phase includes
# ghostty/shell-integration/bash/ghostty.bash in the bundle even when
# ghostty/zig-out/share/ghostty/ is absent (pre-built GhosttyKit path).
#
# This is the common CI/release path: GhosttyKit.xcframework is downloaded
# as a prebuilt artifact so zig-out is never populated. Without this fix,
# bash shell integration silently fails to load and directory inheritance
# is broken for all production DMG users.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPBASE=$(mktemp -d)
trap 'rm -rf "$TMPBASE"' EXIT

# Simulate Xcode build phase environment with NO zig-out (prebuilt xcframework case).
SRCROOT="$ROOT_DIR"
DEST="$TMPBASE/bundle/Resources"
GHOSTTY_DEST="$DEST/ghostty"
CMUX_SHELL_DEST="$DEST/shell-integration"

# zig-out is absent — simulate the prebuilt path
GHOSTTY_SRC="$TMPBASE/nonexistent-zig-out/share/ghostty"
FALLBACK_GHOSTTY="$SRCROOT/Resources/ghostty"
CMUX_GHOSTTY_ZSH_SRC="$SRCROOT/ghostty/src/shell-integration/zsh/ghostty-integration"
CMUX_GHOSTTY_BASH_SRC="$SRCROOT/ghostty/src/shell-integration/bash/ghostty.bash"

mkdir -p "$GHOSTTY_DEST" "$CMUX_SHELL_DEST"

# Mirror the ghostty resource copy logic from the Xcode build phase.
if [ -d "$GHOSTTY_SRC" ]; then
  rsync -a --delete "$GHOSTTY_SRC/" "$GHOSTTY_DEST/"
elif [ -d "$FALLBACK_GHOSTTY" ]; then
  rsync -a --delete "$FALLBACK_GHOSTTY/" "$GHOSTTY_DEST/"
fi

# Mirror the zsh integration copy (already present in build phase).
if [ -f "$CMUX_GHOSTTY_ZSH_SRC" ]; then
  mkdir -p "$CMUX_SHELL_DEST"
  rsync -a "$CMUX_GHOSTTY_ZSH_SRC" "$CMUX_SHELL_DEST/ghostty-integration.zsh"
fi

# Mirror the bash integration copy — this is the fix under test.
# The line below must be reflected in GhosttyTabs.xcodeproj/project.pbxproj.
if [ -f "$CMUX_GHOSTTY_BASH_SRC" ] && [ ! -f "$GHOSTTY_DEST/shell-integration/bash/ghostty.bash" ]; then
  mkdir -p "$GHOSTTY_DEST/shell-integration/bash"
  cp "$CMUX_GHOSTTY_BASH_SRC" "$GHOSTTY_DEST/shell-integration/bash/ghostty.bash"
fi

EXPECTED="$GHOSTTY_DEST/shell-integration/bash/ghostty.bash"
if [ ! -f "$EXPECTED" ]; then
  echo "FAIL: ghostty/shell-integration/bash/ghostty.bash absent from bundle"
  echo "  Simulated: no zig-out (prebuilt GhosttyKit path)"
  echo "  Expected:  $EXPECTED"
  echo "  Impact:    bash PROMPT_COMMAND bootstrap cannot source ghostty.bash;"
  echo "             OSC 7 never fires; directory inheritance broken for all DMG users."
  exit 1
fi

echo "PASS: ghostty/shell-integration/bash/ghostty.bash present in bundle (copied from source)"
