#!/usr/bin/env bash
set -euo pipefail

APP_PATH=""
CONFIGURATION="${CONFIGURATION:-Debug}"
SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
FRAMEWORK_SOURCE="$SRCROOT/Frameworks/CmuxChromiumCore/Sources/CmuxChromiumCore.swift"
BUILD_ROOT="${CMUX_CHROMIUM_CORE_BUILD_DIR:-$SRCROOT/.build/CmuxChromiumCore}"
FRAMEWORK_NAME="CmuxChromiumCore.framework"
MODULE_NAME="CmuxChromiumCore"
CHROMIUM_RUNTIME_REVISION="66fc3593cef3"
CHROMIUM_RUNTIME_RELEASE="66fc3593ce"
CHROMIUM_RUNTIME_TAG="owl-chromium-${CHROMIUM_RUNTIME_RELEASE}"
CHROMIUM_RUNTIME_BASENAME="owl-chromium-runtime-macos-arm64-${CHROMIUM_RUNTIME_REVISION}"
DEFAULT_DOWNLOAD_URL="https://github.com/manaflow-ai/chromium/releases/download/${CHROMIUM_RUNTIME_TAG}/${CHROMIUM_RUNTIME_BASENAME}.tar.gz"
DEFAULT_DOWNLOAD_SHA256="d412d1f2193b36900dcf0ea3a2436b5d8cf30cdc678503b68ebd86c9d73dd92b"
DOWNLOAD_URL="${CMUX_CHROMIUM_CONTENT_SHELL_ARCHIVE_URL:-$DEFAULT_DOWNLOAD_URL}"
EXPECTED_ARCHIVE_SHA256="${CMUX_CHROMIUM_CONTENT_SHELL_SHA256:-}"
if [[ "$DOWNLOAD_URL" == "$DEFAULT_DOWNLOAD_URL" && -z "$EXPECTED_ARCHIVE_SHA256" ]]; then
  EXPECTED_ARCHIVE_SHA256="$DEFAULT_DOWNLOAD_SHA256"
fi
if [[ "$DOWNLOAD_URL" != "$DEFAULT_DOWNLOAD_URL" && -z "$EXPECTED_ARCHIVE_SHA256" ]]; then
  echo "error: custom CMUX_CHROMIUM_CONTENT_SHELL_ARCHIVE_URL requires CMUX_CHROMIUM_CONTENT_SHELL_SHA256" >&2
  exit 1
fi
CACHE_ROOT="${CMUX_CHROMIUM_CONTENT_SHELL_CACHE:-$HOME/Library/Caches/cmux/chromium-content-shell/${CHROMIUM_RUNTIME_TAG}}"
RUNTIME_SANDBOX_DISABLED=false
RUNTIME_USES_IN_PROCESS_GPU_BY_DEFAULT=false
RUNTIME_FORBIDDEN_SWITCHES_JSON='["no-sandbox", "in-process-gpu"]'
RUNTIME_DEFAULT_SWITCHES_JSON='[
      "fresh-owl-embed",
      "fresh-owl-hosted-frame-pump",
      "content-shell-hide-toolbar",
      "no-first-run",
      "no-default-browser-check"
    ]'

usage() {
  cat <<'EOF'
Usage: scripts/build-cmux-chromium-core.sh [--app <path>] [--configuration Debug|Release]

Builds CmuxChromiumCore.framework and optionally embeds it into a cmux .app.
Set CMUX_CHROMIUM_CONTENT_SHELL_APP to use a specific patched Content Shell.app.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="${2:-}"
      [[ -n "$APP_PATH" ]] || { echo "error: --app requires a value" >&2; exit 1; }
      shift 2
      ;;
    --configuration)
      CONFIGURATION="${2:-}"
      [[ -n "$CONFIGURATION" ]] || { echo "error: --configuration requires a value" >&2; exit 1; }
      shift 2
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

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm64|aarch64) ;;
  *)
    echo "error: CmuxChromiumCore currently supports macOS arm64 only, got $HOST_ARCH" >&2
    exit 1
    ;;
esac

resolve_content_shell_app() {
  local candidate=""
  local -a candidates=()
  if [[ -n "${CMUX_CHROMIUM_CONTENT_SHELL_APP:-}" ]]; then
    candidates+=("$CMUX_CHROMIUM_CONTENT_SHELL_APP")
  fi
  candidates+=(
    "$CACHE_ROOT/${CHROMIUM_RUNTIME_BASENAME}/Content Shell.app"
    "$CACHE_ROOT/Content Shell.app"
  )
  if [[ "${CMUX_CHROMIUM_ALLOW_LOCAL_CONTENT_SHELL:-0}" == "1" ]]; then
    candidates+=(
      "$HOME/chromium/src/out/Release/Content Shell.app"
      "/Applications/Content Shell.app"
    )
  fi
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate/Contents/MacOS/Content Shell" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

download_content_shell_if_needed() {
  if resolve_content_shell_app >/dev/null; then
    return 0
  fi
  mkdir -p "$CACHE_ROOT"
  local archive="$CACHE_ROOT/content-shell.tar.gz"
  if [[ "$DOWNLOAD_URL" == "$DEFAULT_DOWNLOAD_URL" ]]; then
    archive="$CACHE_ROOT/${CHROMIUM_RUNTIME_BASENAME}.tar.gz"
  fi
  echo "Downloading patched browser runtime"
  curl -fL "$DOWNLOAD_URL" -o "$archive"
  if [[ -n "$EXPECTED_ARCHIVE_SHA256" ]]; then
    local actual
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [[ "$actual" != "$EXPECTED_ARCHIVE_SHA256" ]]; then
      echo "error: browser runtime checksum mismatch. expected=$EXPECTED_ARCHIVE_SHA256 actual=$actual" >&2
      exit 1
    fi
  fi
  tar -xzf "$archive" -C "$CACHE_ROOT"
}

chromium_version() {
  local app_path="$1"
  local src_dir="${CMUX_CHROMIUM_SRC:-$HOME/chromium/src}"
  if [[ -f "$src_dir/chrome/VERSION" ]]; then
    awk -F= '
      $1 == "MAJOR" { major=$2 }
      $1 == "MINOR" { minor=$2 }
      $1 == "BUILD" { build=$2 }
      $1 == "PATCH" { patch=$2 }
      END {
        if (major != "" && minor != "" && build != "" && patch != "") {
          printf "%s.%s.%s.%s", major, minor, build, patch
        }
      }
    ' "$src_dir/chrome/VERSION"
    return 0
  fi
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$app_path/Contents/Info.plist" 2>/dev/null || printf "unknown"
}

chromium_revision() {
  local runtime_root="${1:-}"
  if [[ -n "$runtime_root" && -f "$runtime_root/owl-runtime-manifest.json" ]]; then
    local revision
    revision="$(plutil -extract chromiumSourceCommit raw -o - "$runtime_root/owl-runtime-manifest.json" 2>/dev/null || true)"
    if [[ -n "$revision" ]]; then
      printf "%s" "$revision"
      return 0
    fi
  fi
  local src_dir="${CMUX_CHROMIUM_SRC:-$HOME/chromium/src}"
  git -C "$src_dir" rev-parse HEAD 2>/dev/null || printf "unknown"
}

content_shell_resource_dir() {
  local app_path="$1"
  local pak
  pak="$(find "$app_path/Contents/Frameworks/Content Shell Framework.framework" \
    -path '*/Resources/content_shell.pak' -print -quit 2>/dev/null)"
  [[ -n "$pak" ]] || return 1
  dirname "$pak"
}

content_shell_runtime_root() {
  local app_path="$1"
  local parent
  parent="$(dirname "$app_path")"
  if [[ -f "$parent/libowl_fresh_mojo_runtime.dylib" ]]; then
    echo "$parent"
    return 0
  fi
  if [[ -f "$app_path/Contents/Resources/libowl_fresh_mojo_runtime.dylib" ]]; then
    echo "$app_path/Contents/Resources"
    return 0
  fi
  echo "$parent"
}

normalize_bundle_permissions() {
  local path="$1"
  chmod -R u+rwX,go+rX "$path"
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$path"
  fi
}

prune_content_shell_runtime_files() {
  local app_path="$1"
  find "$app_path" \( -name '*.log' -o -name '*.tmp' -o -name '.DS_Store' \) -type f -delete
}

verify_runtime_launch_policy() {
  local runtime_root="$1"
  local dylib="$runtime_root/libowl_fresh_mojo_runtime.dylib"
  local manifest="$runtime_root/owl-runtime-manifest.json"
  local build_args="$runtime_root/owl-build-args.gn"
  for name in libowl_fresh_mojo_runtime.dylib owl-runtime-manifest.json owl-build-args.gn; do
    if [[ ! -f "$runtime_root/$name" ]]; then
      echo "error: browser runtime is missing a required component" >&2
      exit 1
    fi
  done
  if ! python3 -m json.tool "$manifest" >/dev/null; then
    echo "error: browser runtime metadata is not valid JSON" >&2
    exit 1
  fi
  if strings "$dylib" | awk 'index($0, "no-sandbox") > 0 || index($0, "--no-sandbox") > 0 { found = 1 } END { exit found ? 0 : 1 }'; then
    echo "error: browser runtime launch policy is not production-safe" >&2
    exit 1
  fi
  if awk '$0 ~ /(^|[^A-Za-z0-9_-])(no-sandbox|--no-sandbox)([^A-Za-z0-9_-]|$)/ { found = 1 } END { exit found ? 0 : 1 }' "$build_args"; then
    echo "error: browser runtime build policy is not production-safe" >&2
    exit 1
  fi
  if awk '$0 ~ /(^|[^A-Za-z0-9_-])(in-process-gpu|--in-process-gpu)([^A-Za-z0-9_-]|$)/ { found = 1 } END { exit found ? 0 : 1 }' "$build_args"; then
    echo "error: browser runtime graphics policy is not production-safe" >&2
    exit 1
  fi
}

verify_rendering_path() {
  local app_path="$1"
  local framework_binary
  framework_binary="$(find "$app_path/Contents/Frameworks/Content Shell Framework.framework" \
    -type f -name "Content Shell Framework" -print -quit 2>/dev/null)"
  if [[ -z "$framework_binary" ]]; then
    echo "error: Content Shell framework binary not found" >&2
    exit 1
  fi
  if ! strings "$framework_binary" | awk '$0 ~ /CALayerHost/ { layer = 1 } $0 ~ /IOSurface/ { surface = 1 } $0 ~ /Metal/ { metal = 1 } END { exit (layer && surface && metal) ? 0 : 1 }'; then
    echo "error: browser runtime does not expose the expected native rendering path" >&2
    exit 1
  fi
}

verify_no_cef() {
  local app_path="$1"
  if find "$app_path" -path '*Chromium Embedded Framework.framework*' -print -quit | grep -q .; then
    echo "error: browser runtime contains a disallowed embedding framework" >&2
    exit 1
  fi
  local -a binaries=(
    "$app_path/Contents/MacOS/Content Shell"
    "$app_path/Contents/Frameworks/Content Shell Framework.framework/Content Shell Framework"
    "$app_path/Contents/Frameworks/Content Shell Framework.framework/Versions/Current/Content Shell Framework"
  )
  local binary
  for binary in "${binaries[@]}"; do
    if [[ -f "$binary" ]] &&
      strings "$binary" | awk '
        $0 ~ /Chromium Embedded Framework|libcef|CefInitialize|CefBrowser|CEF.framework/ { found = 1 }
        END { exit found ? 0 : 1 }
      '; then
      echo "error: browser runtime contains disallowed embedding markers" >&2
      exit 1
    fi
  done
}

sign_path() {
  local path="$1"
  if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - --timestamp=none "$path" >/dev/null
  fi
}

sign_top_level_app_dylibs() {
  local app_path="$1"
  local macos_dir="$app_path/Contents/MacOS"
  [[ -d "$macos_dir" ]] || return 0

  local dylib
  while IFS= read -r -d '' dylib; do
    sign_path "$dylib"
  done < <(find "$macos_dir" -maxdepth 1 -type f -name '*.dylib' -print0)
}

sign_app_plugins() {
  local app_path="$1"
  local plugins_dir="$app_path/Contents/PlugIns"
  [[ -d "$plugins_dir" ]] || return 0

  local plugin
  while IFS= read -r -d '' plugin; do
    sign_path "$plugin"
  done < <(find "$plugins_dir" -maxdepth 1 -type d \( -name '*.plugin' -o -name '*.appex' -o -name '*.xpc' \) -print0)
}

resolve_framework_version_dir() {
  local framework="$1"
  local versions_dir="$framework/Versions"
  local current="$versions_dir/Current"
  if [[ -e "$current" ]]; then
    local target resolved
    target="$(readlink "$current")"
    if [[ "$target" = /* ]]; then
      resolved="$target"
    else
      resolved="$(cd "$versions_dir" && pwd -P)/$target"
    fi
    if [[ -d "$resolved" ]]; then
      echo "$resolved"
      return 0
    fi
  fi
  local -a versions=()
  while IFS= read -r -d '' version_dir; do
    versions+=("$version_dir")
  done < <(find "$versions_dir" -mindepth 1 -maxdepth 1 -type d ! -name Current -print0)
  if (( ${#versions[@]} > 0 )); then
    echo "${versions[$((${#versions[@]} - 1))]}"
    return 0
  fi
  echo "error: no framework version directory found under $versions_dir" >&2
  exit 1
}

sign_content_shell_app() {
  local app_path="$1"
  local chromium_framework="$app_path/Contents/Frameworks/Content Shell Framework.framework"
  if [[ ! -d "$chromium_framework" ]]; then
    echo "error: Content Shell framework not found at $chromium_framework" >&2
    exit 1
  fi
  local resolved_version_dir
  resolved_version_dir="$(resolve_framework_version_dir "$chromium_framework")"
  if [[ -d "$resolved_version_dir/Libraries" ]]; then
    while IFS= read -r -d '' library; do
      sign_path "$library"
    done < <(find "$resolved_version_dir/Libraries" -type f -name '*.dylib' -print0)
  fi
  if [[ -x "$resolved_version_dir/Helpers/chrome_crashpad_handler" ]]; then
    sign_path "$resolved_version_dir/Helpers/chrome_crashpad_handler"
  fi
  if [[ -d "$resolved_version_dir/Helpers" ]]; then
    while IFS= read -r -d '' helper_app; do
      sign_path "$helper_app"
    done < <(find "$resolved_version_dir/Helpers" -maxdepth 1 -type d -name '*.app' -print0)
  fi
  sign_path "$chromium_framework"
  sign_path "$app_path"
}

download_content_shell_if_needed
CONTENT_SHELL_APP="$(resolve_content_shell_app || true)"
if [[ -z "$CONTENT_SHELL_APP" ]]; then
  echo "error: patched Content Shell.app not found" >&2
  exit 1
fi
if [[ ! -f "$FRAMEWORK_SOURCE" ]]; then
  echo "error: missing framework source at $FRAMEWORK_SOURCE" >&2
  exit 1
fi
RESOURCE_SOURCE="$(content_shell_resource_dir "$CONTENT_SHELL_APP" || true)"
if [[ -z "$RESOURCE_SOURCE" ]]; then
  echo "error: Content Shell resources not found under $CONTENT_SHELL_APP" >&2
  exit 1
fi
RUNTIME_ROOT="$(content_shell_runtime_root "$CONTENT_SHELL_APP")"
verify_runtime_launch_policy "$RUNTIME_ROOT"
verify_no_cef "$CONTENT_SHELL_APP"
verify_rendering_path "$CONTENT_SHELL_APP"

PRODUCT_DIR="$BUILD_ROOT/$CONFIGURATION"
FRAMEWORK_DIR="$PRODUCT_DIR/$FRAMEWORK_NAME"
VERSION_DIR="$FRAMEWORK_DIR/Versions/A"
RESOURCE_DIR="$VERSION_DIR/Resources"
rm -rf "$FRAMEWORK_DIR"
mkdir -p "$VERSION_DIR" "$RESOURCE_DIR" "$VERSION_DIR/Modules/$MODULE_NAME.swiftmodule"

SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
SWIFT_OPT="-Onone"
if [[ "$CONFIGURATION" == "Release" ]]; then
  SWIFT_OPT="-O"
fi

xcrun swiftc \
  -emit-library \
  -emit-module \
  -module-name "$MODULE_NAME" \
  -parse-as-library \
  -target "arm64-apple-macos${DEPLOYMENT_TARGET}" \
  -sdk "$SDKROOT" \
  "$SWIFT_OPT" \
  -framework AppKit \
  -framework QuartzCore \
  -Xlinker -install_name \
  -Xlinker "@rpath/$FRAMEWORK_NAME/Versions/A/$MODULE_NAME" \
  "$FRAMEWORK_SOURCE" \
  -o "$VERSION_DIR/$MODULE_NAME" \
  -emit-module-path "$VERSION_DIR/Modules/$MODULE_NAME.swiftmodule/arm64-apple-macos.swiftmodule"

if [[ -f "$VERSION_DIR/$MODULE_NAME.swiftdoc" ]]; then
  mv "$VERSION_DIR/$MODULE_NAME.swiftdoc" "$VERSION_DIR/Modules/$MODULE_NAME.swiftmodule/arm64-apple-macos.swiftdoc"
fi
if [[ -f "$VERSION_DIR/$MODULE_NAME.swiftsourceinfo" ]]; then
  mv "$VERSION_DIR/$MODULE_NAME.swiftsourceinfo" "$VERSION_DIR/Modules/$MODULE_NAME.swiftmodule/arm64-apple-macos.swiftsourceinfo"
fi

cat > "$RESOURCE_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$MODULE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.cmuxterm.chromium-core</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$MODULE_NAME</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>MinimumOSVersion</key>
  <string>$DEPLOYMENT_TARGET</string>
</dict>
</plist>
EOF

rsync -a --delete "$CONTENT_SHELL_APP" "$RESOURCE_DIR/"
prune_content_shell_runtime_files "$RESOURCE_DIR/Content Shell.app"
for name in content_shell.pak icudtl.dat v8_context_snapshot.arm64.bin; do
  if [[ -f "$RESOURCE_SOURCE/$name" ]]; then
    rsync -a "$RESOURCE_SOURCE/$name" "$RESOURCE_DIR/$name"
  fi
done
for name in libowl_fresh_mojo_runtime.dylib owl-runtime-manifest.json owl-build-args.gn; do
  if [[ -f "$RUNTIME_ROOT/$name" ]]; then
    rsync -a "$RUNTIME_ROOT/$name" "$RESOURCE_DIR/$name"
  fi
done

VERSION_STRING="$(chromium_version "$CONTENT_SHELL_APP")"
REVISION_STRING="$(chromium_revision "$RUNTIME_ROOT")"
cat > "$RESOURCE_DIR/cmux-chromium-manifest.json" <<EOF
{
  "engine": "chromium-owl-fresh-mojo",
  "chromiumVersion": "$VERSION_STRING",
  "chromiumRevision": "$REVISION_STRING",
  "frameworkName": "$FRAMEWORK_NAME",
  "resourceNames": [
    "Content Shell.app",
    "libowl_fresh_mojo_runtime.dylib",
    "content_shell.pak",
    "icudtl.dat",
    "v8_context_snapshot.arm64.bin"
  ],
  "hostClassName": "CmuxChromiumBrowserHost",
  "hostFactoryClassName": "CmuxChromiumBrowserHostFactory",
  "hostAPIVersion": 1,
  "renderingAPI": {
    "nativeViewHost": "Chromium remote_cocoa WebContents NSView",
    "compositorLayer": "CALayerHost",
    "surfaceTransport": "IOSurface/Metal"
  },
  "launchPolicy": {
    "sandboxDisabled": $RUNTIME_SANDBOX_DISABLED,
    "usesInProcessGPUByDefault": $RUNTIME_USES_IN_PROCESS_GPU_BY_DEFAULT,
    "defaultSwitches": $RUNTIME_DEFAULT_SWITCHES_JSON,
    "forbiddenSwitchesVerifiedAbsent": $RUNTIME_FORBIDDEN_SWITCHES_JSON
  }
}
EOF

ln -s A "$FRAMEWORK_DIR/Versions/Current"
ln -s Versions/Current/$MODULE_NAME "$FRAMEWORK_DIR/$MODULE_NAME"
ln -s Versions/Current/Resources "$FRAMEWORK_DIR/Resources"
ln -s Versions/Current/Modules "$FRAMEWORK_DIR/Modules"

normalize_bundle_permissions "$FRAMEWORK_DIR"
if [[ -f "$RESOURCE_DIR/libowl_fresh_mojo_runtime.dylib" ]]; then
  sign_path "$RESOURCE_DIR/libowl_fresh_mojo_runtime.dylib"
fi
sign_content_shell_app "$RESOURCE_DIR/Content Shell.app"
sign_path "$FRAMEWORK_DIR"

if [[ -n "$APP_PATH" ]]; then
  if [[ ! -d "$APP_PATH" ]]; then
    echo "error: app path not found: $APP_PATH" >&2
    exit 1
  fi
  DEST="$APP_PATH/Contents/Frameworks/$FRAMEWORK_NAME"
  mkdir -p "$APP_PATH/Contents/Frameworks"
  rm -rf "$DEST"
  rsync -a "$FRAMEWORK_DIR" "$APP_PATH/Contents/Frameworks/"
  normalize_bundle_permissions "$DEST"
  if [[ -f "$DEST/Resources/libowl_fresh_mojo_runtime.dylib" ]]; then
    sign_path "$DEST/Resources/libowl_fresh_mojo_runtime.dylib"
  fi
  sign_content_shell_app "$DEST/Resources/Content Shell.app"
  sign_path "$DEST"
  if [[ -d "$APP_PATH/Contents/PlugIns" ]] &&
    find "$APP_PATH/Contents/PlugIns" -name '*.xctest' -print -quit | grep -q .; then
    echo "Skipping outer app re-sign for Xcode test host bundle"
  else
    sign_top_level_app_dylibs "$APP_PATH"
    sign_app_plugins "$APP_PATH"
    sign_path "$APP_PATH"
  fi
  echo "Embedded $FRAMEWORK_NAME into $APP_PATH"
else
  echo "$FRAMEWORK_DIR"
fi
