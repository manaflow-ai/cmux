#!/bin/bash
# Downloads and caches the pinned CEF (Chromium Embedded Framework) binary
# distribution for the host architecture, then prints the path to the cached
# "Chromium Embedded Framework.framework".
#
# The framework is never checked into the repository. The cache lives under
# ~/Library/Caches/cmux-dev/cef/<version>/<platform>/ and is shared by all
# build directories on the machine. Pass --check to only verify presence.
set -euo pipefail

CEF_VERSION="151.3.17+gf059e67+chromium-151.0.7922.138"

# Xcode script phases can run under Rosetta, where `uname -m` lies about the
# build architecture. The build passes ARCHS; interactive callers fall back
# to the host architecture.
CEF_ARCH="${CMUX_CEF_ARCH:-${ARCHS:-}}"
CEF_ARCH="${CEF_ARCH:-$(uname -m)}"

case "$CEF_ARCH" in
  arm64)
    CEF_PLATFORM="macosarm64"
    CEF_SHA256="1320e1abe7bcd3535eb3649fe9b008f3848738c3a6f138f105139c325216f4e1"
    ;;
  x86_64)
    CEF_PLATFORM="macosx64"
    CEF_SHA256="44d2e64f47522ea93b7ef7f695d162e2522236d8ae9bb77a8f59e88ceb4c136b"
    ;;
  *)
    echo "ensure-cef: unsupported architecture $CEF_ARCH" >&2
    exit 1
    ;;
esac

CACHE_ROOT="${CMUX_CEF_CACHE_DIR:-$HOME/Library/Caches/cmux-dev/cef}"
INSTALL_DIR="$CACHE_ROOT/$CEF_VERSION/$CEF_PLATFORM"
FRAMEWORK="$INSTALL_DIR/Chromium Embedded Framework.framework"

if [[ -d "$FRAMEWORK" ]]; then
  echo "$FRAMEWORK"
  exit 0
fi

if [[ "${1:-}" == "--check" ]]; then
  echo "ensure-cef: framework not cached at $FRAMEWORK" >&2
  exit 1
fi

ENCODED_VERSION="${CEF_VERSION//+/%2B}"
ARCHIVE_NAME="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}_minimal.tar.bz2"
URL="https://cef-builds.spotifycdn.com/cef_binary_${ENCODED_VERSION}_${CEF_PLATFORM}_minimal.tar.bz2"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/cmux-cef-XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

echo "ensure-cef: downloading $ARCHIVE_NAME" >&2
curl -sSL --fail -o "$STAGING/cef.tar.bz2" "$URL"

ACTUAL_SHA="$(shasum -a 256 "$STAGING/cef.tar.bz2" | awk '{print $1}')"
if [[ "$ACTUAL_SHA" != "$CEF_SHA256" ]]; then
  echo "ensure-cef: checksum mismatch: expected $CEF_SHA256 got $ACTUAL_SHA" >&2
  exit 1
fi

tar xjf "$STAGING/cef.tar.bz2" -C "$STAGING"
EXTRACTED="$(find "$STAGING" -maxdepth 1 -type d -name 'cef_binary_*' | head -1)"
if [[ -z "$EXTRACTED" || ! -d "$EXTRACTED/Release/Chromium Embedded Framework.framework" ]]; then
  echo "ensure-cef: archive did not contain the framework" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
# Also keep the include headers next to the framework for the shim target.
rsync -a --delete "$EXTRACTED/include/" "$INSTALL_DIR/include/"

# CEF ships a flat framework, but Xcode's product validation and codesign
# both require the standard versioned layout. Restructure into Versions/A
# with top-level symlinks — the same shape Electron ships — which keeps
# Chromium's own resource lookup working because Resources stays beside the
# binary's real location.
FLAT="$EXTRACTED/Release/Chromium Embedded Framework.framework"
STAGED="$STAGING/versioned.framework"
mkdir -p "$STAGED/Versions/A"
rsync -a "$FLAT/" "$STAGED/Versions/A/"
ln -s A "$STAGED/Versions/Current"
ln -s "Versions/Current/Chromium Embedded Framework" "$STAGED/Chromium Embedded Framework"
ln -s Versions/Current/Libraries "$STAGED/Libraries"
ln -s Versions/Current/Resources "$STAGED/Resources"
rm -rf "$FRAMEWORK"
rsync -a "$STAGED/" "$FRAMEWORK/"
echo "$FRAMEWORK"
