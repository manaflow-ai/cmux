#!/usr/bin/env bash
# Re-compress a DMG in place with ULMO (LZMA). Invalidates any existing DMG
# signature, so callers must codesign the DMG after this script returns.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 /path/to/image.dmg" >&2
  exit 1
fi

DMG_PATH="$1"

if [ ! -f "$DMG_PATH" ]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

TMP_PATH="${DMG_PATH%.dmg}-ulmo.dmg"
rm -f "$TMP_PATH"
hdiutil convert "$DMG_PATH" -format ULMO -o "$TMP_PATH"
mv "$TMP_PATH" "$DMG_PATH"
ls -la "$DMG_PATH"
