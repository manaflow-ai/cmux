#!/usr/bin/env bash
set -euo pipefail

# Emits the host's Sidebar ExtensionKit point declaration for Xcode 14-era
# ExtensionKit. The point id may be scoped per tagged dev build.

POINT_ID="${CMUX_SIDEBAR_EXTENSION_POINT_ID:-com.cmuxterm.app.cmux.sidebar}"
if [[ -z "$POINT_ID" ]]; then
  POINT_ID="com.cmuxterm.app.cmux.sidebar"
fi

EXTENSIONS_DIR="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Extensions"
mkdir -p "$EXTENSIONS_DIR"

DEST="${EXTENSIONS_DIR}/${POINT_ID}.appextensionpoint"
DECLARATION="$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>${POINT_ID}</key>
  <dict>
    <key>_EXScopeRestriction</key>
    <string>none</string>
    <key>EXExtensionPointIsPublic</key>
    <true/>
    <key>EXPresentsUserInterface</key>
    <true/>
  </dict>
</dict>
</plist>
EOF
)"

# Keep the phase running for tag changes and missing/corrupt outputs, but do not
# replace an unchanged declaration and dirty the app bundle on every build.
find "$EXTENSIONS_DIR" -maxdepth 1 -name '*.appextensionpoint' ! -path "$DEST" -delete
if [[ ! -L "$DEST" ]] && cmp -s "$DEST" <(printf '%s\n' "$DECLARATION"); then
  exit 0
fi

TEMP="$(mktemp "$EXTENSIONS_DIR/.cmux-extension-point.XXXXXX")"
trap 'rm -f "$TEMP"' EXIT
printf '%s\n' "$DECLARATION" > "$TEMP"
chmod 644 "$TEMP"
# Do not follow an existing destination symlink, including one to a directory.
if [[ -L "$DEST" ]]; then
  rm -f "$DEST"
elif [[ -d "$DEST" ]]; then
  rmdir "$DEST"
fi
mv -f "$TEMP" "$DEST"
echo "Wrote sidebar extension point declaration: $DEST"
