#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: smoke-installable-artifact.sh [--channel stable|nightly|debug] <app-or-dmg-path>

Runs artifact-level checks against the built product a user downloads or launches.
For a DMG, the script mounts it read-only, discovers the contained .app, verifies
the app, then detaches the image.

Environment:
  CMUX_INSTALLABLE_REQUIRE_NOTARIZATION=0  Skip stapler validation.
  CMUX_INSTALLABLE_REQUIRE_SPCTL=0         Skip Gatekeeper assessment.
  CMUX_INSTALLABLE_RUN_CLI=0               Skip bundled CLI help/version smoke.
EOF
}

CHANNEL="stable"
ARTIFACT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      CHANNEL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "error: unknown option $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$ARTIFACT_PATH" ]]; then
        echo "error: unexpected extra argument $1" >&2
        usage >&2
        exit 2
      fi
      ARTIFACT_PATH="$1"
      shift
      ;;
  esac
done

if [[ -z "$ARTIFACT_PATH" ]]; then
  usage >&2
  exit 2
fi

case "$CHANNEL" in
  stable)
    EXPECTED_BUNDLE_ID="com.cmuxterm.app"
    EXPECTED_APP_NAME="cmux"
    ;;
  nightly)
    EXPECTED_BUNDLE_ID="com.cmuxterm.app.nightly"
    EXPECTED_APP_NAME="cmux NIGHTLY"
    ;;
  debug)
    EXPECTED_BUNDLE_ID_PREFIX="com.cmuxterm.app.debug."
    EXPECTED_APP_NAME_PREFIX="cmux DEV "
    ;;
  *)
    echo "error: unknown channel '$CHANNEL'" >&2
    usage >&2
    exit 2
    ;;
esac

REQUIRE_NOTARIZATION="${CMUX_INSTALLABLE_REQUIRE_NOTARIZATION:-1}"
REQUIRE_SPCTL="${CMUX_INSTALLABLE_REQUIRE_SPCTL:-1}"
RUN_CLI="${CMUX_INSTALLABLE_RUN_CLI:-1}"
MOUNT_DIR=""
DEVICE=""

cleanup() {
  if [[ -n "$DEVICE" ]]; then
    hdiutil detach "$DEVICE" -quiet >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist"
}

expect_nonempty_plist_value() {
  local plist="$1"
  local key="$2"
  local value
  value="$(plist_value "$plist" "$key" 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    echo "error: $key missing or empty in $plist" >&2
    exit 1
  fi
  printf '%s' "$value"
}

discover_app_in_dmg() {
  local dmg_path="$1"
  local attach_output
  attach_output="$(hdiutil attach -readonly -nobrowse -plist "$dmg_path")"
  DEVICE="$(python3 -c 'import plistlib,sys; p=plistlib.load(sys.stdin.buffer); print(next(e["dev-entry"] for e in p["system-entities"] if "mount-point" in e))' <<<"$attach_output")"
  MOUNT_DIR="$(python3 -c 'import plistlib,sys; p=plistlib.load(sys.stdin.buffer); print(next(e["mount-point"] for e in p["system-entities"] if "mount-point" in e))' <<<"$attach_output")"
  python3 - "$MOUNT_DIR" <<'PY'
import pathlib
import sys

mount = pathlib.Path(sys.argv[1])
apps = sorted(path for path in mount.iterdir() if path.suffix == ".app" and path.is_dir())
if len(apps) != 1:
    raise SystemExit(f"expected exactly one .app in {mount}, found {len(apps)}")
print(apps[0])
PY
}

if [[ ! -e "$ARTIFACT_PATH" ]]; then
  echo "error: artifact not found at $ARTIFACT_PATH" >&2
  exit 1
fi

APP_PATH="$ARTIFACT_PATH"
if [[ "$ARTIFACT_PATH" == *.dmg ]]; then
  echo "==> validating DMG container: $ARTIFACT_PATH"
  /usr/bin/codesign --verify --verbose=2 "$ARTIFACT_PATH"
  if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
    xcrun stapler validate "$ARTIFACT_PATH"
  fi
  APP_PATH="$(discover_app_in_dmg "$ARTIFACT_PATH")"
fi

if [[ ! -d "$APP_PATH/Contents" ]]; then
  echo "error: app bundle not found at $APP_PATH" >&2
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "error: Info.plist missing at $INFO_PLIST" >&2
  exit 1
fi

echo "==> validating app bundle: $APP_PATH"
BUNDLE_ID="$(expect_nonempty_plist_value "$INFO_PLIST" CFBundleIdentifier)"
APP_NAME="$(expect_nonempty_plist_value "$INFO_PLIST" CFBundleName)"
DISPLAY_NAME="$(expect_nonempty_plist_value "$INFO_PLIST" CFBundleDisplayName)"
EXECUTABLE_NAME="$(expect_nonempty_plist_value "$INFO_PLIST" CFBundleExecutable)"
MARKETING_VERSION="$(expect_nonempty_plist_value "$INFO_PLIST" CFBundleShortVersionString)"
BUILD_VERSION="$(expect_nonempty_plist_value "$INFO_PLIST" CFBundleVersion)"

if [[ "$CHANNEL" == "debug" ]]; then
  if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID_PREFIX"* ]]; then
    echo "error: debug bundle id expected prefix '$EXPECTED_BUNDLE_ID_PREFIX', found '$BUNDLE_ID'" >&2
    exit 1
  fi
  if [[ "$DISPLAY_NAME" != "$EXPECTED_APP_NAME_PREFIX"* ]]; then
    echo "error: debug display name expected prefix '$EXPECTED_APP_NAME_PREFIX', found '$DISPLAY_NAME'" >&2
    exit 1
  fi
else
  if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
    echo "error: bundle id expected '$EXPECTED_BUNDLE_ID', found '$BUNDLE_ID'" >&2
    exit 1
  fi
  if [[ "$APP_NAME" != "$EXPECTED_APP_NAME" || "$DISPLAY_NAME" != "$EXPECTED_APP_NAME" ]]; then
    echo "error: app name/display name expected '$EXPECTED_APP_NAME', found '$APP_NAME'/'$DISPLAY_NAME'" >&2
    exit 1
  fi
fi

EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "error: app executable missing or not executable at $EXECUTABLE_PATH" >&2
  exit 1
fi

CLI_PATH="$APP_PATH/Contents/Resources/bin/cmux"
if [[ ! -x "$CLI_PATH" ]]; then
  echo "error: bundled CLI missing or not executable at $CLI_PATH" >&2
  exit 1
fi

if [[ "$RUN_CLI" == "1" ]]; then
  "$CLI_PATH" --version >/dev/null
  "$CLI_PATH" --help >/dev/null
fi

if [[ "$CHANNEL" != "debug" ]]; then
  PROFILE_PATH="$APP_PATH/Contents/embedded.provisionprofile"
  if [[ ! -s "$PROFILE_PATH" ]]; then
    echo "error: release app is missing embedded provisioning profile at $PROFILE_PATH" >&2
    exit 1
  fi
  if command -v security >/dev/null; then
    TMP_PROFILE_PLIST="$(mktemp -t cmux-profile.XXXXXX.plist)"
    security cms -D -i "$PROFILE_PATH" > "$TMP_PROFILE_PLIST"
    APP_IDENTIFIER="$(plist_value "$TMP_PROFILE_PLIST" "Entitlements:com.apple.application-identifier")"
    rm -f "$TMP_PROFILE_PLIST"
    EXPECTED_APP_IDENTIFIER="7WLXT3NR37.$BUNDLE_ID"
    if [[ "$APP_IDENTIFIER" != "$EXPECTED_APP_IDENTIFIER" ]]; then
      echo "error: provisioning profile app id expected '$EXPECTED_APP_IDENTIFIER', found '$APP_IDENTIFIER'" >&2
      exit 1
    fi
  fi
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
if [[ "$REQUIRE_SPCTL" == "1" ]]; then
  spctl -a -vv --type execute "$APP_PATH"
fi
if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
  xcrun stapler validate "$APP_PATH"
fi

echo "installable artifact smoke OK: bundle=$BUNDLE_ID version=$MARKETING_VERSION build=$BUILD_VERSION"
