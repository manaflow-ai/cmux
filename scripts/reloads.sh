#!/usr/bin/env bash
set -euo pipefail

APP_NAME="cmux STAGING"
BUNDLE_ID="com.cmuxterm.app.staging"
BASE_APP_NAME="cmux"
DERIVED_DATA=""
NAME_SET=0
BUNDLE_SET=0
DERIVED_SET=0
TAG=""
# Matches CmuxStateDirectory (non-TCC ~/.local/state/cmux) where the app/CLI now
# read the last-socket-path markers (https://github.com/manaflow-ai/cmux/issues/5146).
# Resolve the real account home via getpwuid (the same syscall
# homeDirectoryForCurrentUser uses) rather than $HOME, which a shell can override.
# perl ships with macOS and returns the full home path even when it contains spaces;
# `dscl ... | awk` mis-parses such paths because dscl wraps a value with spaces onto
# a second line. `|| true` keeps the lookup from aborting the script under
# `set -euo pipefail`; an empty result falls back to $HOME.
_cmux_account_home="$(perl -e 'print((getpwuid($<))[7])' 2>/dev/null || true)"
LAST_SOCKET_PATH_DIR="${_cmux_account_home:-$HOME}/.local/state/cmux"

write_last_socket_path() {
  local socket_path="$1"
  local marker_name="staging-last-socket-path"
  local tmp_marker="/tmp/cmux-staging-last-socket-path"
  if [[ -n "${STAGING_SLUG:-}" ]]; then
    marker_name="staging-${STAGING_SLUG}-last-socket-path"
    tmp_marker="/tmp/cmux-staging-${STAGING_SLUG}-last-socket-path"
  fi
  mkdir -p "$LAST_SOCKET_PATH_DIR"
  echo "$socket_path" > "${LAST_SOCKET_PATH_DIR}/${marker_name}" || true
  echo "$socket_path" > "$tmp_marker" || true
}

staging_slug_from_bundle_id() {
  local bundle_id="$1"
  local suffix=""
  if [[ "$bundle_id" == "com.cmuxterm.app.staging."* ]]; then
    suffix="${bundle_id#com.cmuxterm.app.staging.}"
  fi
  sanitize_path "$suffix"
}

usage() {
  cat <<'EOF'
Usage: ./scripts/reloads.sh [options]

Release build with isolated "cmux STAGING" identity. Runs side-by-side with
the production cmux app.

Options:
  --tag <name>           Short tag for parallel builds (e.g., feature-xyz-lol).
                         Sets app name, bundle id, and derived data path unless overridden.
  --name <app name>      Override app display/bundle name.
  --bundle-id <id>       Override bundle identifier.
  --derived-data <path>  Override derived data path.
  -h, --help             Show this help.
EOF
}

sanitize_bundle() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\\.+//; s/\\.+$//; s/\\.+/./g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="agent"
  fi
  echo "$cleaned"
}

sanitize_path() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  echo "$cleaned"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      if [[ -z "$TAG" ]]; then
        echo "error: --tag requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --name)
      APP_NAME="${2:-}"
      if [[ -z "$APP_NAME" ]]; then
        echo "error: --name requires a value" >&2
        exit 1
      fi
      NAME_SET=1
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      if [[ -z "$BUNDLE_ID" ]]; then
        echo "error: --bundle-id requires a value" >&2
        exit 1
      fi
      BUNDLE_SET=1
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA="${2:-}"
      if [[ -z "$DERIVED_DATA" ]]; then
        echo "error: --derived-data requires a value" >&2
        exit 1
      fi
      DERIVED_SET=1
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -n "$TAG" ]]; then
  TAG_ID="$(sanitize_bundle "$TAG")"
  TAG_SLUG="$(sanitize_path "$TAG")"
  if [[ -z "$TAG_SLUG" ]]; then
    echo "error: --tag must contain at least one alphanumeric character" >&2
    exit 1
  fi
  if [[ "$NAME_SET" -eq 0 ]]; then
    APP_NAME="cmux STAGING ${TAG}"
  fi
  if [[ "$BUNDLE_SET" -eq 0 ]]; then
    BUNDLE_ID="com.cmuxterm.app.staging.${TAG_ID}"
  fi
  if [[ "$DERIVED_SET" -eq 0 ]]; then
    DERIVED_DATA="/tmp/cmux-staging-${TAG_SLUG}"
  fi
fi

# Minimal entitlements for a locally dev-signed staging build: just the
# team-prefixed keychain access group, which an auto-provisioned development
# profile will accept. Auto-created if missing so a fresh checkout needs no
# manual setup. Override the location via CMUX_STAGING_ENTITLEMENTS.
STAGING_ENTITLEMENTS="${CMUX_STAGING_ENTITLEMENTS:-$HOME/Library/Application Support/cmux/staging.entitlements}"
if [[ ! -f "$STAGING_ENTITLEMENTS" ]]; then
  mkdir -p "$(dirname "$STAGING_ENTITLEMENTS")"
  cat > "$STAGING_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>keychain-access-groups</key>
    <array>
        <string>$(AppIdentifierPrefix)$(CFBundleIdentifier)</string>
    </array>
</dict>
</plist>
PLIST
  echo "==> Created staging entitlements at $STAGING_ENTITLEMENTS"
fi

XCODEBUILD_ARGS=(
  -project cmux.xcodeproj
  -scheme cmux
  -configuration Release
  -destination 'platform=macOS'
  -allowProvisioningUpdates
  DEVELOPMENT_TEAM="${CMUX_DEV_TEAM:-HH3SJBAS42}"
  CODE_SIGN_STYLE=Automatic
  CODE_SIGN_ENTITLEMENTS="$STAGING_ENTITLEMENTS"
  ONLY_ACTIVE_ARCH=YES
  # Pink/red app icon so the STAGING build is visually distinct from production
  # cmux in the Dock, Finder, and Cmd-Tab. AppIcon-Staging is a hue-shifted
  # variant of AppIcon in Assets.xcassets (same mechanism as AppIcon-Debug).
  ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon-Staging
)
if [[ -n "$DERIVED_DATA" ]]; then
  XCODEBUILD_ARGS+=(-derivedDataPath "$DERIVED_DATA")
fi
if [[ -z "$TAG" ]]; then
  XCODEBUILD_ARGS+=(
    INFOPLIST_KEY_CFBundleName="$APP_NAME"
    INFOPLIST_KEY_CFBundleDisplayName="$APP_NAME"
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
  )
fi
XCODEBUILD_ARGS+=(build)

xcodebuild "${XCODEBUILD_ARGS[@]}"
sleep 0.2

FALLBACK_APP_NAME="$BASE_APP_NAME"
SEARCH_APP_NAME="$APP_NAME"
if [[ -n "$TAG" ]]; then
  SEARCH_APP_NAME="$BASE_APP_NAME"
fi
if [[ -n "$DERIVED_DATA" ]]; then
  APP_PATH="${DERIVED_DATA}/Build/Products/Release/${SEARCH_APP_NAME}.app"
  if [[ ! -d "${APP_PATH}" && "$SEARCH_APP_NAME" != "$FALLBACK_APP_NAME" ]]; then
    APP_PATH="${DERIVED_DATA}/Build/Products/Release/${FALLBACK_APP_NAME}.app"
  fi
else
  APP_BINARY="$(
    find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/${SEARCH_APP_NAME}.app/Contents/MacOS/${SEARCH_APP_NAME}" -print0 \
    | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
    | sort -nr \
    | head -n 1 \
    | cut -d' ' -f2-
  )"
  if [[ -n "${APP_BINARY}" ]]; then
    APP_PATH="$(dirname "$(dirname "$(dirname "$APP_BINARY")")")"
  fi
  if [[ -z "${APP_PATH:-}" && "$SEARCH_APP_NAME" != "$FALLBACK_APP_NAME" ]]; then
    APP_BINARY="$(
      find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/${FALLBACK_APP_NAME}.app/Contents/MacOS/${FALLBACK_APP_NAME}" -print0 \
      | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
      | sort -nr \
      | head -n 1 \
      | cut -d' ' -f2-
    )"
    if [[ -n "${APP_BINARY}" ]]; then
      APP_PATH="$(dirname "$(dirname "$(dirname "$APP_BINARY")")")"
    fi
  fi
fi
if [[ -z "${APP_PATH:-}" || ! -d "${APP_PATH}" ]]; then
  echo "${APP_NAME}.app not found in DerivedData" >&2
  exit 1
fi

# Staging always copies the built app and patches the plist to set an isolated
# socket path, bundle id, and display name. This prevents conflicts with the
# production cmux app.
STAGING_APP_PATH="$(dirname "$APP_PATH")/${APP_NAME}.app"
rm -rf "$STAGING_APP_PATH"
cp -R "$APP_PATH" "$STAGING_APP_PATH"
INFO_PLIST="$STAGING_APP_PATH/Contents/Info.plist"
if [[ -f "$INFO_PLIST" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$INFO_PLIST"

  # Inject staging socket paths via LSEnvironment so the Release binary
  # (which defaults to the per-user stable socket) uses isolated sockets instead.
  STAGING_SLUG="$(staging_slug_from_bundle_id "$BUNDLE_ID")"
  APP_SUPPORT_DIR="$HOME/Library/Application Support/cmux"
  if [[ -n "$STAGING_SLUG" ]]; then
    CMUXD_SOCKET="${APP_SUPPORT_DIR}/cmuxd-${STAGING_SLUG}.sock"
    CMUX_SOCKET_PATH_VALUE="/tmp/cmux-staging-${STAGING_SLUG}.sock"
  else
    CMUXD_SOCKET="${APP_SUPPORT_DIR}/cmuxd-staging.sock"
    CMUX_SOCKET_PATH_VALUE="/tmp/cmux-staging.sock"
  fi
  write_last_socket_path "$CMUX_SOCKET_PATH_VALUE"
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$INFO_PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :LSEnvironment:CMUX_BUNDLE_ID \"${BUNDLE_ID}\"" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CMUX_BUNDLE_ID string \"${BUNDLE_ID}\"" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :LSEnvironment:CMUXD_UNIX_PATH \"${CMUXD_SOCKET}\"" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CMUXD_UNIX_PATH string \"${CMUXD_SOCKET}\"" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :LSEnvironment:CMUX_SOCKET_PATH \"${CMUX_SOCKET_PATH_VALUE}\"" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CMUX_SOCKET_PATH string \"${CMUX_SOCKET_PATH_VALUE}\"" "$INFO_PLIST"
  if [[ -S "$CMUXD_SOCKET" ]]; then
    for PID in $(lsof -t "$CMUXD_SOCKET" 2>/dev/null); do
      kill "$PID" 2>/dev/null || true
    done
    rm -f "$CMUXD_SOCKET"
  fi
  if [[ -S "$CMUX_SOCKET_PATH_VALUE" ]]; then
    rm -f "$CMUX_SOCKET_PATH_VALUE"
  fi
  # Ad-hoc signing entitlements for the staging app: ONLY get-task-allow, which an
  # ad-hoc binary may carry without a provisioning profile. We deliberately do NOT
  # reuse the built app's entitlements: xcodebuild bakes in restricted keys
  # (keychain-access-groups, application-identifier, team-identifier) that REQUIRE a
  # provisioning profile. The auto-generated "Mac Team Provisioning Profile" expires
  # 7 days after each build, after which AMFI refuses to launch the app ("can't be
  # opened"; amfid Code=-413 "No matching profile found"). Signing ad-hoc with no
  # restricted entitlements removes the profile dependency entirely, so the staging
  # build keeps launching indefinitely. Trade-off: the app uses the ad-hoc default
  # keychain access group, so its auth tokens re-save once after switching modes.
  STAGING_APP_ENT_TMP="$(mktemp -t cmux-staging-ent).plist"
  cat > "$STAGING_APP_ENT_TMP" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.get-task-allow</key>
    <true/>
</dict>
</plist>
PLIST
  # Drop the soon-to-expire auto-generated provisioning profile; ad-hoc needs none.
  rm -f "$STAGING_APP_PATH/Contents/embedded.provisionprofile"
fi
APP_PATH="$STAGING_APP_PATH"

# Ensure any running instance is fully terminated, regardless of DerivedData path.
/usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
sleep 0.3
# Kill any running staging instance; allow side-by-side with the main and dev apps.
pkill -f "${APP_NAME}.app/Contents/MacOS/${BASE_APP_NAME}" || true
sleep 0.3
CMUXD_SRC="$PWD/cmuxd/zig-out/bin/cmuxd"
if [[ -d "$PWD/cmuxd" ]]; then
  (cd "$PWD/cmuxd" && zig build -Doptimize=ReleaseFast)
fi
if [[ -x "$CMUXD_SRC" ]]; then
  BIN_DIR="$APP_PATH/Contents/Resources/bin"
  mkdir -p "$BIN_DIR"
  cp "$CMUXD_SRC" "$BIN_DIR/cmuxd"
  chmod +x "$BIN_DIR/cmuxd"
fi

# Inside-out re-sign now that Resources/bin is fully populated (incl. cmuxd).
# The staging app is ALWAYS signed ad-hoc. A dev-cert (Apple Development)
# signature embeds a "Mac Team Provisioning Profile" that expires 7 days after
# every build; once it lapses, AMFI refuses to launch the app ("can't be opened";
# amfid Code=-413 "No matching profile found") — the weekly-recurring breakage
# this path used to cause. Ad-hoc signing carries no profile and never expires.
# Nested CLI helpers are signed ad-hoc with NO entitlements (the app-level
# get-task-allow is harmless but pointless on a helper); the app bundle is signed
# ad-hoc with the minimal get-task-allow entitlements written above.

sign_staging_helpers() {
  local helper
  for helper in "$APP_PATH/Contents/Resources/bin"/*; do
    [[ -f "$helper" && -x "$helper" ]] || continue
    /usr/bin/file -b "$helper" | grep -q "Mach-O" || continue
    /usr/bin/codesign --force --options runtime --timestamp=none --sign - "$helper" >/dev/null 2>&1 || true
  done
}

# Ad-hoc sign nested helpers + the app bundle, then VERIFY the seal. Returns 0
# only if the resulting signature validates, so a swallowed codesign failure can
# never ship an unlaunchable, AMFI-killed bundle. Diagnostic output from a failed
# sign is surfaced (not redirected to /dev/null) so a future breakage is
# debuggable from the reloads.sh log.
sign_and_verify_staging_app() {
  local sign_err
  sign_staging_helpers
  if [[ -s "${STAGING_APP_ENT_TMP:-}" ]]; then
    sign_err="$(/usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der --entitlements "$STAGING_APP_ENT_TMP" "$APP_PATH" 2>&1)" \
      || { echo "$sign_err" >&2; return 1; }
  else
    sign_err="$(/usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der "$APP_PATH" 2>&1)" \
      || { echo "$sign_err" >&2; return 1; }
  fi
  /usr/bin/codesign --verify --verbose=2 "$APP_PATH" >/dev/null 2>&1
}

CMUX_SIGNED_OK=0
if sign_and_verify_staging_app; then
  echo "==> Signed staging app ad-hoc (no provisioning profile; never expires)"
  CMUX_SIGNED_OK=1
fi
rm -f "${STAGING_APP_ENT_TMP:-}"
if [[ "$CMUX_SIGNED_OK" -eq 0 ]]; then
  echo "error: failed to produce a valid code signature for $APP_PATH" >&2
  echo "       The app would be SIGKILLed by AMFI on launch (\"can't be opened\")." >&2
  echo "       codesign --verify output:" >&2
  /usr/bin/codesign --verify --verbose=2 "$APP_PATH" >&2 || true
  exit 1
fi

# Install the freshly-signed staging app to a stable, canonical location in
# /Applications and launch THAT, so Spotlight, the Dock, and `open -b <bundle id>`
# always resolve to this build. Otherwise reloads.sh builds, signs, and launches
# entirely inside DerivedData (build scratch that Xcode "Clean" wipes), while any
# hand-dragged /Applications copy goes stale; Spotlight prefers /Applications, so
# it launches the stale bundle, which AMFI SIGKILLs ("can't be opened"). ditto
# preserves the code signature produced above, so the installed copy stays valid
# without re-signing. If install fails for any reason, fall back to launching the
# DerivedData build (previous behavior) rather than failing the reload.
INSTALLED_APP_PATH="/Applications/${APP_NAME}.app"
if rm -rf "$INSTALLED_APP_PATH" 2>/dev/null && ditto "$APP_PATH" "$INSTALLED_APP_PATH" 2>/dev/null \
  && /usr/bin/codesign --verify --verbose=2 "$INSTALLED_APP_PATH" >/dev/null 2>&1; then
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
  [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$INSTALLED_APP_PATH" >/dev/null 2>&1 || true
  APP_PATH="$INSTALLED_APP_PATH"
  echo "==> Installed staging app to $INSTALLED_APP_PATH"
else
  rm -rf "$INSTALLED_APP_PATH" 2>/dev/null || true
  echo "==> warning: could not install a valid copy to $INSTALLED_APP_PATH; launching DerivedData build instead" >&2
fi

# Avoid inheriting cmux/ghostty environment variables from the terminal that
# runs this script (often inside another cmux instance), which can cause
# socket and resource-path conflicts.
OPEN_CLEAN_ENV=(
  env
  -u CMUX_SOCKET_PATH
  -u CMUX_TAB_ID
  -u CMUX_PANEL_ID
  -u CMUXD_UNIX_PATH
  -u CMUX_TAG
  -u CMUX_BUNDLE_ID
  -u CMUX_SHELL_INTEGRATION
  -u GHOSTTY_BIN_DIR
  -u GHOSTTY_RESOURCES_DIR
  -u GHOSTTY_SHELL_FEATURES
  # Dev shells (including CI/Codex) often force-disable paging by exporting these.
  # Don't leak that into cmux, otherwise `git diff` won't page even with PAGER=less.
  -u GIT_PAGER
  -u GH_PAGER
  -u TERMINFO
  -u XDG_DATA_DIRS
)

# Always inject staging socket paths via env to ensure they take effect
# (LSEnvironment requires app restart to pick up plist changes).
"${OPEN_CLEAN_ENV[@]}" CMUX_BUNDLE_ID="$BUNDLE_ID" CMUX_SOCKET_PATH="$CMUX_SOCKET_PATH_VALUE" CMUXD_UNIX_PATH="$CMUXD_SOCKET" open -g "$APP_PATH"

# Safety: ensure only one instance is running.
sleep 0.2
PIDS=($(pgrep -f "${APP_PATH}/Contents/MacOS/" || true))
if [[ "${#PIDS[@]}" -gt 1 ]]; then
  NEWEST_PID=""
  NEWEST_AGE=999999
  for PID in "${PIDS[@]}"; do
    AGE="$(ps -o etimes= -p "$PID" | tr -d ' ')"
    if [[ -n "$AGE" && "$AGE" -lt "$NEWEST_AGE" ]]; then
      NEWEST_AGE="$AGE"
      NEWEST_PID="$PID"
    fi
  done
  for PID in "${PIDS[@]}"; do
    if [[ "$PID" != "$NEWEST_PID" ]]; then
      kill "$PID" 2>/dev/null || true
    fi
  done
fi
