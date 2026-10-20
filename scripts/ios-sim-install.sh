#!/usr/bin/env bash
# Install a PREBUILT cmux iOS simulator .app into the tag's isolated simulator
# and launch it signed in + auto-paired. Used by cloud iOS reloads
# (cmuxterm-hq scripts/reload-cloud-ios.sh), which download the simulator app
# instead of building it locally; local builds go through ios/scripts/reload.sh,
# which shares the same isolated-simulator resolution.
#
#   scripts/ios-sim-install.sh --tag <tag> --app <Debug-iphonesimulator/cmux.app>
#                              [--auth-profile agent|personal]
#                              [--expected-account <email>]
#                              [--credentials-file <path>]
#                              [--no-attach] [--no-sign-in] [--no-setup] [--no-launch]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/mobile-attach.sh
source "$SCRIPT_DIR/lib/mobile-attach.sh"
# shellcheck source=lib/ios-sim-isolate.sh
source "$SCRIPT_DIR/lib/ios-sim-isolate.sh"

TAG=""
APP=""
NO_ATTACH=0
NO_SIGN_IN=0
NO_SETUP=0
LAUNCH=1
AUTH_PROFILE="agent"
EXPECTED_ACCOUNT=""
AUTH_CREDENTIALS_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --app) APP="${2:-}"; shift 2 ;;
    --auth-profile) AUTH_PROFILE="${2:-}"; shift 2 ;;
    --expected-account) EXPECTED_ACCOUNT="${2:-}"; shift 2 ;;
    --credentials-file) AUTH_CREDENTIALS_FILE="${2:-}"; shift 2 ;;
    --no-attach) NO_ATTACH=1; shift ;;
    --no-sign-in) NO_SIGN_IN=1; shift ;;
    --no-setup) NO_SETUP=1; shift ;;
    --no-launch) LAUNCH=0; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$TAG" ]] || { echo "error: --tag is required" >&2; exit 2; }
[[ -n "$APP" && -d "$APP" ]] || { echo "error: --app must point at a simulator .app" >&2; exit 2; }

SLUG="$(cmux_attach__slug "$TAG")"
BUNDLE_ID="dev.cmux.ios.$SLUG"
# Fail closed: an unreadable CFBundleIdentifier must not skip validation and
# install an arbitrary app under this tag's identity.
APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist" 2>/dev/null || true)"
if [[ -z "$APP_BUNDLE_ID" ]]; then
  echo "error: could not read CFBundleIdentifier from $APP/Info.plist" >&2
  exit 1
fi
if [[ "$APP_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "error: app bundle id $APP_BUNDLE_ID does not match tag '$TAG' ($BUNDLE_ID)" >&2
  exit 1
fi

SIM_UDID="$(cmux_ios_isolated_sim_udid "$SLUG")"
[[ -n "$SIM_UDID" ]] || { echo "error: could not resolve isolated simulator" >&2; exit 1; }
SIM_NAME="$(cmux_ios_isolated_sim_name "$SLUG")"

echo "==> installing $BUNDLE_ID into isolated simulator $SIM_NAME ($SIM_UDID)"
xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true
xcrun simctl install "$SIM_UDID" "$APP"

if [[ "$LAUNCH" -eq 1 ]]; then
  xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ "$NO_SETUP" -eq 1 || "$NO_SIGN_IN" -eq 1 ]]; then
    xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" >/dev/null
  else
    launch_args=(--tag "$TAG" --simulator-id "$SIM_UDID" --detach)
    launch_args+=(--auth-profile "$AUTH_PROFILE")
    [[ -n "$EXPECTED_ACCOUNT" ]] && launch_args+=(--expected-account "$EXPECTED_ACCOUNT")
    [[ -n "$AUTH_CREDENTIALS_FILE" ]] && launch_args+=(--credentials-file "$AUTH_CREDENTIALS_FILE")
    [[ "$NO_ATTACH" -eq 0 ]] && launch_args+=(--ensure-mac)
    if ! "$SCRIPT_DIR/mobile-dev-launch.sh" "${launch_args[@]}"; then
      echo "error: installed $BUNDLE_ID on $SIM_NAME, but signed setup failed; refusing an unpaired fallback launch" >&2
      exit 1
    fi
  fi
fi

cat <<EOF
==> iOS simulator install succeeded
Bundle id:
  $BUNDLE_ID
Simulator:
  $SIM_NAME ($SIM_UDID)
EOF
