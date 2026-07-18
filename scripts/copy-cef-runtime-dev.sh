#!/bin/zsh
# Xcode build phase: bundle the CEF runtime into dev builds of cmux.
#
# No-op unless BOTH hold:
#   - the CEFKit package has a fetched CEF distribution
#     (Packages/macOS/CEFKit/scripts/fetch-cef.sh), and
#   - this is a Debug build.
# Release/nightly artifacts and CI builds are unaffected; the Chromium
# Browser (CEF) debug window explains how to enable the runtime when absent.
#
# Bundles:
#   - Chromium Embedded Framework.framework into Contents/Frameworks
#   - five "<App> Helper*.app" subprocess bundles built from the CEFKit
#     package's cefkit-helper executable
#   - the CEFKit test extension into Contents/Resources/CEFExtensions
set -euo pipefail

copy_preinstalled_extensions() {
  local source_dir="$1"
  local destination_dir="$2"
  mkdir -p "$destination_dir"
  [[ -d "$source_dir" ]] || return
  for ext_dir in "$source_dir"/*(N/); do
    [[ -f "$ext_dir/manifest.json" ]] || continue
    ditto "$ext_dir" "$destination_dir/$(basename "$ext_dir")"
  done
}

if [[ "${CEFKIT_COPY_EXTENSIONS_ONLY:-0}" == "1" ]]; then
  copy_preinstalled_extensions \
    "${CEFKIT_EXTENSION_SOURCE_DIR:?missing CEFKIT_EXTENSION_SOURCE_DIR}" \
    "${CEFKIT_EXTENSION_DESTINATION_DIR:?missing CEFKIT_EXTENSION_DESTINATION_DIR}"
  exit 0
fi

if [[ -z "${SRCROOT:-}" || -z "${TARGET_BUILD_DIR:-}" || -z "${FULL_PRODUCT_NAME:-}" ]]; then
  echo "copy-cef-runtime-dev.sh must run from Xcode build settings" >&2
  exit 1
fi

CEF_PKG="${SRCROOT}/Packages/macOS/CEFKit"
CEF_ROOT="${CEF_PKG}/third_party/cef/current"

if [[ "${CONFIGURATION:-}" != "Debug" ]]; then
  echo "copy-cef-runtime-dev: skipping (configuration ${CONFIGURATION:-unset})"
  exit 0
fi
if [[ ! -d "${CEF_ROOT}/Release/Chromium Embedded Framework.framework" ]]; then
  echo "copy-cef-runtime-dev: skipping (no CEF distribution; run Packages/macOS/CEFKit/scripts/fetch-cef.sh)"
  exit 0
fi

APP_BUNDLE="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"
APP_FRAMEWORKS="${APP_BUNDLE}/Contents/Frameworks"
APP_RESOURCES="${APP_BUNDLE}/Contents/Resources"
CEF_FRAMEWORK_DIR="${APP_FRAMEWORKS}/Chromium Embedded Framework.framework"
HELPER_BASE="${PRODUCT_NAME} Helper"

CEF_BINARIES="${CEF_ROOT}/${CONFIGURATION}"
if [[ ! -d "${CEF_BINARIES}/Chromium Embedded Framework.framework" ]]; then
  CEF_BINARIES="${CEF_ROOT}/Release"
fi

mkdir -p "$APP_FRAMEWORKS" "$APP_RESOURCES"

# Framework (rsync-style delete of stale copy first).
rm -rf "$CEF_FRAMEWORK_DIR"
mkdir -p "${CEF_FRAMEWORK_DIR}/Versions"
ditto "${CEF_BINARIES}/Chromium Embedded Framework.framework" "${CEF_FRAMEWORK_DIR}/Versions/A"
ln -sfn "Versions/A/Chromium Embedded Framework" "${CEF_FRAMEWORK_DIR}/Chromium Embedded Framework"
ln -sfn "Versions/A/Libraries" "${CEF_FRAMEWORK_DIR}/Libraries"
ln -sfn "Versions/A/Resources" "${CEF_FRAMEWORK_DIR}/Resources"
ln -sfn "A" "${CEF_FRAMEWORK_DIR}/Versions/Current"

# Helper executable from the CEFKit package. env -i keeps Xcode's build
# settings from leaking into the nested SwiftPM invocation.
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  /usr/bin/swift build \
  --package-path "$CEF_PKG" \
  --configuration release \
  --product cefkit-helper
HELPER_BINARY="$("$SHELL" -c "env -i HOME=\"$HOME\" PATH=/usr/bin:/bin /usr/bin/swift build --package-path \"$CEF_PKG\" --configuration release --show-bin-path")/cefkit-helper"
if [[ ! -x "$HELPER_BINARY" ]]; then
  echo "copy-cef-runtime-dev: cefkit-helper build produced no binary" >&2
  exit 1
fi

make_helper_variant() {
  local name_suffix="$1"
  local bundle_suffix="$2"
  local helper_title="${HELPER_BASE}${name_suffix}"
  local helper_bundle="${APP_FRAMEWORKS}/${helper_title}.app"

  rm -rf "$helper_bundle"
  mkdir -p "${helper_bundle}/Contents/MacOS"
  cp "$HELPER_BINARY" "${helper_bundle}/Contents/MacOS/${helper_title}"
  cat > "${helper_bundle}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>${helper_title}</string>
	<key>CFBundleExecutable</key>
	<string>${helper_title}</string>
	<key>CFBundleIdentifier</key>
	<string>${PRODUCT_BUNDLE_IDENTIFIER}.helper${bundle_suffix}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${helper_title}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSFileQuarantineEnabled</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST
  codesign --force --sign - "$helper_bundle" 2>/dev/null || true
}

make_helper_variant "" ""
make_helper_variant " (Alerts)" ".alerts"
make_helper_variant " (GPU)" ".gpu"
make_helper_variant " (Plugin)" ".plugin"
make_helper_variant " (Renderer)" ".renderer"

# Test extension for verifying the Chrome extension system.
rm -rf "${APP_RESOURCES}/CEFExtensions"
mkdir -p "${APP_RESOURCES}/CEFExtensions"
ditto "${CEF_PKG}/Demo/TestExtension" "${APP_RESOURCES}/CEFExtensions/cefkit-test-extension"

# Preinstalled extensions fetched by Packages/macOS/CEFKit/scripts/
# fetch-extensions.sh (uBlock Origin, Bitwarden). Best-effort: dev builds
# without a fetch just skip them.
copy_preinstalled_extensions \
  "${CEF_PKG}/third_party/extensions" \
  "${APP_RESOURCES}/CEFExtensions"

echo "copy-cef-runtime-dev: bundled CEF runtime into ${FULL_PRODUCT_NAME}"
