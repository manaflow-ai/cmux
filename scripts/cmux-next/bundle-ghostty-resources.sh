#!/usr/bin/env bash
# Xcode "Bundle Ghostty resources" phase of the cmux-next target: copies the
# Ghostty themes, terminfo (plus cmux's overlay), and shell integration into
# <app>/Contents/Resources, where GhosttyRuntime points GHOSTTY_RESOURCES_DIR.
#
# The same sources as scripts/build-app-bundled-resources.sh (the legacy
# target's phase) without its helper builds (ghostty CLI helper, cmux-cua),
# which the cmux-next app does not ship yet. Sources, in order:
#   ghostty/zig-out/share/{ghostty,terminfo}  (a local zig build), else
#   Resources/ghostty/{themes,terminfo}        (checked in),
#   Resources/terminfo-overlay, ghostty/src/shell-integration,
#   Resources/shell-integration.
set -euo pipefail

dest="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
share="${SRCROOT:?}/ghostty/zig-out/share"

sync_dir() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  rsync -a --delete "$src/" "$dst/"
}

if [[ -d "$share/ghostty" ]]; then
  sync_dir "$share/ghostty" "$dest/ghostty"
elif [[ -d "$SRCROOT/Resources/ghostty" ]]; then
  sync_dir "$SRCROOT/Resources/ghostty" "$dest/ghostty"
else
  echo "warning: no Ghostty resources found; themes will not resolve"
fi

if [[ -d "$SRCROOT/ghostty/src/shell-integration" ]]; then
  sync_dir "$SRCROOT/ghostty/src/shell-integration" "$dest/ghostty/shell-integration"
fi

if [[ -d "$share/terminfo" ]]; then
  sync_dir "$share/terminfo" "$dest/terminfo"
elif [[ -d "$SRCROOT/Resources/ghostty/terminfo" ]]; then
  sync_dir "$SRCROOT/Resources/ghostty/terminfo" "$dest/terminfo"
fi
if [[ -d "$SRCROOT/Resources/terminfo-overlay" ]]; then
  mkdir -p "$dest/terminfo"
  rsync -a "$SRCROOT/Resources/terminfo-overlay/" "$dest/terminfo/"
fi

if [[ -d "$SRCROOT/Resources/shell-integration" ]]; then
  sync_dir "$SRCROOT/Resources/shell-integration" "$dest/shell-integration"
fi
echo "bundled Ghostty resources into $dest"
