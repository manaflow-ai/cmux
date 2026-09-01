#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ios/scripts/reload.sh --tag <tag> [--simulator <name>] [--simulator-id <id>] [--no-launch]
       ios/scripts/reload.sh --tag <tag> --device [--device-id <id>] [--device-name <name>] [--team <team-id>] [--no-launch]
       ios/scripts/reload.sh --tag <tag> --device-only [--device-id <id>] [--device-name <name>] [--team <team-id>] [--no-launch]
       ios/scripts/reload.sh --tag <tag> --simulator-only

Build, install, and launch the cmux iOS app with an isolated tag.

Verification default is simulator + iPhone: when a default iPhone is configured
(CMUX_IPHONE_DEVICE_ID or ~/.config/cmux/iphone-device-id), the device leg is
enabled automatically; --simulator-only opts out explicitly. Without a
configured default, this reloads only the simulator unless --device is given.
If the iPhone is unreachable, the signed build is parked in the offline install
queue (scripts/iphone-install-queue.sh) and auto-installs when the phone
reconnects. Unless a simulator is named explicitly, the simulator leg uses the
tag's own isolated device ("cmux-dev-<slug>"), created on demand.

When a trusted phone leg is enabled, the simulator app is installed but not
launched. The simulator's agent auto-pair would replace the phone's personal
Mac pairing; use --simulator-only for a connected simulator run.

Every device build requires the same-tag Mac dev build (the iOS app is unusable
without its Mac); when it is missing, the Mac tag is built first, and the reload
refuses to ship a phone-only build if that fails.

After install, the app is launched signed in (dogfood creds) and auto-paired to
the tagged Mac app. Opt out granularly:
  --no-sign-in   plain launch, no auto sign-in (implies no auto-pair)
  --no-attach    sign in, but do not auto-pair to the Mac
  --no-setup     plain install + launch (today's behavior)

  --prod-auth    sign this DEV build in against PRODUCTION auth (bakes
                 CMUXAuthEnvironment=production into Info.plist; the presence
                 worker and API base follow the channel in-app). Implies
                 --no-sign-in (dogfood auto-login creds are dev-channel);
                 sign in in-app with your real account and use the IN-APP
                 scanner.

Device signing uses the local Xcode account, or App Store Connect API
credentials from ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_PATH, or
ios/Config/AppStoreConnect.local.plist. Set IOS_DEVELOPMENT_TEAM or pass
--team when the project cannot infer a team.
EOF
}

# Tag -> slug. Delegates to the shared helper (scripts/lib/mobile-attach.sh,
# sourced below) so the bundle id this builds/installs always matches the one
# scripts/mobile-dev-launch.sh later signs in / pairs against, including for edge
# tags that sanitize to empty. Do not reintroduce a local sanitizer here.
sanitize_tag() { cmux_attach__slug "$1"; }

require_option_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    echo "Missing value for $option" >&2
    usage >&2
    exit 2
  fi
}

TAG=""
SIMULATOR_NAME="${IOS_SIMULATOR_NAME:-iPhone 17}"
SIMULATOR_ID="${IOS_SIMULATOR_ID:-}"
# Track whether the caller picked a simulator explicitly (flag or env); when
# not, the reload uses the tag's own isolated simulator instead of a shared one.
SIMULATOR_EXPLICIT=0
[[ -n "${IOS_SIMULATOR_NAME:-}" || -n "${IOS_SIMULATOR_ID:-}" ]] && SIMULATOR_EXPLICIT=1
DEVICE_ID="${IOS_DEVICE_ID:-}"
DEVICE_NAME="${IOS_DEVICE_NAME:-}"
DEVELOPMENT_TEAM="${IOS_DEVELOPMENT_TEAM:-}"
LAUNCH=1
RELOAD_SIMULATOR=1
RELOAD_DEVICE=0
SIMULATOR_ONLY=0
ALLOW_PROVISIONING_UPDATES=1
ALLOW_DEVICE_REGISTRATION=0
# Auto-setup: after install + launch, sign in (inject dogfood creds) and auto-pair
# to the tagged Mac app. Default ON; opt out granularly.
NO_SIGN_IN=0
NO_ATTACH=0
NO_SETUP=0
# A combined phone + simulator reload uses different auth profiles for each
# surface. Launching the simulator first would sign the shared tagged Mac into
# the agent account and invalidate the physical phone's personal pairing. Keep
# the simulator installed but unlaunched during a trusted phone reload; use
# --simulator-only for a connected simulator run.
SIMULATOR_LAUNCH=1
# Disable AArch64 GlobalISel codegen for this build. Xcode 26's Swift frontend
# can miscompile under -O/wholemodule on the GlobalISel path, surfacing as bogus
# "undefined symbol: _abort/_free/..." link failures. Mirrors scripts/reload.sh.
# Also honored via CMUX_SWIFT_FRONTEND_WORKAROUND=1.
SWIFT_FRONTEND_WORKAROUND="${CMUX_SWIFT_FRONTEND_WORKAROUND:-0}"
# --prod-auth: bake CMUXAuthEnvironment=production so the dev build signs in
# against the production Stack project.
PROD_AUTH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      require_option_value "$1" "${2:-}"
      TAG="${2:-}"
      shift 2
      ;;
    --simulator)
      require_option_value "$1" "${2:-}"
      SIMULATOR_NAME="${2:-}"
      SIMULATOR_EXPLICIT=1
      shift 2
      ;;
    --simulator-id)
      require_option_value "$1" "${2:-}"
      SIMULATOR_ID="${2:-}"
      SIMULATOR_EXPLICIT=1
      shift 2
      ;;
    --simulator-only|--sim-only)
      SIMULATOR_ONLY=1
      shift
      ;;
    --device)
      RELOAD_DEVICE=1
      shift
      ;;
    --device-only)
      RELOAD_DEVICE=1
      RELOAD_SIMULATOR=0
      shift
      ;;
    --device-id)
      require_option_value "$1" "${2:-}"
      DEVICE_ID="${2:-}"
      RELOAD_DEVICE=1
      shift 2
      ;;
    --device-name)
      require_option_value "$1" "${2:-}"
      DEVICE_NAME="${2:-}"
      RELOAD_DEVICE=1
      shift 2
      ;;
    --team)
      require_option_value "$1" "${2:-}"
      DEVELOPMENT_TEAM="${2:-}"
      shift 2
      ;;
    --no-provisioning-updates)
      ALLOW_PROVISIONING_UPDATES=0
      shift
      ;;
    --allow-device-registration)
      ALLOW_DEVICE_REGISTRATION=1
      shift
      ;;
    --no-launch)
      LAUNCH=0
      shift
      ;;
    --no-sign-in)
      NO_SIGN_IN=1
      shift
      ;;
    --no-attach)
      NO_ATTACH=1
      shift
      ;;
    --no-setup)
      NO_SETUP=1
      shift
      ;;
    --swift-frontend-workaround|--swift-workaround)
      SWIFT_FRONTEND_WORKAROUND=1
      shift
      ;;
    --prod-auth)
      PROD_AUTH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unexpected argument $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TAG" ]]; then
  echo "error: --tag is required" >&2
  usage >&2
  exit 1
fi

if [[ "$SIMULATOR_ONLY" -eq 1 ]]; then
  # At this point RELOAD_DEVICE is 1 only via explicit --device* flags (the
  # configured-default device leg is applied later), so this is a real conflict.
  if [[ "$RELOAD_SIMULATOR" -eq 0 || "$RELOAD_DEVICE" -eq 1 ]]; then
    echo "error: --simulator-only conflicts with --device/--device-only/--device-id/--device-name" >&2
    usage >&2
    exit 1
  fi
fi

if [[ "$RELOAD_SIMULATOR" -eq 0 && "$RELOAD_DEVICE" -eq 0 ]]; then
  echo "error: nothing to reload" >&2
  usage >&2
  exit 1
fi

if [[ "$ALLOW_DEVICE_REGISTRATION" -eq 1 && "$ALLOW_PROVISIONING_UPDATES" -eq 0 ]]; then
  echo "error: --allow-device-registration requires provisioning updates" >&2
  usage >&2
  exit 1
fi

# Extra xcodebuild settings to disable AArch64 GlobalISel when the workaround is
# requested. Expanded into the build invocations via the empty-array-safe idiom
# ${arr[@]+"${arr[@]}"} so it is a no-op (and set -u safe) when disabled.
SWIFT_WORKAROUND_ARGS=()
if [[ "$SWIFT_FRONTEND_WORKAROUND" == "1" ]]; then
  echo "==> Swift frontend workaround enabled (AArch64 GlobalISel disabled)"
  SWIFT_WORKAROUND_ARGS=(
    SWIFT_ENABLE_BATCH_MODE=NO
    DEBUG_INFORMATION_FORMAT=
    GCC_GENERATE_DEBUGGING_SYMBOLS=NO
    'OTHER_SWIFT_FLAGS=$(inherited) -Xllvm -aarch64-enable-global-isel-at-O=-1'
  )
fi

XCODEBUILD_PARALLEL_ARGS=()
if [[ -n "${CMUX_XCODEBUILD_JOBS:-}" ]]; then
  if [[ ! "$CMUX_XCODEBUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: CMUX_XCODEBUILD_JOBS must be a positive integer" >&2
    exit 1
  fi
  XCODEBUILD_PARALLEL_ARGS=(-jobs "$CMUX_XCODEBUILD_JOBS")
fi

# --prod-auth: point the build at the production auth channel for production
# account, registry, and API testing (https://github.com/manaflow-ai/cmux/issues/7145).
# The value lands in the CMUXAuthEnvironment Info.plist key (a tapped device
# build sees no shell env), read by MobileAuthComposition. Presence needs no
# URL here: PresenceClient.resolvedServiceBaseURL follows the resolved auth
# channel, so the worker URLs live only in Swift and cannot drift; an explicit
# CMUX_PRESENCE_BASE_URL still wins as before.
CMUX_IOS_AUTH_ENV_VALUE=""
if [[ "$PROD_AUTH" -eq 1 ]]; then
  CMUX_IOS_AUTH_ENV_VALUE="production"
  # The dogfood auto-login creds are dev-Stack-project accounts; against
  # production auth they cannot sign in. Launch plain and sign in in-app with
  # the same account as the Mac you want to pair with.
  if [[ "$NO_SETUP" -eq 0 && "$NO_SIGN_IN" -eq 0 ]]; then
    echo "==> --prod-auth: skipping auto sign-in/auto-pair (dogfood creds are dev-channel); sign in in the app"
    NO_SIGN_IN=1
  fi
fi

# Bake service origins because a launched iOS app does not inherit the tagged
# macOS process environment. A Simulator can reach the matching tag's localhost
# server. A physical device cannot: localhost is the phone itself, so Debug
# device builds use staging unless the caller supplies a reachable override.
# Production-auth builds retain production origins. Explicit overrides always
# win, including the shared CMUX_DEV_API_BASE_URL used by tagged Mac builds.
cmux_ios_resolve_api_base_url() {
  local target="$1"
  local explicit_base_url="${CMUX_IOS_API_BASE_URL:-${CMUX_DEV_API_BASE_URL:-}}"

  if [[ -n "$explicit_base_url" ]]; then
    printf '%s' "$explicit_base_url"
  elif [[ "$PROD_AUTH" -eq 1 ]]; then
    printf '%s' "https://cmux.com"
  elif [[ -n "${CMUX_VM_API_BASE_URL:-}" ]]; then
    printf '%s' "$CMUX_VM_API_BASE_URL"
  elif [[ "$target" == "physical_device" ]]; then
    printf '%s' "https://cmux-staging.vercel.app"
  elif [[ "${CMUX_PORT:-}" =~ ^[0-9]+$ ]] \
      && (( 10#$CMUX_PORT >= 1 && 10#$CMUX_PORT <= 65535 )); then
    printf 'http://localhost:%d' "$((10#$CMUX_PORT))"
  else
    printf '%s' "http://localhost:3000"
  fi
}

# Iroh discovery and grants always use one shared broker. This is staging for
# Debug builds on both targets and production for --prod-auth builds.
cmux_ios_resolve_iroh_broker_base_url() {
  local explicit_base_url="${CMUX_IOS_IROH_BROKER_BASE_URL:-${CMUX_IROH_BROKER_BASE_URL:-}}"

  if [[ -n "$explicit_base_url" ]]; then
    printf '%s' "$explicit_base_url"
  elif [[ "$PROD_AUTH" -eq 1 ]]; then
    printf '%s' "https://cmux.com"
  else
    printf '%s' "https://cmux-staging.vercel.app"
  fi
}

CMUX_IOS_SIMULATOR_API_BASE_URL_VALUE="$(cmux_ios_resolve_api_base_url simulator)"
CMUX_IOS_DEVICE_API_BASE_URL_VALUE="$(cmux_ios_resolve_api_base_url physical_device)"
CMUX_IOS_IROH_BROKER_BASE_URL_VALUE="$(cmux_ios_resolve_iroh_broker_base_url)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IROH_RELAY_POLICY_BUILD_ARGS=()
if [[ "$PROD_AUTH" -eq 1 ]]; then
  IROH_RELAY_POLICY_BUILD_ARGS=(
    -xcconfig "$IOS_DIR/../config/IrohRelayPolicyProduction.xcconfig"
  )
fi
# Shared tag/identity + attach helpers; sanitize_tag() above delegates here so the
# built bundle id matches the signed-launch bundle id. Sourced before any
# sanitize_tag call below.
# shellcheck source=../../scripts/lib/mobile-attach.sh
source "$IOS_DIR/../scripts/lib/mobile-attach.sh"
# Fail before building if the tag would collide with a fallback/reserved identity
# or exceed the cloud presence limit.
if ! cmux_attach_validate_dev_tag "$TAG"; then
  exit 1
fi
WORKSPACE="$IOS_DIR/cmux.xcworkspace"
SCHEME="cmux-ios"
TAG_SLUG="$(sanitize_tag "$TAG")"
DISPLAY_NAME="cmux DEV $TAG"
BUNDLE_ID="dev.cmux.ios.$TAG_SLUG"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/cmux-ios-$TAG_SLUG"
QUEUE_SCRIPT="$IOS_DIR/../scripts/iphone-install-queue.sh"

# Enforced verification default: simulator + iPhone. When a default device id
# is configured (CMUX_IPHONE_DEVICE_ID or ~/.config/cmux/iphone-device-id) and
# the caller made no explicit device/simulator-only choice, enable the device
# leg automatically so agent verification never silently stops at sim-only.
DEFAULT_DEVICE_ID=""
if [[ -x "$QUEUE_SCRIPT" ]]; then
  DEFAULT_DEVICE_ID="$("$QUEUE_SCRIPT" default-device 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
fi
if [[ "$SIMULATOR_ONLY" -eq 0 && "$RELOAD_DEVICE" -eq 0 && -n "$DEFAULT_DEVICE_ID" ]]; then
  RELOAD_DEVICE=1
  echo "==> default iPhone configured; reloading simulator + phone (opt out with --simulator-only)"
fi
if [[ "$RELOAD_DEVICE" -eq 1 && -z "$DEVICE_ID" && -z "$DEVICE_NAME" && -n "$DEFAULT_DEVICE_ID" ]]; then
  DEVICE_ID="$DEFAULT_DEVICE_ID"
fi

# iPhone auth gate: installed-but-signed-out is a failed install. Build-only
# staging (--no-launch) still runs the personal auth-contract preflight because
# mobile-dev-launch performs the signed launch immediately afterward, or the
# offline queue performs it when the phone reconnects. Only flags that actually
# skip that launcher (--no-sign-in, --no-setup, --no-attach) require a HUMAN
# setting CMUX_ALLOW_UNAUTHENTICATED_INSTALL=1 (agents never set it; same
# convention as CMUX_ALLOW_LOCAL_XCODEBUILD). --prod-auth is exempt: its
# sign-in is inherently manual and announced above.
if [[ "$RELOAD_DEVICE" -eq 1 && "$PROD_AUTH" -eq 0 ]] \
    && [[ "$NO_SIGN_IN" -eq 1 || "$NO_SETUP" -eq 1 || "$NO_ATTACH" -eq 1 ]] \
    && [[ "${CMUX_ALLOW_UNAUTHENTICATED_INSTALL:-0}" != "1" ]]; then
  echo "error: refusing an unauthenticated iPhone install: --no-sign-in/--no-setup/--no-attach skip the signed-in+paired auth gate" >&2
  echo "error: retry without the opt-out flag(s): ios/scripts/reload.sh --tag $TAG --device${DEVICE_ID:+ --device-id $DEVICE_ID}  (humans only: CMUX_ALLOW_UNAUTHENTICATED_INSTALL=1 to skip)" >&2
  exit 2
fi

# Isolated per-tag simulator by default: unless the caller explicitly picked a
# simulator (flag or IOS_SIMULATOR_NAME/IOS_SIMULATOR_ID), resolve or create
# "cmux-dev-<slug>" so concurrent agent sessions never share a simulator.
if [[ "$RELOAD_SIMULATOR" -eq 1 && "$SIMULATOR_EXPLICIT" -eq 0 ]]; then
  # shellcheck source=../../scripts/lib/ios-sim-isolate.sh
  source "$IOS_DIR/../scripts/lib/ios-sim-isolate.sh"
  SIMULATOR_ID="$(cmux_ios_isolated_sim_udid "$TAG_SLUG")"
  [[ -n "$SIMULATOR_ID" ]] || { echo "error: could not resolve the isolated simulator for tag $TAG" >&2; exit 1; }
  SIMULATOR_NAME="$(cmux_ios_isolated_sim_name "$TAG_SLUG")"
fi

DESTINATION="platform=iOS Simulator,name=$SIMULATOR_NAME"
if [[ -n "$SIMULATOR_ID" ]]; then
  DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"
fi
MOBILE_DEV_LAUNCH="$IOS_DIR/../scripts/mobile-dev-launch.sh"
DEVICE_PROCESS_HELPER="$IOS_DIR/../scripts/ios-device-process.sh"
GHOSTTYKIT_ENSURE="$IOS_DIR/../scripts/ensure-ghosttykit.sh"
DEVICE_AUTH_PROFILE="personal"
DEVICE_AUTH_CREDENTIALS_FILE="${CMUX_IOS_DOGFOOD_CREDENTIALS_FILE:-$HOME/.secrets/cmuxterm-dev.env}"
DEVICE_AUTH_ACCOUNT=""
DEVICE_AUTH_REQUIRED=0
if [[ "$RELOAD_DEVICE" -eq 1 && "$PROD_AUTH" -eq 0 \
    && "$NO_SETUP" -eq 0 && "$NO_SIGN_IN" -eq 0 && "$NO_ATTACH" -eq 0 ]]; then
  DEVICE_AUTH_REQUIRED=1
  [[ -x "$MOBILE_DEV_LAUNCH" ]] \
    || { echo "error: $MOBILE_DEV_LAUNCH is required for authenticated iPhone setup" >&2; exit 1; }
  auth_contract_output="$(
    "$MOBILE_DEV_LAUNCH" \
      --check-auth-contract \
      --auth-profile "$DEVICE_AUTH_PROFILE" \
      --credentials-file "$DEVICE_AUTH_CREDENTIALS_FILE"
  )" || exit $?
  DEVICE_AUTH_ACCOUNT="$(printf '%s\n' "$auth_contract_output" \
    | awk -F= '$1 == "CMUX_DEV_AUTH_ACCOUNT" { print substr($0, index($0, "=") + 1); exit }')"
  [[ -n "$DEVICE_AUTH_ACCOUNT" ]] \
    || { echo "error: iPhone auth preflight returned no selected account" >&2; exit 2; }
  echo "==> iPhone auth contract: $DEVICE_AUTH_PROFILE ($DEVICE_AUTH_ACCOUNT)"
fi

# Keep the linked xcframework synchronized with the checked-out Ghostty
# submodule before Xcode builds either target. Without this, a local cloud
# fallback can reuse a stale GhosttyKit symlink and compile against an older C
# header even though the Swift sources target the current submodule API.
if [[ ! -x "$GHOSTTYKIT_ENSURE" ]]; then
  echo "error: $GHOSTTYKIT_ENSURE not found or not executable" >&2
  exit 1
fi
"$GHOSTTYKIT_ENSURE"

# Best-effort user notification (mirrors the queue script's notify).
reload_device_notify() {
  local title="$1" body="$2" cmux_bin
  cmux_bin="$(command -v cmux 2>/dev/null || true)"
  [[ -z "$cmux_bin" && -x "$HOME/.local/bin/cmux" ]] && cmux_bin="$HOME/.local/bin/cmux"
  [[ -n "$cmux_bin" ]] || return 0
  "$cmux_bin" notify --title "$title" --body "$body" >/dev/null 2>&1 || true
}

# Auto-setup launch: relaunch the just-installed app signed in (dogfood creds
# injected) and, unless --no-attach, auto-paired to the tagged Mac app. Delegates
# to scripts/mobile-dev-launch.sh so there is ONE signed-launch path. Returns
# non-zero on any failure so callers can warn + leave the app installed (75
# passes through mobile-dev-launch's phone-offline/locked deferred-delivery
# code). $1 = device|simulator, $2 = device install id (device only).
auto_setup_launch() {
  local kind="$1" id="${2:-}"
  local args=(--tag "$TAG")
  if [[ "$kind" == "device" ]]; then
    args+=(--device)
    [[ -n "$id" ]] && args+=(--device-id "$id")
    if [[ "$DEVICE_AUTH_REQUIRED" -eq 1 ]]; then
      args+=(
        --auth-profile "$DEVICE_AUTH_PROFILE"
        --expected-account "$DEVICE_AUTH_ACCOUNT"
        --credentials-file "$DEVICE_AUTH_CREDENTIALS_FILE"
      )
    fi
  else
    # --detach: do not attach the simulator console (would block this script).
    # Pass the exact resolved UDID so the launch targets the sim we installed
    # onto, not just the first booted sim sharing the name.
    args+=(--simulator "$SIMULATOR_NAME" --detach)
    [[ -n "$id" ]] && args+=(--simulator-id "$id")
    args+=(--auth-profile agent)
  fi
  # Auto-pair by default (--ensure-mac enables the pairing host + launches the
  # tagged Mac app if down, then mints a ticket). --no-attach must be forwarded
  # explicitly: mobile-dev-launch now defaults DEVICE launches to --ensure-mac,
  # so omitting the flag would silently override the caller's opt-out.
  if [[ "$NO_ATTACH" -eq 0 ]]; then
    args+=(--ensure-mac)
  else
    args+=(--no-attach)
  fi
  if [[ ! -x "$MOBILE_DEV_LAUNCH" ]]; then
    echo "warning: $MOBILE_DEV_LAUNCH not found/executable; cannot auto-sign-in" >&2
    return 1
  fi
  "$MOBILE_DEV_LAUNCH" "${args[@]}"
}

# Dev-build identity baked into the app's Info.plist (CMUXGitSHA / CMUXDevTag),
# surfaced in-app under Settings > About so a dogfood build is tellable. The
# short SHA marks "+" when the working tree is dirty. Use `git status --porcelain`
# (not `git diff HEAD`) so an UNTRACKED new source file also flips the marker:
# SwiftPM/Xcode compile untracked files under Sources, so a build that contains
# uncommitted local work must never read as a clean committed SHA. These default
# empty in Shared.xcconfig, so a TestFlight/release build shows a clean "1.0.0"
# while a reload shows "1.0.0 (123) · <tag> · <sha>".
GIT_SHA="$(git -C "$IOS_DIR" rev-parse --short HEAD 2>/dev/null || true)"
if [[ -n "$GIT_SHA" && -n "$(git -C "$IOS_DIR" status --porcelain 2>/dev/null)" ]]; then
  GIT_SHA="$GIT_SHA+"
fi

LOCAL_ASC_CONFIG="$IOS_DIR/Config/AppStoreConnect.local.plist"
if [[ -f "$LOCAL_ASC_CONFIG" ]]; then
  ASC_API_KEY_ID="${ASC_API_KEY_ID:-$(/usr/libexec/PlistBuddy -c 'Print :ASC_API_KEY_ID' "$LOCAL_ASC_CONFIG" 2>/dev/null || true)}"
  ASC_API_ISSUER_ID="${ASC_API_ISSUER_ID:-$(/usr/libexec/PlistBuddy -c 'Print :ASC_API_ISSUER_ID' "$LOCAL_ASC_CONFIG" 2>/dev/null || true)}"
  ASC_API_KEY_PATH="${ASC_API_KEY_PATH:-$(/usr/libexec/PlistBuddy -c 'Print :ASC_API_KEY_PATH' "$LOCAL_ASC_CONFIG" 2>/dev/null || true)}"
fi

XCODE_AUTH_ARGS=()
if [[ -n "${ASC_API_KEY_ID:-}" && -n "${ASC_API_ISSUER_ID:-}" && -n "${ASC_API_KEY_PATH:-}" ]]; then
  XCODE_AUTH_ARGS=(
    -authenticationKeyPath "$ASC_API_KEY_PATH"
    -authenticationKeyID "$ASC_API_KEY_ID"
    -authenticationKeyIssuerID "$ASC_API_ISSUER_ID"
  )
fi

# Tell the mobile-attach QR server (scripts/mobile-attach-qr-server.sh) which
# iOS tag is freshest, so the QR's "Open" button + bundle id track this reload
# without restarting the server. Merges into the shared marker so a concurrent
# macOS reload's mac_tag is preserved. Best-effort: never fail the reload over
# the marker (e.g. no python3, read-only TMPDIR).
update_qr_tag_marker() {
  # FIXED /tmp path (not TMPDIR): the QR server runs in a different shell whose
  # per-session TMPDIR differs, so the rendezvous file must be machine-shared.
  local marker="/tmp/cmux-mobile-attach-qr-tags.json"
  command -v python3 >/dev/null 2>&1 || return 0
  IOS_TAG="$TAG" MARKER="$marker" python3 - <<'PY' 2>/dev/null || true
import json, os
marker = os.environ["MARKER"]
data = {}
try:
    with open(marker) as fh:
        loaded = json.load(fh)
        if isinstance(loaded, dict):
            data = loaded
except (FileNotFoundError, ValueError, OSError):
    pass
data["ios_tag"] = os.environ["IOS_TAG"]
tmp = marker + ".tmp"
with open(tmp, "w") as fh:
    json.dump(data, fh)
os.replace(tmp, marker)
PY
}

run_and_capture() {
  local log_path="$1"
  shift

  set +e
  "$@" 2>&1 | tee "$log_path"
  local status="${PIPESTATUS[0]}"
  set -e

  return "$status"
}

print_device_build_failure() {
  local log_path="$1"

  if grep -Eiq "No Accounts|No profiles|requires a development team|requires a provisioning profile|provisioning profile|Automatic signing|Signing for .* requires|No signing certificate|doesn't include the selected device|requires a signing certificate" "$log_path"; then
    cat >&2 <<EOF
error: physical device reload needs local iOS signing setup.

Xcode could not sign the tagged app for a connected device. Set up an Apple
Developer account in Xcode or provide App Store Connect API credentials through
ASC_API_KEY_ID, ASC_API_ISSUER_ID, and ASC_API_KEY_PATH, make sure the device is
registered for the team, then retry with either:

  IOS_DEVELOPMENT_TEAM=<TEAM_ID> ios/scripts/reload.sh --tag $TAG --device
  ios/scripts/reload.sh --tag $TAG --device --team <TEAM_ID>

The script does not store signing credentials or hardcode team ids.
Build log:
  $log_path
EOF
  elif grep -Eiq "developer disk image could not be mounted|Timed out waiting for all destinations|destination specifier|not eligible" "$log_path"; then
    cat >&2 <<EOF
error: physical device reload needs the connected device to be ready for Xcode.

Xcode could not prepare the selected iPhone/iPad as a build destination. Make
sure the device is unlocked, trusted, in Developer Mode, and supported by the
installed Xcode device support files.
Build log:
  $log_path
EOF
  else
    cat >&2 <<EOF
error: physical device build failed.
Build log:
  $log_path
EOF
  fi
}

select_device() {
  IOS_DEVICE_ID_REQUEST="$DEVICE_ID" IOS_DEVICE_NAME_REQUEST="$DEVICE_NAME" /usr/bin/python3 - <<'PY'
import json
import os
import subprocess
import sys
import tempfile

requested_id = os.environ.get("IOS_DEVICE_ID_REQUEST", "")
requested_name = os.environ.get("IOS_DEVICE_NAME_REQUEST", "")

with tempfile.NamedTemporaryFile() as output:
    result = subprocess.run(
        ["xcrun", "devicectl", "list", "devices", "--json-output", output.name],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr, end="")
        raise SystemExit(result.returncode)
    output.seek(0)
    data = json.load(output)

devices = []
for device in data.get("result", {}).get("devices", []):
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    properties = device.get("deviceProperties", {})
    if hardware.get("platform") != "iOS":
        continue
    if hardware.get("reality") != "physical":
        continue
    if connection.get("pairingState") != "paired":
        continue

    coredevice_id = str(device.get("identifier") or "")
    hardware_udid = str(hardware.get("udid") or "")
    destination_id = hardware_udid or coredevice_id
    install_id = coredevice_id or hardware_udid
    if not destination_id or not install_id:
        continue

    name = properties.get("name") or destination_id
    ids = {
        coredevice_id,
        hardware_udid,
        str(hardware.get("serialNumber") or ""),
        str(hardware.get("ecid") or ""),
    }
    boot_state = str(properties.get("bootState") or "")
    transport = str(connection.get("transportType") or "")
    tunnel_state = str(connection.get("tunnelState") or "")
    has_modern_coredevice_status = bool(properties.get("developerModeStatus"))
    available = (
        boot_state.lower() == "booted"
        or (
            transport == "localNetwork"
            and tunnel_state != "unavailable"
            and has_modern_coredevice_status
        )
    )
    devices.append({
        "identifier": destination_id,
        "install_identifier": install_id,
        "name": name,
        "ids": ids,
        "available": available,
        "boot": properties.get("bootState") or "unknown",
        "tunnel": connection.get("tunnelState") or "unknown",
    })

if requested_id:
    exact_matches = [
        device for device in devices
        if any(requested_id == candidate for candidate in device["ids"])
    ]
    partial_matches = [
        device for device in devices
        if any(requested_id in candidate for candidate in device["ids"])
    ]
    matches = exact_matches or partial_matches
    if len(matches) > 1:
        print(f"error: device id is ambiguous: {requested_id}", file=sys.stderr)
        for device in matches:
            print(f"  {device['name']} ({device['identifier']})", file=sys.stderr)
        raise SystemExit(1)
    if matches:
        device = matches[0]
        if not device["available"]:
            print(
                f"error: requested device is not available: {device['name']} ({device['identifier']}), "
                f"boot={device['boot']}, tunnel={device['tunnel']}",
                file=sys.stderr,
            )
            raise SystemExit(1)
        print(f"{device['identifier']}\t{device['install_identifier']}\t{device['name']}")
        raise SystemExit(0)
    print(f"error: requested device id not found: {requested_id}", file=sys.stderr)
    raise SystemExit(1)

if requested_name:
    matches = [device for device in devices if device["name"] == requested_name]
    if not matches:
        matches = [device for device in devices if requested_name.lower() in device["name"].lower()]
    if len(matches) > 1:
        print(f"error: device name is ambiguous: {requested_name}", file=sys.stderr)
        for device in matches:
            print(f"  {device['name']} ({device['identifier']})", file=sys.stderr)
        raise SystemExit(1)
    if matches:
        device = matches[0]
        if not device["available"]:
            print(
                f"error: requested device is not available: {device['name']} ({device['identifier']}), "
                f"boot={device['boot']}, tunnel={device['tunnel']}",
                file=sys.stderr,
            )
            raise SystemExit(1)
        print(f"{device['identifier']}\t{device['install_identifier']}\t{device['name']}")
        raise SystemExit(0)
    print(f"error: requested device name not found: {requested_name}", file=sys.stderr)
    raise SystemExit(1)

for device in devices:
    if device["available"]:
        print(f"{device['identifier']}\t{device['install_identifier']}\t{device['name']}")
        raise SystemExit(0)

print("error: no available paired physical iPhone/iPad found", file=sys.stderr)
if devices:
    print("Connected paired physical iOS devices:", file=sys.stderr)
    for device in devices:
        print(
            f"  {device['name']} ({device['identifier']}), boot={device['boot']}, tunnel={device['tunnel']}",
            file=sys.stderr,
        )
raise SystemExit(1)
PY
}

reload_simulator() {
  echo "==> Building simulator app (tag: $TAG, simulator: $SIMULATOR_NAME${SIMULATOR_ID:+, id: $SIMULATOR_ID})"

  # Build the Swift package + app target with -O / wholemodule even on
  # Debug. The VT parser + snapshot rehydration runs on every push from
  # the Mac (potentially >60Hz with the frame-driven event path); -O0
  # compiled Swift is fast enough to compile but produces materially
  # slower runtime code. Keep Debug configuration so codesigning and
  # debug info still work, but force the compiler to optimize.
  xcodebuild \
    ${XCODEBUILD_PARALLEL_ARGS[@]+"${XCODEBUILD_PARALLEL_ARGS[@]}"} \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    ${IROH_RELAY_POLICY_BUILD_ARGS[@]+"${IROH_RELAY_POLICY_BUILD_ARGS[@]}"} \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    PRODUCT_DISPLAY_NAME="$DISPLAY_NAME" \
    CMUX_GIT_SHA="$GIT_SHA" \
    CMUX_DEV_TAG="$TAG" \
    CMUX_PRESENCE_BASE_URL="${CMUX_PRESENCE_BASE_URL:-}" \
    CMUX_IOS_AUTH_ENV="$CMUX_IOS_AUTH_ENV_VALUE" \
    CMUX_API_BASE_URL="$CMUX_IOS_SIMULATOR_API_BASE_URL_VALUE" \
    CMUX_IROH_BROKER_BASE_URL="$CMUX_IOS_IROH_BROKER_BASE_URL_VALUE" \
    EXCLUDED_SOURCE_FILE_NAMES=Info.plist \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_OPTIMIZATION_LEVEL=-O \
    SWIFT_COMPILATION_MODE=wholemodule \
    GCC_OPTIMIZATION_LEVEL=s \
    ${SWIFT_WORKAROUND_ARGS[@]+"${SWIFT_WORKAROUND_ARGS[@]}"} \
    build

  APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/cmux.app"
  if [[ ! -d "$APP_PATH" ]]; then
    echo "error: built app not found at $APP_PATH" >&2
    exit 1
  fi

  if [[ -n "$SIMULATOR_ID" ]]; then
    SIM_ID="$SIMULATOR_ID"
  else
    SIM_ID="$(SIMULATOR_NAME="$SIMULATOR_NAME" /usr/bin/python3 - <<'PY'
import json
import os
import subprocess
import sys

name = os.environ["SIMULATOR_NAME"]
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
for runtimes in data.get("devices", {}).values():
    for device in runtimes:
        if device.get("name") == name and device.get("isAvailable", True):
            print(device["udid"])
            raise SystemExit(0)
print(f"error: simulator not found: {name}", file=sys.stderr)
raise SystemExit(1)
PY
    )"
  fi

  xcrun simctl boot "$SIM_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$SIM_ID" "$APP_PATH"

  if [[ "$LAUNCH" -eq 1 && "$SIMULATOR_LAUNCH" -eq 1 ]]; then
    xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    if [[ "$NO_SETUP" -eq 1 || "$NO_SIGN_IN" -eq 1 ]]; then
      xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" >/dev/null
    elif ! auto_setup_launch simulator "$SIM_ID"; then
      echo "error: installed $BUNDLE_ID, but signed setup failed; refusing an unpaired fallback launch" >&2
      echo "error: repair the tagged Mac/Iroh route, or pass --no-attach, --no-sign-in, or --no-setup explicitly" >&2
      return 1
    fi
  elif [[ "$LAUNCH" -eq 1 ]]; then
    echo "==> simulator installed but not launched because the trusted phone reload owns the tagged Mac pairing"
  fi

  cat <<EOF
==> iOS simulator reload succeeded
App path:
  $APP_PATH
Bundle id:
  $BUNDLE_ID
Simulator:
  $SIMULATOR_NAME ($SIM_ID)
EOF
  if [[ "$PROD_AUTH" -eq 1 ]]; then
    cat <<EOF
Auth environment:
  production (--prod-auth): sign in in-app with your real account, then pair
  with the Mac DEV build that has tag $TAG.
EOF
  fi
}

# Every phone build ships with the same-tag Mac dev build (the iOS app is
# unusable without its Mac). Build the Mac tag first when missing; refuse to
# ship a phone-only build when that fails.
mac_app_present() {
  [[ -d "$(cmux_attach_mac_app_path "$TAG")" ]] && return 0
  compgen -G "$HOME/Library/Developer/Xcode/DerivedData/cmux-$TAG/Build/Products/Debug/cmux DEV*.app" >/dev/null 2>&1
}

ensure_mac_build() {
  mac_app_present && return 0
  if [[ "${CMUX_IOS_SKIP_MAC_BUILD_CHECK:-0}" == "1" ]]; then
    echo "warning: same-tag Mac dev build missing (CMUX_IOS_SKIP_MAC_BUILD_CHECK=1; shipping phone-only at your own risk)" >&2
    return 0
  fi
  local repo_root mac_reload
  repo_root="$(cd "$IOS_DIR/.." && pwd)"
  if [[ -x "$repo_root/scripts/reload-cloud.sh" ]]; then
    mac_reload="$repo_root/scripts/reload-cloud.sh"
  else
    mac_reload="$repo_root/scripts/reload.sh"
  fi
  echo "==> same-tag Mac dev build missing for '$TAG'; building it first ($mac_reload)"
  if ! ( cd "$repo_root" && "$mac_reload" --tag "$TAG" ); then
    echo "error: Mac tagged build failed; refusing to ship a phone-only iOS build (the iOS app is unusable without its Mac)." >&2
    echo "error: build it manually (./scripts/reload-cloud.sh --tag $TAG or ./scripts/reload.sh --tag $TAG), then re-run." >&2
    exit 1
  fi
  if ! mac_app_present; then
    echo "error: Mac build finished but no tagged Mac app was found; refusing a phone-only iOS build." >&2
    exit 1
  fi
}

reload_device() {
  local selection
  local selected_device_id
  local selected_device_install_id
  local selected_device_name
  local selection_remainder
  local device_destination
  local device_app_path
  local build_log
  local tab
  local build_args
  local queue_mode=0
  local queued_device_id=""

  ensure_mac_build

  # Reachability uses ONE probe implementation (the queue script's), so the
  # local and cloud reload paths agree on what "unreachable" means, including
  # the CMUX_IPHONE_QUEUE_FORCE_UNREACHABLE test hook. select_device still owns
  # name/ambiguity resolution for reachable devices, and its failure is treated
  # as unreachable too (the phone can drop between probe and selection).
  # A --device-name target never falls back to the DEFAULT device id: queueing
  # a build for a different phone than the one named would install it on the
  # wrong device.
  local probe_id="$DEVICE_ID"
  if [[ -z "$probe_id" && -z "$DEVICE_NAME" ]]; then
    probe_id="$DEFAULT_DEVICE_ID"
  fi
  local device_unreachable=0
  if [[ -n "$probe_id" && -x "$QUEUE_SCRIPT" ]] \
      && ! "$QUEUE_SCRIPT" probe --device-id "$probe_id" >/dev/null 2>&1; then
    device_unreachable=1
  elif ! selection="$(select_device)"; then
    device_unreachable=1
  fi

  if [[ "$device_unreachable" -eq 1 ]]; then
    # The target iPhone is unreachable. Build anyway and park the signed app in
    # the offline install queue so it auto-installs when the phone reconnects,
    # instead of silently shipping simulator-only.
    queued_device_id="$probe_id"
    if [[ "$ALLOW_DEVICE_REGISTRATION" -eq 1 ]]; then
      echo "error: --allow-device-registration needs the device connected; cannot queue" >&2
      exit 1
    fi
    if [[ -z "$queued_device_id" ]]; then
      if [[ -n "$DEVICE_NAME" ]]; then
        echo "error: device '$DEVICE_NAME' is unreachable and name targets cannot be queued (the queue needs a stable id); pass --device-id instead" >&2
      else
        echo "error: iPhone unreachable and no device id to queue for (pass --device-id, set CMUX_IPHONE_DEVICE_ID, or write ~/.config/cmux/iphone-device-id)" >&2
      fi
      exit 1
    fi
    if [[ ! -x "$QUEUE_SCRIPT" ]]; then
      echo "error: iPhone unreachable and $QUEUE_SCRIPT is missing; cannot queue the build" >&2
      exit 1
    fi
    queue_mode=1
    selected_device_name="(unreachable, queueing for $queued_device_id)"
    echo "==> iPhone unreachable; the signed build will be QUEUED for auto-install on reconnect"
  else
    tab=$'\t'
    selected_device_id="${selection%%"$tab"*}"
    selection_remainder="${selection#*"$tab"}"
    selected_device_install_id="${selection_remainder%%"$tab"*}"
    selected_device_name="${selection_remainder#*"$tab"}"
  fi
  device_destination="generic/platform=iOS"
  if [[ "$queue_mode" -eq 0 && "$ALLOW_DEVICE_REGISTRATION" -eq 1 ]]; then
    device_destination="platform=iOS,id=$selected_device_id"
  fi
  device_app_path="$DERIVED_DATA/Build/Products/Debug-iphoneos/cmux.app"
  build_log="${TMPDIR:-/tmp}/cmux-ios-device-build-$TAG_SLUG.log"

  echo "==> Building physical device app (tag: $TAG, device: $selected_device_name)"

  build_args=(
    xcodebuild
    ${XCODEBUILD_PARALLEL_ARGS[@]+"${XCODEBUILD_PARALLEL_ARGS[@]}"}
    -workspace "$WORKSPACE"
    -scheme "$SCHEME"
    -configuration Debug
    -destination "$device_destination"
    -derivedDataPath "$DERIVED_DATA"
  )
  build_args+=(${IROH_RELAY_POLICY_BUILD_ARGS[@]+"${IROH_RELAY_POLICY_BUILD_ARGS[@]}"})

  if [[ "$ALLOW_PROVISIONING_UPDATES" -eq 1 ]]; then
    build_args+=(-allowProvisioningUpdates)
  fi

  if [[ "$ALLOW_DEVICE_REGISTRATION" -eq 1 ]]; then
    build_args+=(-allowProvisioningDeviceRegistration)
  fi

  # bash 3.2 + set -u errors on expanding an empty array; guard the expansion.
  build_args+=(${XCODE_AUTH_ARGS[@]+"${XCODE_AUTH_ARGS[@]}"})

  build_args+=(
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
    PRODUCT_DISPLAY_NAME="$DISPLAY_NAME"
    CMUX_GIT_SHA="$GIT_SHA"
    CMUX_DEV_TAG="$TAG"
    CMUX_PRESENCE_BASE_URL="${CMUX_PRESENCE_BASE_URL:-}"
    CMUX_IOS_AUTH_ENV="$CMUX_IOS_AUTH_ENV_VALUE"
    CMUX_API_BASE_URL="$CMUX_IOS_DEVICE_API_BASE_URL_VALUE"
    CMUX_IROH_BROKER_BASE_URL="$CMUX_IOS_IROH_BROKER_BASE_URL_VALUE"
    EXCLUDED_SOURCE_FILE_NAMES=Info.plist
    CODE_SIGNING_ALLOWED=YES
    CODE_SIGN_STYLE=Automatic
    # Force Swift -O / wholemodule on Debug. See the same flags on the
    # simulator path for why.
    SWIFT_OPTIMIZATION_LEVEL=-O
    SWIFT_COMPILATION_MODE=wholemodule
    GCC_OPTIMIZATION_LEVEL=s
  )

  if [[ "${#SWIFT_WORKAROUND_ARGS[@]}" -gt 0 ]]; then
    build_args+=("${SWIFT_WORKAROUND_ARGS[@]}")
  fi

  if [[ -n "$DEVELOPMENT_TEAM" ]]; then
    build_args+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
  fi

  build_args+=(build)

  if ! run_and_capture "$build_log" "${build_args[@]}"; then
    print_device_build_failure "$build_log"
    exit 1
  fi

  if [[ ! -d "$device_app_path" ]]; then
    echo "error: built device app not found at $device_app_path" >&2
    exit 1
  fi

  if [[ "$queue_mode" -eq 1 ]]; then
    local enqueue_args
    enqueue_args=(enqueue --tag "$TAG" --app "$device_app_path" \
      --device-id "$queued_device_id" --checkout "$(cd "$IOS_DIR/.." && pwd)")
    if [[ "$DEVICE_AUTH_REQUIRED" -eq 1 ]]; then
      enqueue_args+=(
        --auth-profile "$DEVICE_AUTH_PROFILE"
        --expected-account "$DEVICE_AUTH_ACCOUNT"
        --credentials-file "$DEVICE_AUTH_CREDENTIALS_FILE"
      )
    elif [[ "$NO_ATTACH" -eq 1 || "$NO_SIGN_IN" -eq 1 || "$NO_SETUP" -eq 1 ]]; then
      # The preflight above permits this branch only after a human explicitly
      # opted out of the iPhone auth gate. Keep that intent visible in the
      # persistent queue entry instead of relying only on the opt-out flags.
      enqueue_args+=(--allow-unauthenticated)
    else
      echo "error: cannot queue a physical iPhone build without its personal auth contract" >&2
      echo "error: provide the personal profile, or use --prod-auth for a manual in-app sign-in after the phone reconnects" >&2
      return 1
    fi
    [[ "$NO_ATTACH" -eq 1 ]] && enqueue_args+=(--no-attach)
    [[ "$NO_SIGN_IN" -eq 1 ]] && enqueue_args+=(--no-sign-in)
    [[ "$NO_SETUP" -eq 1 ]] && enqueue_args+=(--no-setup)
    [[ "$LAUNCH" -eq 0 ]] && enqueue_args+=(--no-launch)
    "$QUEUE_SCRIPT" "${enqueue_args[@]}"
    # Queued is NOT installed: report it truthfully with a distinct exit code
    # (75 = delivery deferred), notify so the human can unlock/reconnect, and
    # exit promptly instead of retrying or watching.
    reload_device_notify "iPhone offline: $TAG build queued" \
      "Reconnect/unlock the iPhone to receive the '$TAG' dev build (auto-installs on reconnect). Manual retry: scripts/iphone-install-queue.sh drain"
    echo "==> queued; unlock/reconnect the iPhone to receive. Retry: scripts/iphone-install-queue.sh drain (then scripts/verify-iphone-auth.sh --tag $TAG --device-id $queued_device_id)"
    return 75
  fi

  echo "==> Installing physical device app"
  if [[ ! -x "$DEVICE_PROCESS_HELPER" ]]; then
    echo "error: $DEVICE_PROCESS_HELPER not found or not executable" >&2
    exit 1
  fi
  "$DEVICE_PROCESS_HELPER" terminate-installed \
    --device-id "$selected_device_install_id" \
    --bundle-id "$BUNDLE_ID"
  # CMUX_SANCTIONED_IPHONE_INSTALL marks this install as coming from the
  # sanctioned wrapper flow, so the cmuxterm-hq local-build-guards devicectl
  # interceptor lets it through while refusing raw agent installs (which skip
  # sign-in). Inert on machines without the guards.
  CMUX_SANCTIONED_IPHONE_INSTALL=1 \
    xcrun devicectl device install app --device "$selected_device_install_id" "$device_app_path"

  local device_auth_status
  if [[ "$DEVICE_AUTH_REQUIRED" -eq 1 ]]; then
    device_auth_status="staged (--no-launch; authenticated mobile-dev-launch runs separately or on queue reconnect)"
  else
    device_auth_status="not launched (--no-launch; auth gate skipped by explicit opt-out)"
  fi
  if [[ "$LAUNCH" -eq 1 ]]; then
    if [[ "$NO_SETUP" -eq 1 || "$NO_SIGN_IN" -eq 1 ]]; then
      # Plain launch (no sign-in / no pair); reachable only via --prod-auth or
      # the human-only CMUX_ALLOW_UNAUTHENTICATED_INSTALL=1. A launch failure
      # (most commonly a LOCKED device) must not fail the whole reload here.
      if ! xcrun devicectl device process launch --terminate-existing --device "$selected_device_install_id" "$BUNDLE_ID" >/dev/null 2>&1; then
        echo "warning: installed but could not launch $BUNDLE_ID (device locked? unlock the iPhone and tap the app)" >&2
      fi
      if [[ "$PROD_AUTH" -eq 1 ]]; then
        device_auth_status="manual (--prod-auth): sign in in-app, then pair with the tagged Mac"
      else
        device_auth_status="UNVERIFIED (explicit opt-out): NOT signed in; verify later with scripts/verify-iphone-auth.sh --tag $TAG --device-id $selected_device_install_id"
      fi
    else
      local setup_rc=0
      auto_setup_launch device "$selected_device_install_id" || setup_rc=$?
      if [[ "$setup_rc" -eq 75 ]]; then
        # Phone went offline or is LOCKED mid-delivery: park the already-built
        # signed app in the install queue so it lands on unlock/reconnect,
        # notify, and exit promptly with the deferred-delivery code. Never
        # watch for unlock here. Only claim "queued" if the enqueue succeeded.
        # Preserve the caller's --no-attach so the queued drain honors the
        # human-authorized unpaired intent instead of escalating to ensure-mac
        # (this branch only runs with NO_SETUP=0 and NO_SIGN_IN=0).
        local deferred_enqueue_args
        deferred_enqueue_args=(enqueue --tag "$TAG" --app "$device_app_path" \
          --device-id "$selected_device_install_id" --checkout "$(cd "$IOS_DIR/.." && pwd)")
        if [[ "$DEVICE_AUTH_REQUIRED" -eq 1 ]]; then
          deferred_enqueue_args+=(
            --auth-profile "$DEVICE_AUTH_PROFILE"
            --expected-account "$DEVICE_AUTH_ACCOUNT"
            --credentials-file "$DEVICE_AUTH_CREDENTIALS_FILE"
          )
        else
          # This can only be reached for a human-authorized opt-out, as
          # reload's iPhone auth preflight rejects every other no-auth path.
          deferred_enqueue_args+=(--allow-unauthenticated)
        fi
        [[ "$NO_ATTACH" -eq 1 ]] && deferred_enqueue_args+=(--no-attach)
        if ! "$QUEUE_SCRIPT" "${deferred_enqueue_args[@]}"; then
          echo "error: iPhone is locked/offline AND the build could NOT be queued; nothing will auto-install" >&2
          echo "error: retry after unlocking: scripts/mobile-dev-launch.sh --tag $TAG --device --device-id $selected_device_install_id --ensure-mac" >&2
          return 1
        fi
        reload_device_notify "iPhone locked/offline: $TAG build queued" \
          "Unlock/reconnect the iPhone to receive the '$TAG' dev build (auto-installs via the queue). Manual retry: scripts/iphone-install-queue.sh drain"
        echo "==> queued; unlock to receive. Retry: scripts/iphone-install-queue.sh drain (then scripts/verify-iphone-auth.sh --tag $TAG --device-id $selected_device_install_id)"
        return 75
      elif [[ "$setup_rc" -ne 0 ]]; then
        # A plain fallback can reuse stale pairing state and look dogfood-ready
        # while the matching tagged Iroh route is absent. Fail closed unless the
        # caller explicitly requested a plain launch above.
        echo "error: installed $BUNDLE_ID, but the iPhone auth gate failed; refusing an unpaired fallback launch" >&2
        echo "error: retry: scripts/mobile-dev-launch.sh --tag $TAG --device --device-id $selected_device_install_id --ensure-mac" >&2
        return 1
      elif [[ "$NO_ATTACH" -eq 1 ]]; then
        # Signed launch without pairing (human-authorized opt-out): the auth
        # gate never ran, so this install must not be reported as verified.
        device_auth_status="UNVERIFIED (--no-attach opt-out): sign-in attempted but not proven; check with scripts/verify-iphone-auth.sh --tag $TAG --device-id $selected_device_install_id"
      else
        device_auth_status="verified signed in + paired (iPhone auth gate PASS; re-check: scripts/verify-iphone-auth.sh --tag $TAG --device-id $selected_device_install_id)"
      fi
    fi
  fi

  cat <<EOF
==> iOS physical device reload succeeded
App path:
  $device_app_path
Bundle id:
  $BUNDLE_ID
Device:
  $selected_device_name ($selected_device_id)
Auth:
  $device_auth_status
EOF
  if [[ "$PROD_AUTH" -eq 1 ]]; then
    cat <<EOF
Auth environment:
  production (--prod-auth): sign in in-app with your real account, then pair
  with the Mac DEV build that has tag $TAG.
EOF
  fi
}

echo "==> iOS reload starting (tag: $TAG)"

if [[ "$RELOAD_DEVICE" -eq 1 && "$LAUNCH" -eq 1 && "$NO_SETUP" -eq 0 && "$NO_SIGN_IN" -eq 0 && "$NO_ATTACH" -eq 0 ]]; then
  SIMULATOR_LAUNCH=0
  echo "==> combined phone reload will install but not launch the simulator to preserve the personal Mac pairing"
fi

if [[ "$RELOAD_SIMULATOR" -eq 1 ]]; then
  reload_simulator
fi

if [[ "$RELOAD_DEVICE" -eq 1 ]]; then
  reload_device
fi

update_qr_tag_marker
