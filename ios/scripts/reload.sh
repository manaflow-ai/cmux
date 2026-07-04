#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ios/scripts/reload.sh --tag <tag> [--simulator <name>] [--no-launch]
       ios/scripts/reload.sh --tag <tag> --device [--device-id <id>] [--device-name <name>] [--team <team-id>] [--no-launch]
       ios/scripts/reload.sh --tag <tag> --device-only [--device-id <id>] [--device-name <name>] [--team <team-id>] [--no-launch]

Build, install, and launch the cmux iOS app with an isolated tag.

By default this reloads only the simulator. Use --device to also reload the
first available paired iPhone/iPad, or --device-only to skip the simulator.

By default, direct reloads use production auth and launch signed-out so they can
pair with beta/stable/nightly Macs after you sign in with your real account.
Pass --dev-auth to use dogfood credentials and auto-pair to the tagged Mac app.
Opt out granularly:
  --no-sign-in   plain launch, no auto sign-in (implies no auto-pair)
  --no-attach    sign in, but do not auto-pair to the Mac
  --no-setup     plain install + launch (today's behavior)

  --prod-auth    deprecated no-op; production auth is now the default for DEV
                 reloads so the build can pair with beta/stable/nightly Macs.
  --dev-auth     build against the development Stack project. Use this for the
                 local auto-sign-in/auto-pair dogfood flow only; it cannot pair
                 with a production-auth Mac QR.

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
DEVICE_ID="${IOS_DEVICE_ID:-}"
DEVICE_NAME="${IOS_DEVICE_NAME:-}"
DEVELOPMENT_TEAM="${IOS_DEVELOPMENT_TEAM:-}"
LAUNCH=1
RELOAD_SIMULATOR=1
RELOAD_DEVICE=0
ALLOW_PROVISIONING_UPDATES=1
ALLOW_DEVICE_REGISTRATION=0
# Auto-setup: under --dev-auth, after install + launch, sign in (inject dogfood
# creds) and auto-pair to the tagged Mac app. Production-auth reloads skip this
# because the dogfood credentials belong to the development Stack project.
# Opt out granularly.
NO_SIGN_IN=0
NO_ATTACH=0
NO_SETUP=0
# Auth channel baked into CMUXAuthEnvironment. DEV reloads default to production
# so a sideloaded build can scan/pair with beta/stable/nightly Macs. --dev-auth
# remains the explicit escape hatch for local dogfood credentials.
AUTH_ENV_VALUE="production"

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
      shift 2
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
    --prod-auth)
      echo "==> --prod-auth: deprecated no-op; production auth is now the default for DEV reloads. Use --dev-auth for the local dogfood flow."
      AUTH_ENV_VALUE="production"
      shift
      ;;
    --dev-auth)
      AUTH_ENV_VALUE="development"
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

# The value lands in the CMUXAuthEnvironment Info.plist key (a tapped device
# build sees no shell env), read by MobileAuthComposition. Presence needs no
# URL here: PresenceClient.resolvedServiceBaseURL follows the resolved auth
# channel, so the worker URLs live only in Swift and cannot drift; an explicit
# CMUX_PRESENCE_BASE_URL still wins as before.
CMUX_IOS_AUTH_ENV_VALUE="$AUTH_ENV_VALUE"
if [[ "$AUTH_ENV_VALUE" == "production" ]]; then
  # The dogfood auto-login creds are dev-Stack-project accounts; against
  # production auth they cannot sign in. Launch plain and sign in in-app with
  # the same account as the Mac you want to pair with.
  if [[ "$NO_SETUP" -eq 0 && "$NO_SIGN_IN" -eq 0 ]]; then
    echo "==> production auth: skipping auto sign-in/auto-pair (dogfood creds are dev-channel); sign in in the app"
    NO_SIGN_IN=1
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Shared tag/identity + attach helpers; sanitize_tag() above delegates here so the
# built bundle id matches the signed-launch bundle id. Sourced before any
# sanitize_tag call below.
# shellcheck source=../../scripts/lib/mobile-attach.sh
source "$IOS_DIR/../scripts/lib/mobile-attach.sh"
# Fail closed on tags with no alphanumerics (their slug collapses onto the shared
# fallback identity), matching the macOS reload's reject-empty behavior.
if ! cmux_attach_tag_has_alnum "$TAG"; then
  echo "error: --tag '$TAG' has no letters or digits; pick a tag with at least one alphanumeric character" >&2
  exit 1
fi
WORKSPACE="$IOS_DIR/cmux.xcworkspace"
SCHEME="cmux-ios"
TAG_SLUG="$(sanitize_tag "$TAG")"
DISPLAY_NAME="cmux DEV $TAG"
BUNDLE_ID="dev.cmux.ios.$TAG_SLUG"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/cmux-ios-$TAG_SLUG"
DESTINATION="platform=iOS Simulator,name=$SIMULATOR_NAME"
MOBILE_DEV_LAUNCH="$IOS_DIR/../scripts/mobile-dev-launch.sh"

# Auto-setup launch: relaunch the just-installed app signed in (dogfood creds
# injected) and, unless --no-attach, auto-paired to the tagged Mac app. Delegates
# to scripts/mobile-dev-launch.sh so there is ONE signed-launch path. Returns
# non-zero on any failure so callers can warn + leave the app installed. $1 =
# device|simulator, $2 = device install id (device only).
auto_setup_launch() {
  local kind="$1" id="${2:-}"
  local args=(--tag "$TAG")
  if [[ "$kind" == "device" ]]; then
    args+=(--device)
    [[ -n "$id" ]] && args+=(--device-id "$id")
  else
    # --detach: do not attach the simulator console (would block this script).
    # Pass the exact resolved UDID so the launch targets the sim we installed
    # onto, not just the first booted sim sharing the name.
    args+=(--simulator "$SIMULATOR_NAME" --detach)
    [[ -n "$id" ]] && args+=(--simulator-id "$id")
  fi
  # Auto-pair by default (--ensure-mac enables the pairing host + launches the
  # tagged Mac app if down, then mints a ticket); --no-attach signs in only.
  [[ "$NO_ATTACH" -eq 0 ]] && args+=(--ensure-mac)
  if [[ ! -x "$MOBILE_DEV_LAUNCH" ]]; then
    echo "warning: $MOBILE_DEV_LAUNCH not found/executable; cannot auto-sign-in" >&2
    return 1
  fi
  "$MOBILE_DEV_LAUNCH" "${args[@]}"
}

print_auth_environment_summary() {
  if [[ "$AUTH_ENV_VALUE" == "production" ]]; then
    cat <<EOF
Auth environment:
  production (default): sign in in-app with your real account, then pair
  with your beta/stable Mac using the in-app QR scanner.
EOF
  elif [[ "$NO_SETUP" -eq 1 ]]; then
    cat <<EOF
Auth environment:
  development (--dev-auth): plain launch; auto sign-in/auto-pair skipped (--no-setup).
EOF
  elif [[ "$NO_SIGN_IN" -eq 1 ]]; then
    cat <<EOF
Auth environment:
  development (--dev-auth): plain launch; auto sign-in/auto-pair skipped (--no-sign-in).
EOF
  elif [[ "$NO_ATTACH" -eq 1 ]]; then
    cat <<EOF
Auth environment:
  development (--dev-auth): auto sign-in is enabled; auto-pair skipped (--no-attach).
EOF
  else
    cat <<EOF
Auth environment:
  development (--dev-auth): local dogfood auto sign-in/auto-pair is enabled.
EOF
  fi
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
  echo "==> Building simulator app (tag: $TAG, simulator: $SIMULATOR_NAME)"

  # Build the Swift package + app target with -O / wholemodule even on
  # Debug. The VT parser + snapshot rehydration runs on every push from
  # the Mac (potentially >60Hz with the frame-driven event path); -O0
  # compiled Swift is fast enough to compile but produces materially
  # slower runtime code. Keep Debug configuration so codesigning and
  # debug info still work, but force the compiler to optimize.
  xcodebuild \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    PRODUCT_DISPLAY_NAME="$DISPLAY_NAME" \
    CMUX_GIT_SHA="$GIT_SHA" \
    CMUX_DEV_TAG="$TAG" \
    CMUX_PRESENCE_BASE_URL="${CMUX_PRESENCE_BASE_URL:-}" \
    CMUX_IOS_AUTH_ENV="$CMUX_IOS_AUTH_ENV_VALUE" \
    EXCLUDED_SOURCE_FILE_NAMES=Info.plist \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_OPTIMIZATION_LEVEL=-O \
    SWIFT_COMPILATION_MODE=wholemodule \
    GCC_OPTIMIZATION_LEVEL=s \
    build

  APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/cmux.app"
  if [[ ! -d "$APP_PATH" ]]; then
    echo "error: built app not found at $APP_PATH" >&2
    exit 1
  fi

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

  xcrun simctl boot "$SIM_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$SIM_ID" "$APP_PATH"

  if [[ "$LAUNCH" -eq 1 ]]; then
    xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    if [[ "$NO_SETUP" -eq 1 || "$NO_SIGN_IN" -eq 1 ]]; then
      xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" >/dev/null
    elif ! auto_setup_launch simulator "$SIM_ID"; then
      echo "warning: signed launch failed; launching plain (sign in manually)" >&2
      xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" >/dev/null
    fi
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
  print_auth_environment_summary
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

  selection="$(select_device)"
  tab=$'\t'
  selected_device_id="${selection%%$tab*}"
  selection_remainder="${selection#*$tab}"
  selected_device_install_id="${selection_remainder%%$tab*}"
  selected_device_name="${selection_remainder#*$tab}"
  device_destination="generic/platform=iOS"
  if [[ "$ALLOW_DEVICE_REGISTRATION" -eq 1 ]]; then
    device_destination="platform=iOS,id=$selected_device_id"
  fi
  device_app_path="$DERIVED_DATA/Build/Products/Debug-iphoneos/cmux.app"
  build_log="${TMPDIR:-/tmp}/cmux-ios-device-build-$TAG_SLUG.log"

  echo "==> Building physical device app (tag: $TAG, device: $selected_device_name)"

  build_args=(
    xcodebuild
    -workspace "$WORKSPACE"
    -scheme "$SCHEME"
    -configuration Debug
    -destination "$device_destination"
    -derivedDataPath "$DERIVED_DATA"
  )

  if [[ "$ALLOW_PROVISIONING_UPDATES" -eq 1 ]]; then
    build_args+=(-allowProvisioningUpdates)
  fi

  if [[ "$ALLOW_DEVICE_REGISTRATION" -eq 1 ]]; then
    build_args+=(-allowProvisioningDeviceRegistration)
  fi

  build_args+=("${XCODE_AUTH_ARGS[@]}")

  build_args+=(
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
    PRODUCT_DISPLAY_NAME="$DISPLAY_NAME"
    CMUX_GIT_SHA="$GIT_SHA"
    CMUX_DEV_TAG="$TAG"
    CMUX_PRESENCE_BASE_URL="${CMUX_PRESENCE_BASE_URL:-}"
    CMUX_IOS_AUTH_ENV="$CMUX_IOS_AUTH_ENV_VALUE"
    EXCLUDED_SOURCE_FILE_NAMES=Info.plist
    CODE_SIGNING_ALLOWED=YES
    CODE_SIGN_STYLE=Automatic
    # Force Swift -O / wholemodule on Debug. See the same flags on the
    # simulator path for why.
    SWIFT_OPTIMIZATION_LEVEL=-O
    SWIFT_COMPILATION_MODE=wholemodule
    GCC_OPTIMIZATION_LEVEL=s
  )

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

  echo "==> Installing physical device app"
  xcrun devicectl device install app --device "$selected_device_install_id" "$device_app_path"

  if [[ "$LAUNCH" -eq 1 ]]; then
    # Build + install already succeeded; a launch failure (most commonly a
    # LOCKED device — "could not be unlocked") must not fail the whole reload
    # or skip the QR marker update below. Warn and continue.
    if [[ "$NO_SETUP" -eq 1 || "$NO_SIGN_IN" -eq 1 ]]; then
      # Plain launch (no sign-in / no pair). --no-sign-in implies no auto-setup
      # since attaching without a signed-in session is meaningless.
      if ! xcrun devicectl device process launch --terminate-existing --device "$selected_device_install_id" "$BUNDLE_ID" >/dev/null 2>&1; then
        echo "warning: installed but could not launch $BUNDLE_ID (device locked? unlock the iPhone and tap the app)" >&2
      fi
    elif ! auto_setup_launch device "$selected_device_install_id"; then
      # Auto sign-in/pair failed (e.g. missing dogfood creds, helper, or Mac).
      # Fall back to a plain launch so the freshly installed app still opens,
      # matching the simulator path and the previous device behavior.
      echo "warning: signed launch failed; launching plain (sign in manually)" >&2
      if ! xcrun devicectl device process launch --terminate-existing --device "$selected_device_install_id" "$BUNDLE_ID" >/dev/null 2>&1; then
        echo "warning: installed but could not launch $BUNDLE_ID (device locked? unlock the iPhone and tap the app)" >&2
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
EOF
  print_auth_environment_summary
}

echo "==> iOS reload starting (tag: $TAG)"

if [[ "$RELOAD_SIMULATOR" -eq 1 ]]; then
  reload_simulator
fi

if [[ "$RELOAD_DEVICE" -eq 1 ]]; then
  reload_device
fi

update_qr_tag_marker
