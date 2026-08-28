#!/usr/bin/env bash
set -euo pipefail

# Build cmux in Release configuration and install the resulting .app into
# ~/Applications. Does not kill or launch anything — quit the old instance
# yourself before running if you want the new binary to take effect.
#
# Signing: defaults to Xcode development signing with the local cmux team.
# Set CMUX_LOCAL_INSTALL_SIGNING_MODE=local to use Xcode ad-hoc signing instead.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA="${CMUX_LOCAL_INSTALL_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/cmux-local-install}"
DEST_DIR="${CMUX_LOCAL_INSTALL_DEST_DIR:-$HOME/Applications}"
DEST_APP="$DEST_DIR/cmux.app"
DEST_TMP="$DEST_DIR/.cmux.app.installing.$$"
PROJECT_PATH="cmux.xcodeproj"
PROJECT_TMP=""
APP_RELEASE_CONFIG_ID="A5001083"
DEFAULT_DEVELOPMENT_TEAM="WNF89D7V44"
SIGNING_MODE="${CMUX_LOCAL_INSTALL_SIGNING_MODE:-}"
if [[ -z "$SIGNING_MODE" ]]; then
  SIGNING_MODE=development
fi

cleanup() {
  if [[ -n "$DEST_TMP" ]]; then
    rm -rf "$DEST_TMP"
  fi
  if [[ -n "$PROJECT_TMP" ]]; then
    rm -rf "$PROJECT_TMP"
  fi
}
trap cleanup EXIT

cd "$REPO_ROOT"

set_release_build_setting() {
  local key="$1"
  local value="$2"

  SETTING_KEY="$key" \
    SETTING_VALUE="$value" \
    APP_RELEASE_CONFIG_ID="$APP_RELEASE_CONFIG_ID" \
    /usr/bin/perl -0pi -e '
      my $id = $ENV{"APP_RELEASE_CONFIG_ID"};
      my $key = $ENV{"SETTING_KEY"};
      my $value = $ENV{"SETTING_VALUE"};
      $value =~ s/\\/\\\\/g;
      $value =~ s/"/\\"/g;
      my $quoted = "\"" . $value . "\"";

      if (s/($id \/\* Release \*\/ = \{.*?buildSettings = \{.*?\n\s*\Q$key\E = )[^;]+(;)/$1$quoted$2/s) {
        next;
      }
      s/($id \/\* Release \*\/ = \{.*?buildSettings = \{\n)/$1\t\t\t\t$key = $quoted;\n/s
        or die "could not update $key in Release app build settings\n";
    ' "$PROJECT_TMP/project.pbxproj"
}

XCODE_ARGS=()

case "$SIGNING_MODE" in
  local|development|project) ;;
  *)
    echo "Unknown CMUX_LOCAL_INSTALL_SIGNING_MODE: $SIGNING_MODE" >&2
    echo "Expected one of: local, development, project" >&2
    exit 1
    ;;
esac

if [[ "$SIGNING_MODE" != "project" ]]; then
  PROJECT_TMP="$REPO_ROOT/.cmux-local-install.$$.xcodeproj"
  rm -rf "$PROJECT_TMP"
  ditto "$PROJECT_PATH" "$PROJECT_TMP"
  perl -0pi -e 's/container:cmux\.xcodeproj/container:'"$(basename "$PROJECT_TMP")"'/g' \
    "$PROJECT_TMP/xcshareddata/xcschemes/cmux.xcscheme"

  if [[ "$SIGNING_MODE" == "local" ]]; then
    set_release_build_setting CODE_SIGN_STYLE Manual
    set_release_build_setting CODE_SIGN_IDENTITY "-"
    set_release_build_setting CODE_SIGN_ENTITLEMENTS ""
    set_release_build_setting DEVELOPMENT_TEAM ""
    set_release_build_setting PROVISIONING_PROFILE_SPECIFIER ""
    set_release_build_setting CODE_SIGN_INJECT_BASE_ENTITLEMENTS NO
  else
    DEVELOPMENT_TEAM_VALUE="${CMUX_LOCAL_INSTALL_DEVELOPMENT_TEAM:-${DEVELOPMENT_TEAM:-$DEFAULT_DEVELOPMENT_TEAM}}"
    if [[ -z "$DEVELOPMENT_TEAM_VALUE" ]]; then
      DEVELOPMENT_TEAM_VALUE="$(security find-identity -v -p codesigning \
        | sed -nE 's/.*"Apple Development: .* \(([A-Z0-9]+)\)".*/\1/p' \
        | head -n 1)"
    fi
    if [[ -z "$DEVELOPMENT_TEAM_VALUE" ]]; then
      echo "No Apple Development signing team found." >&2
      echo "Set CMUX_LOCAL_INSTALL_DEVELOPMENT_TEAM or use CMUX_LOCAL_INSTALL_SIGNING_MODE=local." >&2
      exit 1
    fi

    set_release_build_setting DEVELOPMENT_TEAM "$DEVELOPMENT_TEAM_VALUE"
    CODE_SIGN_IDENTITY_VALUE="${CMUX_LOCAL_INSTALL_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
    if [[ -n "$CODE_SIGN_IDENTITY_VALUE" ]]; then
      set_release_build_setting CODE_SIGN_IDENTITY "$CODE_SIGN_IDENTITY_VALUE"
    fi

    if [[ "${CMUX_LOCAL_INSTALL_KEEP_ENTITLEMENTS:-0}" != "1" ]]; then
      set_release_build_setting CODE_SIGN_ENTITLEMENTS ""
      set_release_build_setting CODE_SIGN_INJECT_BASE_ENTITLEMENTS NO
    fi

    PROVISIONING_PROFILE_SPECIFIER_VALUE="${CMUX_LOCAL_INSTALL_PROVISIONING_PROFILE_SPECIFIER:-${PROVISIONING_PROFILE_SPECIFIER:-}}"
    if [[ -n "$PROVISIONING_PROFILE_SPECIFIER_VALUE" ]]; then
      set_release_build_setting PROVISIONING_PROFILE_SPECIFIER "$PROVISIONING_PROFILE_SPECIFIER_VALUE"
    fi
  fi

  BUNDLE_IDENTIFIER_VALUE="${CMUX_LOCAL_INSTALL_BUNDLE_IDENTIFIER:-${PRODUCT_BUNDLE_IDENTIFIER:-}}"
  if [[ "$SIGNING_MODE" == "development" && -z "$BUNDLE_IDENTIFIER_VALUE" ]]; then
    USER_SUFFIX="$(id -un | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9.-')"
    if [[ -z "$USER_SUFFIX" ]]; then
      USER_SUFFIX=local
    fi
    BUNDLE_IDENTIFIER_VALUE="com.cmuxterm.app.local.$USER_SUFFIX"
  fi
  if [[ -n "$BUNDLE_IDENTIFIER_VALUE" ]]; then
    set_release_build_setting PRODUCT_BUNDLE_IDENTIFIER "$BUNDLE_IDENTIFIER_VALUE"
  fi

  PROJECT_PATH="$(basename "$PROJECT_TMP")"
fi

ALLOW_PROVISIONING_UPDATES="${CMUX_LOCAL_INSTALL_ALLOW_PROVISIONING_UPDATES:-}"
if [[ -z "$ALLOW_PROVISIONING_UPDATES" ]]; then
  if [[ "$SIGNING_MODE" == "development" ]]; then
    ALLOW_PROVISIONING_UPDATES=1
  else
    ALLOW_PROVISIONING_UPDATES=0
  fi
fi

if [[ "$ALLOW_PROVISIONING_UPDATES" == "1" ]]; then
  XCODE_ARGS+=(-allowProvisioningUpdates)
fi

# Strip detritus from any prior build product. Incremental builds preserve
# files xcodebuild didn't create (e.g. a custom-icon "Icon\r" with FinderInfo
# and a resource fork stamped on the bundle by Finder), and the internal
# codesign step then fails with "resource fork, Finder information, or similar
# detritus not allowed".
STALE_APP="$DERIVED_DATA/Build/Products/Release/cmux.app"
if [[ -d "$STALE_APP" ]]; then
  /usr/bin/xattr -cr "$STALE_APP"
  /usr/bin/find "$STALE_APP" -maxdepth 1 \( -name $'Icon\r' -o -name 'Icon' \) -delete
fi

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme cmux \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  "${XCODE_ARGS[@]}" \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Release/cmux.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "cmux.app not found at expected build path:" >&2
  echo "  $APP_PATH" >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

mkdir -p "$DEST_DIR"
rm -rf "$DEST_TMP"
ditto "$APP_PATH" "$DEST_TMP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$DEST_TMP"

rm -rf "$DEST_APP"
mv "$DEST_TMP" "$DEST_APP"
DEST_TMP=""
cleanup
trap - EXIT

echo "Installed:"
echo "  from: ${APP_PATH}"
echo "  to:   ${DEST_APP}"
/usr/bin/codesign --display --verbose=2 "$DEST_APP" 2>&1 | grep -E "^(Identifier|Authority|TeamIdentifier|Signature)" || true
