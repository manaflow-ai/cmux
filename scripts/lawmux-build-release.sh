#!/usr/bin/env bash
# Build the Release lawmux.app from this checkout, without Apple Developer
# signing (ad-hoc), and optionally install or open it.
#
#   scripts/lawmux-build-release.sh            build; prints the lawmux.app path
#   scripts/lawmux-build-release.sh --install  also copy it to /Applications/lawmux.app
#   scripts/lawmux-build-release.sh --open     also open the built (or installed) app
#
# Why not scripts/reload.sh or scripts/reloadp.sh: upstream's tagged builds force
# a com.cmuxterm.app.debug.<tag> bundle id, and reloadp.sh refuses to run while the
# user's cmux is open. lawmux has its own bundle id (com.lawrenceturnerw.lawmux),
# its own DerivedData and never launches by itself, so it cannot replace a running
# cmux. See LAWMUX.md.
set -euo pipefail

EXPECTED_BUNDLE_ID="com.lawrenceturnerw.lawmux"
INSTALL=0
OPEN=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --open) OPEN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

cd "$(git rev-parse --show-toplevel)"
# Xcode run-script phases look here for cargo, go, zig and bun.
export PATH="${CARGO_HOME:-${HOME}/.cargo}/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

for tool in xcodebuild cargo go zig bun; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool not found on PATH; see LAWMUX.md for the prerequisites" >&2
    exit 1
  fi
done
if [[ ! -e GhosttyKit.xcframework ]]; then
  echo "error: GhosttyKit.xcframework is missing; run ./scripts/setup.sh first" >&2
  exit 1
fi

DERIVED_DATA="${LAWMUX_DERIVED_DATA:-${HOME}/Library/Developer/Xcode/DerivedData/lawmux-release}"
PRODUCTS="$DERIVED_DATA/Build/Products/Release"

# Build settings lawmux overrides on the command line (upstream's project stays
# untouched). Changing either knob invalidates the Swift build cache, so the
# first build after a switch is a full one.
#
#   LAWMUX_UNIVERSAL=1  also build x86_64 (default: the current arch only;
#                       the Rust/Go sidecars read ARCHS as well)
#   LAWMUX_WMO=1        whole-module optimization like upstream's release
#                       (default: incremental, so small edits rebuild fast)
BUILD_SETTINGS=(
  CODE_SIGN_ENTITLEMENTS=
  CMUX_CUA_HELPER_DISPLAY_NAME="lawmux Computer Use"
)
if [[ "${LAWMUX_UNIVERSAL:-0}" == 1 ]]; then
  ARCH_NOTE="universal (arm64 + x86_64)"
else
  BUILD_SETTINGS+=(ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES)
  ARCH_NOTE="$(uname -m) only"
fi
if [[ "${LAWMUX_WMO:-0}" == 1 ]]; then
  MODE_NOTE="whole-module"
else
  BUILD_SETTINGS+=(SWIFT_COMPILATION_MODE=incremental)
  MODE_NOTE="incremental"
fi

echo "==> Building Release into $DERIVED_DATA ($ARCH_NOTE, $MODE_NOTE Swift compilation)"
# CODE_SIGN_ENTITLEMENTS= mirrors upstream's Release dev builds: the entitlements
# file needs a provisioning profile that an ad-hoc build does not have.
xcodebuild \
  -project cmux.xcodeproj \
  -scheme cmux \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  "${BUILD_SETTINGS[@]}" \
  build

echo "==> Renaming cmux.app to lawmux.app"
rm -rf "$PRODUCTS/lawmux.app"
mv "$PRODUCTS/cmux.app" "$PRODUCTS/lawmux.app"
APP="$PRODUCTS/lawmux.app"

# The bundle's directory name is not part of the code signature, but verify anyway.
codesign --verify --deep --strict "$APP"
BUNDLE_ID="$(defaults read "$APP/Contents/Info.plist" CFBundleIdentifier)"
if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  echo "error: built app has bundle id '$BUNDLE_ID', expected '$EXPECTED_BUNDLE_ID'" >&2
  echo "error: refusing to continue; it could collide with the installed cmux" >&2
  exit 1
fi

TARGET="$APP"
if [[ "$INSTALL" == 1 ]]; then
  DEST="/Applications/lawmux.app"
  if [[ -e "$DEST" ]]; then
    EXISTING_ID="$(defaults read "$DEST/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || true)"
    if [[ "$EXISTING_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
      echo "error: $DEST exists but is not lawmux (bundle id '$EXISTING_ID'); not replacing it" >&2
      exit 1
    fi
    if pgrep -f "$DEST/Contents/MacOS/cmux" >/dev/null 2>&1; then
      echo "error: $DEST is running; quit lawmux first, then rerun with --install" >&2
      exit 1
    fi
    rm -rf "$DEST"
  fi
  echo "==> Installing to $DEST"
  ditto "$APP" "$DEST"
  TARGET="$DEST"
fi

if [[ "$OPEN" == 1 ]]; then
  open "$TARGET"
fi

echo
echo "lawmux.app: $TARGET"
echo "bundle id:  $BUNDLE_ID ($(codesign -dv "$TARGET" 2>&1 | sed -n 's/^Signature=//p'))"
