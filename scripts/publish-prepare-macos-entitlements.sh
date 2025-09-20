#!/usr/bin/env bash
set -euo pipefail

# Create macOS entitlements file for Electron signing for publish workflows.
# Writes to apps/client/build/entitlements.mac.plist to align with electron-builder config.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLIENT_DIR="$ROOT_DIR/apps/client"
BUILD_DIR="$CLIENT_DIR/build"
ENTITLEMENTS_FILE="$BUILD_DIR/entitlements.mac.plist"

mkdir -p "$BUILD_DIR"

if [[ ! -f "$ENTITLEMENTS_FILE" ]]; then
  cat > "$ENTITLEMENTS_FILE" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-jit</key>
  <true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
  <true/>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
  <key>com.apple.security.cs.debugger</key>
  <true/>
  <key>com.apple.security.network.client</key>
  <true/>
  <key>com.apple.security.network.server</key>
  <true/>
</dict>
</plist>
PLIST
  echo "Created entitlements: $ENTITLEMENTS_FILE"
else
  echo "Entitlements already present: $ENTITLEMENTS_FILE (no changes)"
fi
