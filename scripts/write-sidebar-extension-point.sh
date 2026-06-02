#!/usr/bin/env bash
set -euo pipefail

# write-sidebar-extension-point.sh - emit the host's sidebar ExtensionKit point
# declaration at build time, keyed for the effective extension point id.
#
# Because the id can be scoped per dev build tag (via the
# CMUX_SIDEBAR_EXTENSION_POINT_ID build setting), a static checked-in bundle
# declaration can't carry it. AppExtensionPoint.Definition is only available in
# newer SDKs than cmux's macOS 14 floor, so this script writes the bundle-level
# declaration directly and intentionally avoids private underscored keys.
#
# The committed default is com.manaflow.cmux.sidebar; reload.sh overrides
# CMUX_SIDEBAR_EXTENSION_POINT_ID for tagged builds. The resolved id never
# touches tracked source.

POINT_ID="${CMUX_SIDEBAR_EXTENSION_POINT_ID:-com.manaflow.cmux.sidebar}"
if [[ -z "$POINT_ID" ]]; then
  POINT_ID="com.manaflow.cmux.sidebar"
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
    <key>EXExtensionPointIsPublic</key>
    <true/>
    <key>EXPresentsUserInterface</key>
    <true/>
  </dict>
</dict>
</plist>
EOF

echo "Wrote sidebar extension point declaration: $DEST"
