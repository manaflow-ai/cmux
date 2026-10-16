#!/usr/bin/env bash
# Embed the Developer ID provisioning profile for the cmux Cloud tunnel system
# extension into a built app bundle, verifying it names the expected App ID and
# grants the packet-tunnel system-extension capability.
#
# Usage:
#   scripts/ci/embed-tunnel-extension-profile.sh <app-path> <expected-app-id> <profile-base64>
#
# Missing or invalid signing material is an error. Nightly and Stable must not
# ship a browser path that cannot start its Network Extension.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <app-path> <expected-app-id> <profile-base64>" >&2
  exit 2
fi

APP_PATH="$1"
EXPECTED_APP_ID="$2"
PROFILE_BASE64="$3"
SYSTEM_EXTENSIONS_DIR="$APP_PATH/Contents/Library/SystemExtensions"

if [[ -z "$PROFILE_BASE64" ]]; then
  echo "error: missing Cloud tunnel extension provisioning profile" >&2
  exit 1
fi

if [[ ! -d "$SYSTEM_EXTENSIONS_DIR" ]]; then
  echo "error: a tunnel extension profile was provided but $SYSTEM_EXTENSIONS_DIR does not exist in the built app" >&2
  exit 1
fi

SYSEXT="$(find "$SYSTEM_EXTENSIONS_DIR" -mindepth 1 -maxdepth 1 -name '*.systemextension' | head -1)"
if [[ -z "$SYSEXT" ]]; then
  echo "error: no .systemextension bundle under $SYSTEM_EXTENSIONS_DIR" >&2
  exit 1
fi

TMP_PROFILE="$(mktemp "${TMPDIR:-/tmp}/cmux-tunnel-profile.XXXXXX")"
TMP_PLIST="$(mktemp "${TMPDIR:-/tmp}/cmux-tunnel-profile.XXXXXX.plist")"
trap 'rm -f "$TMP_PROFILE" "$TMP_PLIST"' EXIT

printf '%s' "$PROFILE_BASE64" | base64 --decode > "$TMP_PROFILE"
# A real profile is CMS-wrapped; tests may pass an already-decoded plist.
if ! /usr/bin/security cms -D -i "$TMP_PROFILE" > "$TMP_PLIST" 2>/dev/null; then
  if plutil -lint "$TMP_PROFILE" >/dev/null 2>&1; then
    cp "$TMP_PROFILE" "$TMP_PLIST"
  else
    echo "error: the tunnel extension profile is neither a CMS-wrapped provisioning profile nor a plist" >&2
    exit 1
  fi
fi

APP_ID="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$TMP_PLIST" 2>/dev/null || true)"
if [[ "$APP_ID" != "$EXPECTED_APP_ID" ]]; then
  echo "error: tunnel extension profile targets '$APP_ID', expected '$EXPECTED_APP_ID'" >&2
  exit 1
fi

if ! /usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.networking.networkextension" "$TMP_PLIST" 2>/dev/null \
    | grep -q "packet-tunnel-provider-systemextension"; then
  echo "error: tunnel extension profile does not grant packet-tunnel-provider-systemextension" >&2
  exit 1
fi

PROVISIONS_ALL_DEVICES="$(/usr/libexec/PlistBuddy -c "Print :ProvisionsAllDevices" "$TMP_PLIST" 2>/dev/null || true)"
if [[ "$PROVISIONS_ALL_DEVICES" != "true" ]]; then
  echo "error: tunnel extension profile is not a Developer ID all-devices profile" >&2
  exit 1
fi

cp "$TMP_PROFILE" "$SYSEXT/Contents/embedded.provisionprofile"
echo "embedded tunnel extension profile for $APP_ID into $(basename "$SYSEXT")"
