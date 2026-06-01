#!/usr/bin/env bash
set -euo pipefail

# write-sidebar-extension-point.sh — emit the host's sidebar ExtensionKit point
# declaration at build time, keyed for the effective extension point id.
#
# The sidebar extension point is declared by a file
# `Contents/Extensions/<id>.appextensionpoint` whose FILENAME and top-level dict
# KEY are both the point id. Because the id can be scoped per dev build tag (via
# the CMUX_SIDEBAR_EXTENSION_POINT_ID build setting), a static checked-in resource
# can't carry it. This Run Script writes the declaration into the built bundle
# before code signing, so Xcode produces a coherent, normally-signed,
# pkd-ingestible bundle (unlike post-build mutation of a sealed bundle).
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

# Remove any stale declarations so the bundle contains exactly one, named for the
# effective id (guards against an old id lingering across incremental builds).
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
		<key>_EXScopeRestriction</key>
		<string>none</string>
	</dict>
</dict>
</plist>
EOF

echo "Wrote sidebar extension point declaration: $DEST"
