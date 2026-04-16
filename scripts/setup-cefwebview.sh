#!/usr/bin/env bash
# Set up the vendored CEFWebView Swift package: download CEF binaries,
# build the C++ wrapper, populate vendor/CEFWebView/Frameworks.
#
# Idempotent. Skips work that has already completed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_ROOT="$REPO_ROOT/vendor/CEFWebView"
CEF_ROOT="$PKG_ROOT/CEF"
FRAMEWORKS="$PKG_ROOT/Frameworks"

# Pinned CEF version. Match Chromium 146 stable for Apple Silicon.
# To update: pick a build from https://cef-builds.spotifycdn.com/index.html#macosarm64
CEF_VERSION="${CEF_VERSION:-146.0.5+g4db0d88+chromium-146.0.7680.65}"
CEF_PLATFORM="${CEF_PLATFORM:-macosarm64}"
CEF_DIST="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}_beta"
CEF_TARBALL="${CEF_DIST}.tar.bz2"
CEF_URL="https://cef-builds.spotifycdn.com/${CEF_TARBALL//+/%2B}"

# If a sibling cef-swift-mvp checkout already has the same distribution
# extracted, reuse it instead of re-downloading hundreds of MB.
SIBLING_CEF="$REPO_ROOT/../../cef-swift-mvp/third_party/cef/${CEF_DIST}"

mkdir -p "$CEF_ROOT"

if [ -d "$CEF_ROOT/$CEF_DIST" ]; then
  echo "✓ CEF $CEF_VERSION already extracted in vendor/CEFWebView/CEF/"
elif [ -d "$SIBLING_CEF" ]; then
  echo "↪︎ Linking CEF distribution from $SIBLING_CEF"
  ln -sfn "$SIBLING_CEF" "$CEF_ROOT/$CEF_DIST"
else
  echo "⬇︎ Downloading CEF $CEF_VERSION ($CEF_PLATFORM)..."
  echo "   $CEF_URL"
  TMP_TARBALL="$CEF_ROOT/$CEF_TARBALL"
  curl -fL --retry 3 -o "$TMP_TARBALL" "$CEF_URL"
  tar -xjf "$TMP_TARBALL" -C "$CEF_ROOT"
  rm -f "$TMP_TARBALL"
fi

# Build libcef_dll_wrapper.a if missing.
WRAPPER_LIB="$CEF_ROOT/$CEF_DIST/libcef_dll_wrapper/Release/libcef_dll_wrapper.a"
if [ ! -f "$WRAPPER_LIB" ]; then
  echo "🔨 Building libcef_dll_wrapper..."
  (
    cd "$CEF_ROOT/$CEF_DIST"
    cmake -G Xcode -DPROJECT_ARCH=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 . >/dev/null
    xcodebuild -configuration Release -target libcef_dll_wrapper -quiet
  )
fi

# Restructure into Frameworks/ for Xcode embedding.
SRCROOT="$PKG_ROOT" "$PKG_ROOT/build_cpp.sh"

echo ""
echo "✅ CEFWebView is ready at $PKG_ROOT/Frameworks"
echo "   Next: run scripts/reload.sh --tag <tag> once Xcode integration is wired."
