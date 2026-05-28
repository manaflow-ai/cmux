#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="$ROOT/zig-out/package/zero-cmux.app"
APP_NAME="zero-cmux"
BUNDLE_ID="com.cmux.zero-native"
BINARY="$ROOT/zig-out/bin/zero-cmux"
CEF_DIR="$ROOT/third_party/cef/macos"
SIGN=1

usage() {
  cat <<'EOF'
Usage: scripts/package-app.sh [options]

Options:
  --output <path>      Output .app path.
  --name <name>        App and executable display name.
  --bundle-id <id>     Main bundle identifier.
  --binary <path>      Built zero-cmux executable.
  --cef-dir <path>     CEF runtime directory.
  --no-sign            Skip ad-hoc signing.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT="${2:?}"
      shift 2
      ;;
    --name)
      APP_NAME="${2:?}"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:?}"
      shift 2
      ;;
    --binary)
      BINARY="${2:?}"
      shift 2
      ;;
    --cef-dir)
      CEF_DIR="${2:?}"
      shift 2
      ;;
    --no-sign)
      SIGN=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

CEF_FRAMEWORK="$CEF_DIR/Release/Chromium Embedded Framework.framework"
if [[ ! -x "$BINARY" ]]; then
  echo "error: missing executable: $BINARY" >&2
  exit 1
fi
if [[ ! -d "$CEF_FRAMEWORK" ]]; then
  echo "error: missing CEF framework: $CEF_FRAMEWORK" >&2
  exit 1
fi

sanitize_id_component() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//; s/\.+/./g'
}

plist_add() {
  local plist="$1"
  local key="$2"
  local type="$3"
  local value="$4"
  /usr/libexec/PlistBuddy -c "Add :${key} ${type} ${value}" "$plist" >/dev/null
}

write_plist() {
  local plist="$1"
  local executable="$2"
  local bundle_id="$3"
  local name="$4"
  local background="${5:-0}"
  plutil -create xml1 "$plist"
  plist_add "$plist" CFBundleExecutable string "$executable"
  plist_add "$plist" CFBundleIdentifier string "$bundle_id"
  plist_add "$plist" CFBundleName string "$name"
  plist_add "$plist" CFBundleDisplayName string "$name"
  plist_add "$plist" CFBundlePackageType string APPL
  plist_add "$plist" CFBundleVersion string 1
  plist_add "$plist" CFBundleShortVersionString string 0.1.0
  plist_add "$plist" NSHighResolutionCapable bool YES
  if [[ "$background" == "1" ]]; then
    plist_add "$plist" LSBackgroundOnly bool YES
  fi
}

copy_runtime_siblings() {
  local destination="$1"
  mkdir -p "$destination"
  for item in libEGL.dylib libGLESv2.dylib libvk_swiftshader.dylib libvulkan.1.dylib vk_swiftshader_icd.json; do
    if [[ -e "$CEF_FRAMEWORK/Libraries/$item" ]]; then
      cp -f "$CEF_FRAMEWORK/Libraries/$item" "$destination/$item"
    fi
  done
}

install_helper() {
  local helper_name="$1"
  local helper_suffix="$2"
  local helper_app="$OUTPUT/Contents/Frameworks/${helper_name}.app"
  local helper_macos="$helper_app/Contents/MacOS"
  local helper_frameworks="$helper_app/Contents/Frameworks"
  local helper_plist="$helper_app/Contents/Info.plist"

  mkdir -p "$helper_macos" "$helper_frameworks" "$helper_app/Contents/Resources"
  cp -f "$BINARY" "$helper_macos/$helper_name"
  chmod +x "$helper_macos/$helper_name"
  ln -sfn "../../../Chromium Embedded Framework.framework" "$helper_frameworks/Chromium Embedded Framework.framework"
  copy_runtime_siblings "$helper_macos"
  write_plist "$helper_plist" "$helper_name" "${BUNDLE_ID}.${helper_suffix}" "$helper_name" 1
}

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Frameworks" "$OUTPUT/Contents/Resources"

cp -f "$BINARY" "$OUTPUT/Contents/MacOS/$APP_NAME"
chmod +x "$OUTPUT/Contents/MacOS/$APP_NAME"
cp -R "$CEF_FRAMEWORK" "$OUTPUT/Contents/Frameworks/Chromium Embedded Framework.framework"
copy_runtime_siblings "$OUTPUT/Contents/MacOS"
write_plist "$OUTPUT/Contents/Info.plist" "$APP_NAME" "$BUNDLE_ID" "$APP_NAME" 0
printf 'APPL????' > "$OUTPUT/Contents/PkgInfo"

install_helper "$APP_NAME Helper" "helper"
install_helper "$APP_NAME Helper (GPU)" "helper.$(sanitize_id_component GPU)"
install_helper "$APP_NAME Helper (Plugin)" "helper.$(sanitize_id_component Plugin)"
install_helper "$APP_NAME Helper (Renderer)" "helper.$(sanitize_id_component Renderer)"

if [[ "$SIGN" == "1" ]]; then
  find "$OUTPUT/Contents/Frameworks" -maxdepth 1 -type d -name "*.app" -print0 |
    while IFS= read -r -d '' helper_app; do
      /usr/bin/codesign --force --deep --sign - --timestamp=none "$helper_app" >/dev/null 2>&1
    done
  /usr/bin/codesign --force --deep --sign - --timestamp=none "$OUTPUT" >/dev/null 2>&1
fi

echo "App path:"
echo "  $OUTPUT"
