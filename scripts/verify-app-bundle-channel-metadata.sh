#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: verify-app-bundle-channel-metadata.sh <app-path> <stable|nightly>

Verifies the built app bundle metadata that LaunchServices and Sparkle use for
system prompts. This intentionally checks the final bundle artifact, not the
checked-in plist template.
EOF
}

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

APP_PATH="$1"
CHANNEL="$2"
INFO_PLIST="$APP_PATH/Contents/Info.plist"

if [[ ! -d "$APP_PATH/Contents" ]]; then
  echo "error: app bundle not found at $APP_PATH" >&2
  exit 1
fi

if [[ ! -f "$INFO_PLIST" ]]; then
  echo "error: Info.plist not found at $INFO_PLIST" >&2
  exit 1
fi

case "$CHANNEL" in
  stable)
    EXPECTED_NAME="cmux"
    EXPECTED_BUNDLE_ID="com.cmuxterm.app"
    EXPECTED_ICON_NAME="AppIcon"
    ;;
  nightly)
    EXPECTED_NAME="cmux NIGHTLY"
    EXPECTED_BUNDLE_ID="com.cmuxterm.app.nightly"
    EXPECTED_ICON_NAME="AppIcon-Nightly"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"
}

expect_plist_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(plist_value "$key" 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: $key expected '$expected', found '${actual:-<missing>}'" >&2
    exit 1
  fi
}

expect_plist_value CFBundleName "$EXPECTED_NAME"
expect_plist_value CFBundleDisplayName "$EXPECTED_NAME"
expect_plist_value CFBundleIdentifier "$EXPECTED_BUNDLE_ID"
expect_plist_value CFBundleIconFile "$EXPECTED_ICON_NAME"
expect_plist_value CFBundleIconName "$EXPECTED_ICON_NAME"

ICON_PATH="$APP_PATH/Contents/Resources/${EXPECTED_ICON_NAME}.icns"
if [[ ! -s "$ICON_PATH" ]]; then
  echo "error: expected icon file missing or empty at $ICON_PATH" >&2
  exit 1
fi

CUSTOM_ICON_PATH="$APP_PATH/Icon"$'\r'
if [[ -e "$CUSTOM_ICON_PATH" ]]; then
  echo "error: app bundle contains Finder custom icon file: $CUSTOM_ICON_PATH" >&2
  exit 1
fi

if xattr -p com.apple.FinderInfo "$APP_PATH" >/dev/null 2>&1; then
  echo "error: app bundle has com.apple.FinderInfo; packaged apps must use Info.plist icon metadata" >&2
  exit 1
fi

if [[ -d "$APP_PATH/Contents/_CodeSignature" ]]; then
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

echo "verified $CHANNEL app bundle metadata: $APP_PATH"
