#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  cat >&2 <<'EOF'
Usage: ./scripts/stage-panecho-app.sh /path/to/cmux.app [/path/to/Panecho.app]
EOF
  exit 1
fi

SOURCE_APP="$1"
DEST_APP="${2:-$(dirname "$SOURCE_APP")/Panecho.app}"
PANECHO_PRODUCT_NAME="${PANECHO_PRODUCT_NAME:-Panecho}"
PANECHO_BUNDLE_IDENTIFIER="${PANECHO_BUNDLE_IDENTIFIER:-io.panecho.app}"
PANECHO_AUTH_CALLBACK_SCHEME="${PANECHO_AUTH_CALLBACK_SCHEME:-panecho}"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "error: source app not found at $SOURCE_APP" >&2
  exit 1
fi

rm -rf "$DEST_APP"
ditto "$SOURCE_APP" "$DEST_APP"

INFO_PLIST="$DEST_APP/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "error: Info.plist not found at $INFO_PLIST" >&2
  exit 1
fi

set_plist_value() {
  local key_path="$1"
  local value_type="$2"
  local value="$3"
  "$PLIST_BUDDY" -c "Set :$key_path $value" "$INFO_PLIST" >/dev/null 2>&1 \
    || {
      "$PLIST_BUDDY" -c "Delete :$key_path" "$INFO_PLIST" >/dev/null 2>&1 || true
      "$PLIST_BUDDY" -c "Add :$key_path $value_type $value" "$INFO_PLIST"
    }
}

delete_plist_key() {
  local key_path="$1"
  "$PLIST_BUDDY" -c "Delete :$key_path" "$INFO_PLIST" >/dev/null 2>&1 || true
}

set_plist_value "CFBundleName" string "$PANECHO_PRODUCT_NAME"
set_plist_value "CFBundleDisplayName" string "$PANECHO_PRODUCT_NAME"
set_plist_value "CFBundleIdentifier" string "$PANECHO_BUNDLE_IDENTIFIER"
set_plist_value "CFBundleURLTypes:0:CFBundleURLName" string "$PANECHO_BUNDLE_IDENTIFIER.web"
set_plist_value "CFBundleURLTypes:1:CFBundleURLName" string "$PANECHO_BUNDLE_IDENTIFIER.auth"
set_plist_value "CFBundleURLTypes:1:CFBundleURLSchemes:0" string "$PANECHO_AUTH_CALLBACK_SCHEME"
set_plist_value "NSMicrophoneUsageDescription" string "A program running within $PANECHO_PRODUCT_NAME would like to use your microphone."
set_plist_value "NSCameraUsageDescription" string "A program running within $PANECHO_PRODUCT_NAME would like to use your camera."
set_plist_value "NSBluetoothAlwaysUsageDescription" string "A program running within $PANECHO_PRODUCT_NAME would like to use Bluetooth to discover passkeys and security keys."
set_plist_value "NSAppleEventsUsageDescription" string "A program running within $PANECHO_PRODUCT_NAME would like to use AppleScript."
set_plist_value "NSServices:0:NSMenuItem:default" string "New $PANECHO_PRODUCT_NAME Workspace Here"
set_plist_value "NSServices:1:NSMenuItem:default" string "New $PANECHO_PRODUCT_NAME Window Here"
set_plist_value "UTExportedTypeDeclarations:1:UTTypeDescription" string "$PANECHO_PRODUCT_NAME Sidebar Tab Reorder"
set_plist_value "SUAutomaticallyUpdate" bool false
set_plist_value "SUEnableAutomaticChecks" bool false
set_plist_value "SUScheduledCheckInterval" integer 0
set_plist_value "SUSendProfileInfo" bool false
delete_plist_key "SUFeedURL"
delete_plist_key "SUPublicEDKey"

rm -rf "$DEST_APP/Contents/Frameworks/Sentry.framework"
rm -rf "$DEST_APP/Contents/Resources/PostHog_PostHog.bundle"

# Panecho: ship the react-grab inspector script offline so the in-app browser's
# React Grab works with no CDN fetch (privacy mode loads it from the app bundle).
# Version is coupled to ReactGrabSettings.defaultVersion / knownHashes in ReactGrab.swift.
STAGE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REACT_GRAB_SRC="$STAGE_SCRIPT_DIR/../Resources/react-grab-0.1.29.global.js"
if [[ -f "$REACT_GRAB_SRC" ]]; then
  ditto "$REACT_GRAB_SRC" "$DEST_APP/Contents/Resources/react-grab-0.1.29.global.js"
  echo "Bundled react-grab script into $DEST_APP/Contents/Resources"
else
  echo "warning: react-grab bundled script not found at $REACT_GRAB_SRC" >&2
fi

echo "Staged $PANECHO_PRODUCT_NAME at $DEST_APP"