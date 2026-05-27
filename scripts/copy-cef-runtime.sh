#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${CEF_ROOT:-}" ]]; then
  echo "error: CEF_ROOT is not set" >&2
  exit 1
fi
if [[ -z "${TARGET_BUILD_DIR:-}" || -z "${FRAMEWORKS_FOLDER_PATH:-}" || -z "${INFOPLIST_PATH:-}" ]]; then
  echo "error: Xcode build environment is incomplete" >&2
  exit 1
fi

FRAMEWORKS_DIR="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
INFO_PLIST="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
HELPER_SOURCE="$CEF_ROOT/build/cmux-cef-helper"
CEF_FRAMEWORK_SOURCE="$CEF_ROOT/Release/Chromium Embedded Framework.framework"

if [[ ! -d "$CEF_FRAMEWORK_SOURCE" ]]; then
  echo "error: missing CEF framework at $CEF_FRAMEWORK_SOURCE" >&2
  exit 1
fi
if [[ ! -x "$HELPER_SOURCE" ]]; then
  echo "error: missing CEF helper executable at $HELPER_SOURCE" >&2
  exit 1
fi
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "error: missing app Info.plist at $INFO_PLIST" >&2
  exit 1
fi

mkdir -p "$FRAMEWORKS_DIR"
rsync -a --delete "$CEF_FRAMEWORK_SOURCE" "$FRAMEWORKS_DIR/"
CEF_FRAMEWORK_DEST="$FRAMEWORKS_DIR/Chromium Embedded Framework.framework"
CEF_FRAMEWORK_VERSION_DIR="$CEF_FRAMEWORK_DEST/Versions/A"
if [[ ! -d "$CEF_FRAMEWORK_VERSION_DIR" ]]; then
  versioned_dest="$CEF_FRAMEWORK_DEST.versioned.$$"
  rm -rf "$versioned_dest"
  mkdir -p "$versioned_dest/Versions/A"
  rsync -a "$CEF_FRAMEWORK_DEST/" "$versioned_dest/Versions/A/"
  ln -s A "$versioned_dest/Versions/Current"
  ln -s "Versions/Current/Chromium Embedded Framework" "$versioned_dest/Chromium Embedded Framework"
  ln -s "Versions/Current/Resources" "$versioned_dest/Resources"
  if [[ -d "$versioned_dest/Versions/A/Libraries" ]]; then
    ln -s "Versions/Current/Libraries" "$versioned_dest/Libraries"
  fi
  rm -rf "$CEF_FRAMEWORK_DEST"
  mv "$versioned_dest" "$CEF_FRAMEWORK_DEST"
fi
CEF_FRAMEWORK_LIBRARIES="$CEF_FRAMEWORK_DEST/Versions/Current/Libraries"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || printf '1')"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || printf '1')"
HELPER_NAMES=(
  "cmux Helper"
  "cmux Helper (Alerts)"
  "cmux Helper (GPU)"
  "cmux Helper (Plugin)"
  "cmux Helper (Renderer)"
)

helper_bundle_suffix() {
  case "$1" in
    "cmux Helper") printf 'helper' ;;
    "cmux Helper (Alerts)") printf 'helper.alerts' ;;
    "cmux Helper (GPU)") printf 'helper.gpu' ;;
    "cmux Helper (Plugin)") printf 'helper.plugin' ;;
    "cmux Helper (Renderer)") printf 'helper.renderer' ;;
    *) printf '%s' "$1" | tr '[:upper:] ()' '[:lower:]---' | tr -cs '[:alnum:].-' '-' ;;
  esac
}

for helper_name in "${HELPER_NAMES[@]}"; do
  helper_app="$FRAMEWORKS_DIR/$helper_name.app"
  helper_macos="$helper_app/Contents/MacOS"
  mkdir -p "$helper_macos"
  cp "$HELPER_SOURCE" "$helper_macos/$helper_name"
  chmod 755 "$helper_macos/$helper_name"
  helper_id="$BUNDLE_ID.$(helper_bundle_suffix "$helper_name")"
  cat >"$helper_app/Contents/Info.plist" <<EOF_HELPER
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>$helper_name</string>
	<key>CFBundleIdentifier</key>
	<string>$helper_id</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$helper_name</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$MARKETING_VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUNDLE_VERSION</string>
	<key>LSBackgroundOnly</key>
	<true/>
</dict>
</plist>
EOF_HELPER
done

sign_cef_runtime_if_requested() {
  if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "NO" ]]; then
    return
  fi
  local identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
  if [[ -z "$identity" ]]; then
    return
  fi

  local common=(--force --sign "$identity" --timestamp=none)
  if [[ "${ENABLE_HARDENED_RUNTIME:-NO}" == "YES" ]]; then
    common+=(--options runtime)
  fi

  local entitlements="${CMUX_HELPER_ENTITLEMENTS:-${SRCROOT:-}/cmux-helper.entitlements}"
  local entitlement_args=()
  if [[ -f "$entitlements" ]]; then
    entitlement_args=(--entitlements "$entitlements")
  fi

  if [[ -d "$CEF_FRAMEWORK_LIBRARIES" ]]; then
    while IFS= read -r -d '' library; do
      /usr/bin/codesign "${common[@]}" "${entitlement_args[@]}" "$library"
    done < <(find "$CEF_FRAMEWORK_LIBRARIES" -type f -name "*.dylib" -print0)
  fi

  /usr/bin/codesign "${common[@]}" "${entitlement_args[@]}" "$CEF_FRAMEWORK_DEST"
  for helper_name in "${HELPER_NAMES[@]}"; do
    /usr/bin/codesign "${common[@]}" "${entitlement_args[@]}" "$FRAMEWORKS_DIR/$helper_name.app"
  done
}

sign_cef_runtime_if_requested
