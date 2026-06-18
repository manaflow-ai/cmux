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
find "$EXTENSIONS_DIR" -maxdepth 1 -name '*.appextensionpoint' -delete

DEST="${EXTENSIONS_DIR}/${POINT_ID}.appextensionpoint"
cat > "$DEST" <<EOF
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

echo "Wrote sidebar extension point declaration: $DEST"
