#!/usr/bin/env bash
set -euo pipefail

SOURCE_PACKAGES_DIR="${CMUX_SOURCE_PACKAGES_DIR:-$PWD/.ci-source-packages}"
DERIVED_DATA_PATH="${CMUX_DERIVED_DATA_PATH:-$PWD/.ci-bundled-vnc-helper}"
CONFIGURATION="${CMUX_CONFIGURATION:-Debug}"
APP_PATH="${CMUX_APP_PATH:-}"

if [[ -z "$APP_PATH" ]]; then
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
    -project cmux.xcodeproj \
    -scheme cmux \
    -configuration "$CONFIGURATION" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
    -disableAutomaticPackageResolution \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination "platform=macOS" \
    build

  APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME"
fi

HELPER_PATH="$APP_PATH/Contents/Resources/bin/cmux-vnc-helper"
DYLIB_PATH="$APP_PATH/Contents/Resources/bin/libRoyalVNCKit.dylib"

if [[ ! -x "$HELPER_PATH" ]]; then
  echo "FAIL: bundled VNC helper missing at $HELPER_PATH" >&2
  exit 1
fi

if [[ ! -f "$DYLIB_PATH" ]]; then
  echo "FAIL: bundled RoyalVNC dylib missing at $DYLIB_PATH" >&2
  exit 1
fi

if ! otool -L "$HELPER_PATH" | grep -q '@rpath/libRoyalVNCKit.dylib'; then
  echo "FAIL: VNC helper does not link RoyalVNC through @rpath" >&2
  otool -L "$HELPER_PATH" >&2
  exit 1
fi

if ! otool -l "$HELPER_PATH" | grep -A2 LC_RPATH | grep -q '@loader_path'; then
  echo "FAIL: VNC helper is missing @loader_path rpath for adjacent RoyalVNC dylib" >&2
  otool -l "$HELPER_PATH" >&2
  exit 1
fi

if [[ "${CMUX_EXPECT_UNIVERSAL:-0}" == "1" ]]; then
  HELPER_ARCHS="$(lipo -archs "$HELPER_PATH")"
  DYLIB_ARCHS="$(lipo -archs "$DYLIB_PATH")"
  echo "VNC helper architectures: $HELPER_ARCHS"
  echo "RoyalVNC dylib architectures: $DYLIB_ARCHS"
  [[ "$HELPER_ARCHS" == *arm64* && "$HELPER_ARCHS" == *x86_64* ]]
  [[ "$DYLIB_ARCHS" == *arm64* && "$DYLIB_ARCHS" == *x86_64* ]]
fi

echo "PASS: bundled VNC helper and RoyalVNC dylib are present and loadable"
