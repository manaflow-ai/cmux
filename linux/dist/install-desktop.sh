#!/bin/bash
# Install cmux desktop entry and icons for Linux desktop integration.
# This ensures taskbars/panels can match the app_id (ai.manaflow.cmux)
# to the correct .desktop file and icon.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ID="ai.manaflow.cmux"

DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_BASE="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"

# Install .desktop file
mkdir -p "$DESKTOP_DIR"
cp "$SCRIPT_DIR/$APP_ID.desktop" "$DESKTOP_DIR/$APP_ID.desktop"
echo "Installed $DESKTOP_DIR/$APP_ID.desktop"

# Install icons at standard sizes
for size in 16 32 48 64 128 256 512; do
    icon_dir="$ICON_BASE/${size}x${size}/apps"
    mkdir -p "$icon_dir"
    cp "$SCRIPT_DIR/icons/$APP_ID-${size}.png" "$icon_dir/$APP_ID.png"
    echo "Installed ${size}x${size} icon"
done

# Update caches
if command -v gtk-update-icon-cache &>/dev/null; then
    gtk-update-icon-cache -f -t "$ICON_BASE" 2>/dev/null || true
fi
if command -v update-desktop-database &>/dev/null; then
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
fi

echo "Done. You may need to restart your panel/taskbar for changes to take effect."
