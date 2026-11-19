#!/usr/bin/env bash
# Xcode "Bundle Share extension" phase of the cmux-next target: the Share menu's "<app name> Chat"
# (cmuxterm-hq goal screenshot-into-chat), so a screenshot goes into a chat from Preview, Finder or
# a screenshot's thumbnail in one step:
#
#   Contents/PlugIns/CmuxShare.appex
#     Contents/MacOS/CmuxShare      Packages/macOS/CmuxNext/ShareExtension/ShareViewController.swift
#     Contents/Info.plist           <app bundle id>.share, com.apple.share-services, images only
#
# The extension only opens the shared image files with the app that carries it, the door an image
# opened with cmux already takes into a chat composer; it shows no sheet. One slice per arch in
# $ARCHS for $MACOSX_DEPLOYMENT_TARGET, compiled again only when the source, archs or target change.
# macOS loads an app extension only when it is sandboxed: it is signed with
# share-extension.entitlements (the App Sandbox, nothing else: no App Group, no provisioning
# profile), with the build's identity (EXPANDED_CODE_SIGN_IDENTITY; ad hoc when empty, hardened
# runtime with a real one). Release signing (sign-cmux-bundle.sh) runs `--stamp <app>` first, since
# nightly and RC rename the app after the build, then signs it again with the same entitlements.
#
#   bundle-share-extension.sh               the Xcode phase (Xcode's variables)
#   bundle-share-extension.sh --stamp APP   re-stamps APP's extension from APP's Info.plist
#
# Runs under Xcode's /bin/bash 3.2: no associative arrays, no mapfile.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${SRCROOT:-$(cd "$script_dir/../.." && pwd)}"
EXECUTABLE=CmuxShare
APPEX=CmuxShare.appex
PRINCIPAL_CLASS=CmuxShareViewController
# The most images one share hands over; more and the Share menu leaves the item out.
MAX_IMAGES=20
ENTITLEMENTS="$script_dir/share-extension.entitlements"
SOURCE="$repo_root/Packages/macOS/CmuxNext/ShareExtension/ShareViewController.swift"

# PlistBuddy on a Mac; plistlib elsewhere. Empty for a plist or key that is not there.
plist_get() {
  [[ -f "$1" ]] || return 0
  if [[ -x /usr/libexec/PlistBuddy ]]; then
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
  else
    python3 -I -c 'import plistlib, sys; v = plistlib.load(open(sys.argv[1], "rb")).get(sys.argv[2]); print("" if v is None else v)' \
      "$1" "$2" 2>/dev/null || true
  fi
}

xml_escape() {
  local s="$1"
  s="${s//&/"&amp;"}"; s="${s//</"&lt;"}"; s="${s//>/"&gt;"}"
  printf '%s' "$s"
}

# The extension's Info.plist: <path> <app bundle id> <app name> <version> <short version> <minimum macOS>.
# The Share menu shows CFBundleDisplayName; its version is the app's, as macOS expects of an extension.
write_plist() {
  local path="$1" id name version short minimum
  id="$(xml_escape "$2.share")"; name="$(xml_escape "$3 Chat")"
  version="$(xml_escape "$4")"; short="$(xml_escape "$5")"; minimum="$(xml_escape "$6")"
  cat > "$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$short</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>$minimum</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionAttributes</key>
    <dict>
      <key>NSExtensionActivationRule</key>
      <dict>
        <key>NSExtensionActivationSupportsImageWithMaxCount</key><integer>$MAX_IMAGES</integer>
      </dict>
    </dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.share-services</string>
    <key>NSExtensionPrincipalClass</key><string>$PRINCIPAL_CLASS</string>
  </dict>
</dict>
</plist>
PLIST
}

# <app> -> the values write_plist takes after the path, one per line, from the app's Info.plist
# with the build's settings as the fallback.
app_identity() {
  local info="$1/Contents/Info.plist" id name version short minimum
  id="$(plist_get "$info" CFBundleIdentifier)"; id="${id:-${PRODUCT_BUNDLE_IDENTIFIER:-}}"
  name="$(plist_get "$info" CFBundleName)"; name="${name:-${PRODUCT_NAME:-$(basename "$1" .app)}}"
  version="$(plist_get "$info" CFBundleVersion)"; version="${version:-${CURRENT_PROJECT_VERSION:-1}}"
  short="$(plist_get "$info" CFBundleShortVersionString)"; short="${short:-${MARKETING_VERSION:-$version}}"
  minimum="$(plist_get "$info" LSMinimumSystemVersion)"; minimum="${minimum:-${MACOSX_DEPLOYMENT_TARGET:-14.0}}"
  [[ -n "$id" ]] || { echo "error: $info has no CFBundleIdentifier" >&2; return 1; }
  printf '%s\n' "$id" "$name" "$version" "$short" "$minimum"
}

stamp_plist() { # <app> <plist path>
  local values
  values="$(app_identity "$1")" || return 1
  local id name version short minimum
  { read -r id; read -r name; read -r version; read -r short; read -r minimum; } <<< "$values"
  write_plist "$2" "$id" "$name" "$version" "$short" "$minimum" || return 1
  echo "$id.share"
}

# --stamp APP: the final app's id, name and version (after a nightly or RC rename), before Release signing.
if [[ "${1:-}" == "--stamp" ]]; then
  app="${2:?usage: $0 --stamp <app>}"
  app="${app%/}"
  appex="$app/Contents/PlugIns/$APPEX"
  if [[ ! -d "$appex/Contents" ]]; then
    echo "note: $app carries no Share extension"
    exit 0
  fi
  id="$(stamp_plist "$app" "$appex/Contents/Info.plist")" || exit 1
  echo "stamped the Share extension: $APPEX ($id)"
  exit 0
fi
[[ $# -eq 0 ]] || { echo "usage: $0 [--stamp <app>]" >&2; exit 2; }

resources="${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
app="${TARGET_BUILD_DIR:?}/${resources%/Contents/Resources}"
[[ "$app" == *.app ]] || { echo "error: cannot find the app bundle from UNLOCALIZED_RESOURCES_FOLDER_PATH=$resources" >&2; exit 1; }
work="${TARGET_TEMP_DIR:-${DERIVED_FILE_DIR:?}}/share-extension"
stamp="${TARGET_TEMP_DIR:-$TARGET_BUILD_DIR}/bundle-share-extension.stamp"
rm -f "$stamp"
minimum="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
read -r -a archs <<< "${ARCHS:-arm64}"
mkdir -p "$work"

# The executable: compiled again only when the source, archs, target or toolchain change.
key="$( { echo "${archs[*]} $minimum"; xcrun --sdk macosx swiftc --version 2>&1; xcrun --sdk macosx --show-sdk-version; shasum -a 256 "$SOURCE" "$0"; } | shasum -a 256 | cut -d' ' -f1)"
binary="$work/$EXECUTABLE-$key"
if [[ ! -f "$binary" ]]; then
  rm -f "$work/$EXECUTABLE"-*
  slices=()
  for arch in "${archs[@]}"; do
    out="$work/slice-$arch"
    # -e _NSExtensionMain: Foundation's extension entry point loads the principal class.
    xcrun --sdk macosx swiftc -target "$arch-apple-macos$minimum" -O -swift-version 5 -parse-as-library \
      -application-extension -module-name CmuxShare \
      -Xlinker -e -Xlinker _NSExtensionMain -framework AppKit -framework UniformTypeIdentifiers \
      "$SOURCE" -o "$out"
    slices+=("$out")
  done
  xcrun lipo -create "${slices[@]}" -output "$binary.tmp"
  rm -f "${slices[@]}"
  mv "$binary.tmp" "$binary"
fi

mkdir -p "$app/Contents/PlugIns"
# Staged outside the app: an interrupted build leaves nothing in PlugIns for release signing to trip on.
tmp="$(mktemp -d "$work/stage.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
staged="$tmp/$APPEX"
mkdir -p "$staged/Contents/MacOS"
cp "$binary" "$staged/Contents/MacOS/$EXECUTABLE"
chmod 755 "$staged/Contents/MacOS/$EXECUTABLE"
id="$(stamp_plist "$app" "$staged/Contents/Info.plist")" || exit 1

identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[[ -n "$identity" ]] || identity="-"
flags=(--force --sign "$identity" --entitlements "$ENTITLEMENTS")
if [[ "$identity" != "-" ]]; then
  flags+=(--options runtime)
  if [[ "${CMUX_TIMESTAMP:-}" == "none" ]]; then flags+=(--timestamp=none); else flags+=(--timestamp); fi
fi
"$repo_root/scripts/codesign-retry.sh" "${flags[@]}" "$staged"
rm -rf "$app/Contents/PlugIns/$APPEX"
mv "$staged" "$app/Contents/PlugIns/$APPEX"
printf 'completed\n' > "$stamp"
echo "bundled the Share extension $APPEX ($id, ${archs[*]}, signed by $identity)"
