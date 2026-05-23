#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

make_app() {
  local channel="$1"
  local name="$2"
  local bundle_id="$3"
  local icon_name="$4"
  local app_path="$TMP_DIR/${channel}.app"
  local plist_path="$app_path/Contents/Info.plist"

  mkdir -p "$app_path/Contents/Resources"
  /usr/libexec/PlistBuddy -c "Add :CFBundleName string $name" "$plist_path"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $name" "$plist_path"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_id" "$plist_path"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $icon_name" "$plist_path"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string $icon_name" "$plist_path"
  printf 'icns' > "$app_path/Contents/Resources/${icon_name}.icns"
  "$ROOT_DIR/scripts/verify-app-bundle-channel-metadata.sh" "$app_path" "$channel"
}

make_app stable "cmux" "com.cmuxterm.app" "AppIcon"
make_app nightly "cmux NIGHTLY" "com.cmuxterm.app.nightly" "AppIcon-Nightly"
make_app rc "cmux RC" "com.cmuxterm.app.rc" "AppIcon-RC"

echo "PASS: app bundle channel metadata verifier accepts stable, nightly, and rc"
