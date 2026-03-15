#!/usr/bin/env bash
set -euo pipefail

SOURCE_PACKAGES_DIR="${CMUX_SOURCE_PACKAGES_DIR:-$PWD/.ci-source-packages}"
DERIVED_DATA_PATH="${CMUX_DERIVED_DATA_PATH:-$PWD/.ci-bundled-ghostty-helper}"
CONFIGURATION="${CMUX_CONFIGURATION:-Debug}"

case "$CONFIGURATION" in
  Debug)
    APP_NAME="cmux DEV.app"
    ;;
  Release)
    APP_NAME="cmux.app"
    ;;
  *)
    echo "FAIL: unsupported configuration $CONFIGURATION" >&2
    exit 1
    ;;
esac

mkdir -p "$SOURCE_PACKAGES_DIR"
rm -rf "$DERIVED_DATA_PATH"

xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux \
  -configuration "$CONFIGURATION" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
  -disableAutomaticPackageResolution \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -destination "platform=macOS" \
  build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME"
HELPER_PATH="$APP_PATH/Contents/Resources/bin/ghostty"

if [ ! -x "$HELPER_PATH" ]; then
  echo "FAIL: bundled Ghostty theme picker helper missing at $HELPER_PATH" >&2
  exit 1
fi

echo "PASS: bundled Ghostty theme picker helper present at $HELPER_PATH"
