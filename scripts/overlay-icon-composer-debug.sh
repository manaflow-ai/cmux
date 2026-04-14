#!/bin/sh
set -euo pipefail

DEST="${1:?resource destination required}"
INFO_PLIST="${2:?info plist path required}"

if [ "${CONFIGURATION:-}" != "Debug" ]; then
  exit 0
fi

HOST_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "${HOST_MAJOR:-0}" -lt 26 ]; then
  # Xcode 26.3's actool crashes on macOS 15 when compiling Icon Composer assets.
  exit 0
fi

ICON_BASE_SRC="${SRCROOT}/AppIcon.icon"
ICON_DEBUG_SRC="${SRCROOT}/AppIcon-Debug.icon"
if [ ! -d "$ICON_BASE_SRC" ] || [ ! -d "$ICON_DEBUG_SRC" ]; then
  exit 0
fi

PARTIAL_INFO_PLIST="${TARGET_TEMP_DIR}/icon-composer-partial-info.plist"
rm -f "$PARTIAL_INFO_PLIST"

xcrun actool \
  "${SRCROOT}/Assets.xcassets" \
  "$ICON_BASE_SRC" \
  "$ICON_DEBUG_SRC" \
  --compile "$DEST" \
  --output-format human-readable-text \
  --warnings \
  --notices \
  --output-partial-info-plist "$PARTIAL_INFO_PLIST" \
  --app-icon AppIcon-Debug \
  --development-region "${DEVELOPMENT_LANGUAGE:-en}" \
  --target-device mac \
  --minimum-deployment-target "${MACOSX_DEPLOYMENT_TARGET:?}" \
  --platform macosx \
  --bundle-identifier "${PRODUCT_BUNDLE_IDENTIFIER:?}" \
  --enable-on-demand-resources NO

/usr/libexec/PlistBuddy -c "Set :CFBundleIconName AppIcon-Debug" "$INFO_PLIST" >/dev/null 2>&1 || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon-Debug" "$INFO_PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon-Debug" "$INFO_PLIST" >/dev/null 2>&1 || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon-Debug" "$INFO_PLIST" >/dev/null 2>&1 || true
