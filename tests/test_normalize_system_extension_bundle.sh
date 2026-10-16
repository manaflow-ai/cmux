#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/normalize-system-extension-bundle.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

APP="$TMP_DIR/cmux.app"
OLD="$APP/Contents/Library/SystemExtensions/cmuxTunnel.systemextension"
mkdir -p "$OLD/Contents"
cat > "$OLD/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.cmuxterm.app.nightly.tunnel</string>
</dict>
</plist>
PLIST

"$SCRIPT" "$APP" "com.cmuxterm.app.nightly.tunnel" >/dev/null
NEW="$APP/Contents/Library/SystemExtensions/com.cmuxterm.app.nightly.tunnel.systemextension"
[[ -d "$NEW" ]] || { echo "FAIL: extension was not renamed" >&2; exit 1; }

# The operation is idempotent after the first packaging pass.
"$SCRIPT" "$APP" "com.cmuxterm.app.nightly.tunnel" >/dev/null

if "$SCRIPT" "$APP" "com.cmuxterm.app.release.tunnel" >/dev/null 2>&1; then
  echo "FAIL: accepted a mismatched bundle identifier" >&2
  exit 1
fi

echo "PASS: normalize-system-extension-bundle.sh"
