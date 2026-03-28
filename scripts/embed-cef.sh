#!/usr/bin/env bash
set -euo pipefail

# Embed CEF framework and helper process into a cmux app bundle.
# Usage: ./scripts/embed-cef.sh <path-to-app-bundle>
#
# This copies the Chromium Embedded Framework.framework and creates
# the helper .app bundle inside the app's Frameworks/ directory.

if [ $# -lt 1 ]; then
    echo "Usage: $0 <path-to-app-bundle>"
    exit 1
fi

APP_BUNDLE="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

CEF_VERSION="146.0.6+g68649e2+chromium-146.0.7680.154"
CEF_PLATFORM="macosarm64"
CEF_DIST_NAME="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}_minimal"
CEF_CACHE_DIR="${CMUX_CEF_CACHE_DIR:-$HOME/.cache/cmux/cef}"
CEF_EXTRACT_DIR="$CEF_CACHE_DIR/extracted/$CEF_DIST_NAME"
CEF_FW="$CEF_EXTRACT_DIR/Release/Chromium Embedded Framework.framework"
CEF_WRAPPER_LIB="$CEF_EXTRACT_DIR/build/libcef_dll_wrapper/libcef_dll_wrapper.a"
HELPER_SRC="$PROJECT_DIR/vendor/cef-bridge/helper"

FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"

if [ ! -d "$CEF_FW" ]; then
    echo "Error: CEF framework not found at $CEF_FW"
    echo "Run ./scripts/build-cef-bridge.sh first"
    exit 1
fi

echo "==> Embedding CEF into $APP_BUNDLE"

# 1. Copy the real CEF framework (replaces any stub from the build)
mkdir -p "$FRAMEWORKS_DIR"
echo "==> Copying Chromium Embedded Framework.framework..."
rm -rf "$FRAMEWORKS_DIR/Chromium Embedded Framework.framework"
cp -R "$CEF_FW" "$FRAMEWORKS_DIR/"

# 2. Build the helper if needed
HELPER_BIN="$HELPER_SRC/cmux_helper"
if [ ! -f "$HELPER_BIN" ]; then
    echo "==> Building helper process..."
    clang++ -std=c++20 -arch arm64 -mmacosx-version-min=13.0 \
        -fno-exceptions -fno-rtti \
        -I"$CEF_EXTRACT_DIR" \
        -o "$HELPER_BIN" \
        "$HELPER_SRC/cef_helper.cpp" \
        "$CEF_WRAPPER_LIB" \
        -F"$CEF_EXTRACT_DIR/Release" \
        -framework "Chromium Embedded Framework" \
        -framework AppKit -framework IOSurface \
        -Wl,-rpath,@executable_path/../../../../Frameworks \
        -Wl,-rpath,@executable_path/../../../..
fi

# 3. Create helper .app bundle
# CEF expects: Contents/Frameworks/<app> Helper.app/Contents/MacOS/<app> Helper
# For "cmux DEV", that's "cmux DEV Helper.app"
# We use a generic name and set the path via browser_subprocess_path instead.
HELPER_APP="$FRAMEWORKS_DIR/cmux Helper.app"
mkdir -p "$HELPER_APP/Contents/MacOS"
cp "$HELPER_BIN" "$HELPER_APP/Contents/MacOS/cmux Helper"
cp "$HELPER_SRC/Info.plist" "$HELPER_APP/Contents/Info.plist"

# Fix the helper's CEF framework reference to use @rpath.
# The CEF framework has install name @executable_path/../Frameworks/...
# which works for the main app but not the nested helper. The helper's
# rpath entries already point to the right Frameworks/ directory.
install_name_tool -change \
    "@executable_path/../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework" \
    "@rpath/Chromium Embedded Framework.framework/Chromium Embedded Framework" \
    "$HELPER_APP/Contents/MacOS/cmux Helper" 2>/dev/null || true

# Sign the helper
codesign --force --sign - "$HELPER_APP" 2>/dev/null || true

# 4. Copy the real CEF bridge dylib (replaces the stub static lib)
CEF_BRIDGE_DYLIB="$PROJECT_DIR/vendor/cef-bridge/libcef_bridge.dylib"
if [ -f "$CEF_BRIDGE_DYLIB" ]; then
    cp "$CEF_BRIDGE_DYLIB" "$FRAMEWORKS_DIR/libcef_bridge.dylib"
    codesign --force --sign - "$FRAMEWORKS_DIR/libcef_bridge.dylib" 2>/dev/null || true
    echo "==> Copied CEF bridge dylib"
fi

echo "==> CEF embedded successfully"
echo "    Framework: $FRAMEWORKS_DIR/Chromium Embedded Framework.framework"
echo "    Helper:    $HELPER_APP"
