#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$REPO_ROOT/Apps/SurfaceStatus/SurfaceStatus.xcodeproj"
SCHEME="SurfaceStatus"
CONFIGURATION="Debug"
DERIVED_DATA="${CMUX_SURFACE_SIDEBAR_DERIVED_DATA:-/tmp/cmux-surface-status-sidebar}"
INSTALL_DIR="${CMUX_SURFACE_SIDEBAR_INSTALL_DIR:-/Applications}"
APP_NAME="CMUX Surface Status Sidebar.app"
EXTENSION_NAME="CMUX Surface Status Sidebar Extension.appex"
EXTENSION_POINT="com.cmuxterm.app.cmux.sidebar"
RESTART_CMUX=0
REFRESH_CMUX=0
CLEAN_BUILD=0
VERBOSE=0
BUILD_LOG="${CMUX_SURFACE_SIDEBAR_BUILD_LOG:-/tmp/cmux-surface-status-sidebar-build.log}"

usage() {
  cat <<'EOF'
Build, sign, install, and register the Surface Status sidebar extension for the
official CMUX app. This does not build or modify CMUX itself.

Usage:
  scripts/deploy-surface-status-sidebar.sh [options]

Options:
  --refresh            Redeploy, restart CMUX, and restore the extension sidebar.
  --restart-cmux       Quit and reopen CMUX after registration.
  --clean              Remove DerivedData before building.
  --install-dir PATH   Install directory (default: /Applications).
                       Use "$HOME/Applications" to avoid administrator access.
  --derived-data PATH  Xcode DerivedData path.
  --verbose            Stream the full xcodebuild output.
  -h, --help           Show this help.

Environment equivalents:
  CMUX_SURFACE_SIDEBAR_INSTALL_DIR
  CMUX_SURFACE_SIDEBAR_DERIVED_DATA
  CMUX_SURFACE_SIDEBAR_BUILD_LOG

Prerequisite:
  Select an Apple Development/Personal Team for both Xcode targets once.
EOF
}

while (($#)); do
  case "$1" in
    --refresh)
      REFRESH_CMUX=1
      RESTART_CMUX=1
      shift
      ;;
    --restart-cmux)
      RESTART_CMUX=1
      shift
      ;;
    --clean)
      CLEAN_BUILD=1
      shift
      ;;
    --install-dir)
      [[ $# -ge 2 ]] || { echo "error: --install-dir requires a path" >&2; exit 2; }
      INSTALL_DIR="$2"
      shift 2
      ;;
    --derived-data)
      [[ $# -ge 2 ]] || { echo "error: --derived-data requires a path" >&2; exit 2; }
      DERIVED_DATA="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for command in xcodebuild codesign ditto pluginkit open; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: required command not found: $command" >&2
    exit 1
  }
done

[[ -d "$PROJECT" ]] || {
  echo "error: Xcode project not found: $PROJECT" >&2
  exit 1
}

if [[ "$CLEAN_BUILD" == "1" ]]; then
  echo "==> Removing DerivedData: $DERIVED_DATA"
  rm -rf "$DERIVED_DATA"
fi

echo "==> Checking signing configuration"
APP_SETTINGS="$(xcodebuild \
  -project "$PROJECT" \
  -target SurfaceStatusApp \
  -configuration "$CONFIGURATION" \
  -showBuildSettings 2>/dev/null)"
EXT_SETTINGS="$(xcodebuild \
  -project "$PROJECT" \
  -target SurfaceStatusExtension \
  -configuration "$CONFIGURATION" \
  -showBuildSettings 2>/dev/null)"

APP_TEAM="$(awk -F ' = ' '/^[[:space:]]*DEVELOPMENT_TEAM = / { print $2; exit }' <<<"$APP_SETTINGS")"
EXT_TEAM="$(awk -F ' = ' '/^[[:space:]]*DEVELOPMENT_TEAM = / { print $2; exit }' <<<"$EXT_SETTINGS")"
CONFIGURED_POINT="$(awk -F ' = ' '/^[[:space:]]*CMUX_SIDEBAR_EXTENSION_POINT_ID = / { print $2; exit }' <<<"$EXT_SETTINGS")"

[[ -n "$APP_TEAM" && -n "$EXT_TEAM" ]] || {
  echo "error: select an Apple Development team for both app and extension targets" >&2
  exit 1
}
[[ "$APP_TEAM" == "$EXT_TEAM" ]] || {
  echo "error: app team ($APP_TEAM) and extension team ($EXT_TEAM) differ" >&2
  exit 1
}
[[ "$CONFIGURED_POINT" == "$EXTENSION_POINT" ]] || {
  echo "error: extension point is '$CONFIGURED_POINT'; expected '$EXTENSION_POINT'" >&2
  exit 1
}

echo "    Team: $APP_TEAM"
echo "    Extension point: $EXTENSION_POINT"

echo "==> Building and signing extension container"
echo "    Full build log: $BUILD_LOG"
mkdir -p "$(dirname "$BUILD_LOG")"
: > "$BUILD_LOG"

XCODEBUILD_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "platform=macOS,arch=$(uname -m)"
  -derivedDataPath "$DERIVED_DATA"
  -allowProvisioningUpdates
  build
)

if [[ "$VERBOSE" == "1" ]]; then
  set +e
  xcodebuild "${XCODEBUILD_ARGS[@]}" 2>&1 | tee "$BUILD_LOG"
  BUILD_STATUS=${PIPESTATUS[0]}
  set -e
else
  set +e
  xcodebuild "${XCODEBUILD_ARGS[@]}" >"$BUILD_LOG" 2>&1
  BUILD_STATUS=$?
  set -e
fi

if [[ "$BUILD_STATUS" -ne 0 ]]; then
  echo "error: xcodebuild failed (exit $BUILD_STATUS)" >&2
  echo "==> Last 100 build-log lines" >&2
  tail -n 100 "$BUILD_LOG" >&2
  exit "$BUILD_STATUS"
fi

echo "    Build succeeded"

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME"
BUILT_EXTENSION="$BUILT_APP/Contents/Extensions/$EXTENSION_NAME"
[[ -d "$BUILT_APP" ]] || { echo "error: built app not found: $BUILT_APP" >&2; exit 1; }
[[ -d "$BUILT_EXTENSION" ]] || { echo "error: embedded extension not found: $BUILT_EXTENSION" >&2; exit 1; }

ACTUAL_POINT="$(/usr/libexec/PlistBuddy -c 'Print :EXAppExtensionAttributes:EXExtensionPointIdentifier' "$BUILT_EXTENSION/Contents/Info.plist")"
[[ "$ACTUAL_POINT" == "$EXTENSION_POINT" ]] || {
  echo "error: built extension point is '$ACTUAL_POINT'; expected '$EXTENSION_POINT'" >&2
  exit 1
}

ENTITLEMENTS="$(codesign -d --entitlements :- "$BUILT_EXTENSION" 2>/dev/null || true)"
if ! grep -Fq 'com.apple.security.temporary-exception.files.home-relative-path.read-only' <<<"$ENTITLEMENTS" ||
   ! grep -Fq '/.cmuxterm/' <<<"$ENTITLEMENTS" ||
   ! grep -Fq '/.claude/projects/' <<<"$ENTITLEMENTS"; then
  echo "error: built extension is missing read-only access to lifecycle stores or Claude transcripts" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$BUILT_APP"

echo "==> Installing into $INSTALL_DIR"
DESTINATION="$INSTALL_DIR/$APP_NAME"
STAGED_DESTINATION="$INSTALL_DIR/.$APP_NAME.stage.$$"
BACKUP_DESTINATION="$INSTALL_DIR/.$APP_NAME.backup.$$"
INSTALL_USES_SUDO=0
DESTINATION_EXISTED=0
PROMOTED_DESTINATION=0
if ! { [[ -d "$INSTALL_DIR" && -w "$INSTALL_DIR" ]] || [[ ! -e "$INSTALL_DIR" && -w "$(dirname "$INSTALL_DIR")" ]]; }; then
  INSTALL_USES_SUDO=1
  echo "    Administrator permission is required for $INSTALL_DIR"
fi

install_run() {
  if [[ "$INSTALL_USES_SUDO" == "1" ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

rollback_install() {
  local status=$?
  if [[ "$PROMOTED_DESTINATION" == "1" ]]; then
    pluginkit -r "$DESTINATION/Contents/Extensions/$EXTENSION_NAME" >/dev/null 2>&1 || true
    install_run rm -rf "$DESTINATION" >/dev/null 2>&1 || true
  fi
  if [[ -d "$BACKUP_DESTINATION" ]]; then
    install_run mv "$BACKUP_DESTINATION" "$DESTINATION" >/dev/null 2>&1 || true
    pluginkit -a "$DESTINATION/Contents/Extensions/$EXTENSION_NAME" >/dev/null 2>&1 || true
  fi
  install_run rm -rf "$STAGED_DESTINATION" >/dev/null 2>&1 || true
  return "$status"
}
trap rollback_install ERR INT TERM

install_run mkdir -p "$INSTALL_DIR"
install_run rm -rf "$STAGED_DESTINATION" "$BACKUP_DESTINATION"
install_run ditto "$BUILT_APP" "$STAGED_DESTINATION"
codesign --verify --deep --strict --verbose=2 "$STAGED_DESTINATION"

STAGED_EXTENSION="$STAGED_DESTINATION/Contents/Extensions/$EXTENSION_NAME"
[[ -d "$STAGED_EXTENSION" ]] || { echo "error: staged extension not found: $STAGED_EXTENSION" >&2; false; }
STAGED_POINT="$(/usr/libexec/PlistBuddy -c 'Print :EXAppExtensionAttributes:EXExtensionPointIdentifier' "$STAGED_EXTENSION/Contents/Info.plist")"
[[ "$STAGED_POINT" == "$EXTENSION_POINT" ]] || { echo "error: staged extension point is '$STAGED_POINT'" >&2; false; }

if [[ -e "$DESTINATION" ]]; then
  DESTINATION_EXISTED=1
  [[ -d "$DESTINATION" ]] || { echo "error: refusing to replace non-directory: $DESTINATION" >&2; false; }
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist" 2>/dev/null || true)"
  BUILT_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILT_APP/Contents/Info.plist")"
  [[ "$EXISTING_ID" == "$BUILT_ID" ]] || { echo "error: refusing to replace unrecognized app at $DESTINATION" >&2; false; }
  install_run mv "$DESTINATION" "$BACKUP_DESTINATION"
fi
install_run mv "$STAGED_DESTINATION" "$DESTINATION"
PROMOTED_DESTINATION=1

INSTALLED_EXTENSION="$DESTINATION/Contents/Extensions/$EXTENSION_NAME"
codesign --verify --deep --strict --verbose=2 "$DESTINATION"

echo "==> Registering app and sidebar extension"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
"$LSREGISTER" -f -R -trusted "$DESTINATION"
pluginkit -a "$INSTALLED_EXTENSION"

# Launch Services + pluginkit registration is sufficient on refresh. Avoid
# foregrounding the containing installer app on every UI iteration.
sleep 1

echo "==> Registered CMUX sidebar extensions"
REGISTERED="$(pluginkit -m -A -D -v -p "$EXTENSION_POINT" 2>&1 || true)"
printf '%s\n' "$REGISTERED"
if ! grep -Fq "$INSTALLED_EXTENSION" <<<"$REGISTERED"; then
  echo "error: registration output does not point to the installed extension" >&2
  false
fi

# Xcode/Launch Services may register the DerivedData copy while building. Keep
# one deterministic candidate so ExtensionKit never launches a stale binary.
pluginkit -r "$BUILT_EXTENSION" >/dev/null 2>&1 || true
pluginkit -a "$INSTALLED_EXTENSION"
REGISTERED="$(pluginkit -m -A -D -v -p "$EXTENSION_POINT" 2>&1 || true)"
MATCHING_PATHS="$(printf '%s\n' "$REGISTERED" | grep -F 'CMUX Surface Status Sidebar Extension.appex' || true)"
if grep -Fq "$BUILT_EXTENSION" <<<"$MATCHING_PATHS"; then
  echo "error: temporary build extension remains registered: $BUILT_EXTENSION" >&2
  false
fi

install_run rm -rf "$BACKUP_DESTINATION"
PROMOTED_DESTINATION=0
trap - ERR INT TERM

if [[ "$REFRESH_CMUX" == "1" ]]; then
  echo "==> Selecting the extension sidebar provider"
  defaults write com.cmuxterm.app 'extensions.beta.enabled' -bool true
  defaults write com.cmuxterm.app 'cmuxExtensionSidebar.providerId' 'cmux.sidebar.extensions'
  defaults write com.cmuxterm.app 'cmuxExtensionSidebar.selectedExtensionName' 'Surface Status'

  # Paint the host-owned sidebar material before ExtensionKit cold-launches the
  # remote view. Keeping this persistent surface untinted prevents the one-frame
  # color swap that otherwise appears when the extension first opens.
  defaults write com.cmuxterm.app sidebarPreset -string nativeSidebar
  defaults write com.cmuxterm.app sidebarMaterial -string sidebar
  # Keep the sidebar in its own layout lane. withinWindow overlays it above
  # terminal content, which can briefly show through while ExtensionKit creates
  # the remote view; behindWindow prevents that non-native startup flash.
  defaults write com.cmuxterm.app sidebarBlendMode -string behindWindow
  defaults write com.cmuxterm.app sidebarState -string followWindow
  defaults write com.cmuxterm.app sidebarTintOpacity -float 0
  defaults write com.cmuxterm.app sidebarBlurOpacity -float 1
  defaults write com.cmuxterm.app sidebarCornerRadius -float 0
  defaults write com.cmuxterm.app sidebarMatchTerminalBackground -bool false
fi

if [[ "$RESTART_CMUX" == "1" ]]; then
  echo "==> Restarting CMUX"
  osascript -e 'tell application id "com.cmuxterm.app" to quit' >/dev/null 2>&1 || true
  sleep 1
  open -a cmux
fi

cat <<EOF

Deployment complete.

Installed app:
  $DESTINATION

Next steps in CMUX:
  1. Open the sidebar puzzle-piece menu.
  2. Open Sidebar Extensions.
  3. Enable "Surface Status" and grant its requested permissions.
  4. Select "Surface Status" as the sidebar provider.

The containing app may be closed, but keep it installed because it owns the
embedded extension.

Agent lifecycle integrations are managed separately from the companion app UI;
this deployment script never modifies shell or agent configuration.
EOF
