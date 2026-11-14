#!/usr/bin/env bash
# Launch a tagged cmux iOS DEV build signed in, with no human OAuth, so a dev
# or agent can dogfood on the simulator or a device.
#
# It reuses the app's DEBUG launch hooks:
#   CMUX_UITEST_STACK_EMAIL / CMUX_UITEST_STACK_PASSWORD  -> real Stack sign-in
#   CMUX_UITEST_MOCK_DATA=0                               -> real backend, not mock
#   CMUX_DOGFOOD_READINESS_NONCE                          -> binds the app receipt
# (sim env via SIMCTL_CHILD_*, device env via DEVICECTL_CHILD_*).
#
# Physical devices select the personal profile. Simulators select the shared
# agent profile unless their caller chooses a profile explicitly. No profile
# can fall through to credentials belonging to another profile.
#
# The gate is the app's own signed-in receipt (app-receipt). The iOS app does
# not pair with the Mac, and the cmux-next Mac app no longer runs the iroh
# phone listener, so no Mac takes part in a launch.
#
# Usage:
#   scripts/mobile-dev-launch.sh --tag grid [--simulator "iPhone 17"] [--detach]
#   scripts/mobile-dev-launch.sh --tag grid --device [--device-id <id>]
#   scripts/mobile-dev-launch.sh --tag grid --agent
#
#   --attach, --ensure-mac, --no-attach
#              accepted for older callers and ignored: there is no Mac pairing.
#   --auth-profile <personal|agent>
#              select one identity class without fallback. --agent is a
#              compatibility alias for --auth-profile agent.
#   --expected-account <email>
#              fail before target mutation unless the selected credential file
#              resolves to this normalized account.
#   --check-auth-contract
#              validate the selected profile/file/account and exit without a
#              tag, build, simulator, device, or Mac action.
#   --detach   simulator only: launch without attaching stdio, so the app keeps
#              running after this script exits.
#   --credentials-file <absolute-path>
#              load one 0600 credential file exclusively.
#   --readiness <app-receipt|auto>
#              app-receipt injects a fresh CMUX_DOGFOOD_READINESS_NONCE and waits
#              (CMUX_APP_RECEIPT_TIMEOUT_SECONDS, default 90) for the app's own
#              signed-in receipt at Library/Application Support/cmux-dogfood/
#              readiness.json in its data container; nonce, client id, bundle
#              id, and account must match. auto (default) reads Info.plist
#              CMUXDogfoodReadiness from CMUX_INSTALLED_APP_PATH or the
#              simulator's installed app, which must declare app-receipt-v1.
#
# Refused with exit 2, before credentials load or any target changes:
# --readiness mac-rpc, --iroh-release-gate, --restore-pairing, and an auto mode
# that finds no app-receipt-v1 app. They need the Mac's iroh phone listener
# (mobile.attach_ticket.create / mobile.rpc.ready), which cmux-next removed.
#
# Exit codes: 0 success (device: auth gate PASS), 1 launch/gate failure,
# 2 usage or refused launch, 75 phone offline or locked
# (delivery deferred: notify sent, no retry/watcher loop — rerun the printed
# command after unlocking/reconnecting, or let the install queue deliver).

set -euo pipefail

# Deferred-delivery exit code (EX_TEMPFAIL): the phone is offline or locked.
# Policy: enqueue-and-notify, never sit in an agent-side unlock/ready watcher.
EXIT_PHONE_AWAY=75

cmux_mdl_notify() {
  local title="$1" body="$2" cmux_bin
  cmux_bin="$(command -v cmux 2>/dev/null || true)"
  [[ -z "$cmux_bin" && -x "$HOME/.local/bin/cmux" ]] && cmux_bin="$HOME/.local/bin/cmux"
  [[ -n "$cmux_bin" ]] || return 0
  "$cmux_bin" notify --title "$title" --body "$body" >/dev/null 2>&1 || true
}

# Why every Mac-side path is refused: nothing on this branch serves it.
NO_MAC_RPC="the cmux-next Mac app no longer runs the iroh phone listener (mobile.attach_ticket.create / mobile.rpc.ready)"

TAG=""
TARGET="simulator"          # simulator | device
SIMULATOR_NAME="iPhone 17"
SIMULATOR_ID=""             # exact booted sim UDID (wins over name when set)
DEVICE_ID=""
ATTACH=0                    # only reports that --attach/--ensure-mac were ignored
DETACH=0
REFUSED_FLAG=""
AUTH_CREDENTIALS_FILE=""
AUTH_PROFILE=""
AUTH_PROFILE_EXPLICIT=0
EXPECTED_ACCOUNT=""
CHECK_AUTH_CONTRACT=0
READINESS_REQUEST="auto"      # auto | app-receipt (resolved into READINESS_MODE)
READINESS_MODE=""
APP_RECEIPT_TIMEOUT_SECONDS="${CMUX_APP_RECEIPT_TIMEOUT_SECONDS:-90}"

usage() { sed -n '2,56p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --simulator) TARGET="simulator"; SIMULATOR_NAME="${2:-}"; shift 2 ;;
    # Exact booted simulator UDID; wins over --simulator name so callers that
    # already resolved/installed onto a specific sim launch on THAT one.
    --simulator-id) TARGET="simulator"; SIMULATOR_ID="${2:-}"; shift 2 ;;
    --device) TARGET="device"; shift ;;
    --device-id) DEVICE_ID="${2:-}"; shift 2 ;;
    # Kept so older callers (reload scripts, queue entries, workflows) still
    # parse. The app-receipt gate ignores them.
    --attach|--ensure-mac) ATTACH=1; shift ;;
    --no-attach) ATTACH=0; shift ;;
    --agent) AUTH_PROFILE="agent"; AUTH_PROFILE_EXPLICIT=1; shift ;;
    --auth-profile)
      [[ -n "${2:-}" ]] || { echo "error: --auth-profile requires a value" >&2; exit 2; }
      AUTH_PROFILE="$2"; AUTH_PROFILE_EXPLICIT=1; shift 2
      ;;
    --expected-account)
      [[ -n "${2:-}" ]] || { echo "error: --expected-account requires an email" >&2; exit 2; }
      EXPECTED_ACCOUNT="$2"; shift 2
      ;;
    --check-auth-contract) CHECK_AUTH_CONTRACT=1; shift ;;
    --detach) DETACH=1; shift ;;
    --iroh-release-gate) REFUSED_FLAG="${REFUSED_FLAG:-$1}"; shift; [[ $# -eq 0 ]] || shift ;;
    --restore-pairing) REFUSED_FLAG="${REFUSED_FLAG:-$1}"; shift ;;
    --credentials-file)
      [[ -n "${2:-}" ]] || { echo "error: --credentials-file requires a path" >&2; exit 2; }
      AUTH_CREDENTIALS_FILE="$2"; shift 2
      ;;
    --readiness)
      [[ -n "${2:-}" ]] || { echo "error: --readiness requires app-receipt or auto" >&2; exit 2; }
      READINESS_REQUEST="$2"; shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown arg $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- paths with no target -----------------------------------------------------
# The Iroh release gate and cached-pairing restore pair the app with the Mac
# over its iroh route; mac-rpc waits for the Mac's mobile.rpc.ready event.
# Refuse them before loading credentials or touching a simulator or device.
if [[ -n "$REFUSED_FLAG" ]]; then
  echo "error: $REFUSED_FLAG has no target: $NO_MAC_RPC, and the Iroh release gate needs that route" >&2
  exit 2
fi
case "$READINESS_REQUEST" in
  auto|app-receipt) ;;
  mac-rpc)
    echo "error: --readiness mac-rpc has no target: $NO_MAC_RPC; use --readiness app-receipt" >&2
    exit 2
    ;;
  *) echo "error: --readiness must be app-receipt or auto" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CMUX_MOBILE_SOURCE_CHECKOUT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=scripts/lib/dev-secrets.sh
source "$SCRIPT_DIR/lib/dev-secrets.sh"
# shellcheck source=scripts/lib/mobile-attach.sh
source "$SCRIPT_DIR/lib/mobile-attach.sh"

if [[ -z "$AUTH_PROFILE" ]]; then
  if [[ "$TARGET" == "device" ]]; then
    AUTH_PROFILE="personal"
  else
    AUTH_PROFILE="agent"
  fi
fi
case "$AUTH_PROFILE" in
  personal|agent) ;;
  *) echo "error: --auth-profile must be personal or agent" >&2; exit 2 ;;
esac
if [[ "$TARGET" == "device" && "$AUTH_PROFILE" != "personal" ]]; then
  echo "error: physical iPhone dogfood requires --auth-profile personal; the shared agent account is simulator-only" >&2
  exit 2
fi
if [[ "$CHECK_AUTH_CONTRACT" -eq 1 && "$AUTH_PROFILE_EXPLICIT" -ne 1 ]]; then
  echo "error: --check-auth-contract requires an explicit --auth-profile" >&2
  exit 2
fi
if [[ -z "$AUTH_CREDENTIALS_FILE" ]]; then
  case "$AUTH_PROFILE" in
    personal) AUTH_CREDENTIALS_FILE="$HOME/.secrets/cmuxterm-dev.env" ;;
    # Leave the agent profile unpinned so the loader can discover both the
    # current cmuxterm-dev.env location and the legacy ~/.secrets/cmux.env.
    agent) AUTH_CREDENTIALS_FILE="" ;;
  esac
fi
if [[ "$DETACH" -eq 1 && "$TARGET" != "simulator" ]]; then
  echo "error: --detach is supported only with simulator launches" >&2
  usage >&2
  exit 2
fi

# Ignore ambient auth vars from the calling shell. Normal dev launches must
# resolve from the verified file-backed dogfood creds or an explicit
# --credentials-file, never a stale shell export.
unset CMUX_AUTH_ENVIRONMENT CMUX_STACK_PROJECT_ID CMUX_STACK_PUBLISHABLE_CLIENT_KEY
unset CMUX_AUTH_CREDENTIALS_FILE CMUX_DEV_AUTH_PROFILE CMUX_DEV_AUTH_ACCOUNT
unset CMUX_DOGFOOD_STACK_EMAIL CMUX_DOGFOOD_STACK_PASSWORD
unset CMUX_UITEST_STACK_EMAIL CMUX_UITEST_STACK_PASSWORD

# --- credentials ------------------------------------------------------------
# Exactly one profile is selected per run. Devices use personal, simulators
# default to agent, and no profile falls back to the other profile's account.
credential_args=(--profile "$AUTH_PROFILE")
[[ -n "$AUTH_CREDENTIALS_FILE" ]] && credential_args+=(--credentials-file "$AUTH_CREDENTIALS_FILE")
[[ -n "$EXPECTED_ACCOUNT" ]] && credential_args+=(--expected-account "$EXPECTED_ACCOUNT")
if [[ "$CHECK_AUTH_CONTRACT" -eq 1 ]]; then
  cmux_dev_secrets_load "${credential_args[@]}" >/dev/null || exit $?
  printf 'CMUX_DEV_AUTH_PROFILE=%s\nCMUX_DEV_AUTH_ACCOUNT=%s\n' \
    "$CMUX_DEV_AUTH_PROFILE" "$CMUX_DEV_AUTH_ACCOUNT"
  exit 0
fi

[[ -n "$TAG" ]] || { echo "error: --tag is required" >&2; usage >&2; exit 2; }
# Fail before loading credentials or touching a simulator/device if the tag
# would collide with a fallback/reserved identity or exceed the cloud limit.
if ! cmux_attach_validate_dev_tag "$TAG"; then
  exit 2
fi

# --- bundle id (matches ios/scripts/reload.sh sanitize_tag) ------------------
slug="$(cmux_attach__slug "$TAG")"
BUNDLE_ID="dev.cmux.ios.$slug"

# --- readiness mode -----------------------------------------------------------
# The app's own nonce-bound signed-in receipt is the only gate. auto reads the
# app's CMUXDogfoodReadiness. An app without app-receipt-v1 would need the
# mac-rpc gate, which has no target, so refuse before credentials load.
if [[ "$READINESS_REQUEST" == "app-receipt" ]]; then
  READINESS_MODE="app-receipt"
else
  READINESS_APP=""
  if [[ -n "${CMUX_INSTALLED_APP_PATH:-}" && -f "${CMUX_INSTALLED_APP_PATH}/Info.plist" ]]; then
    READINESS_APP="$CMUX_INSTALLED_APP_PATH"
    READINESS_SOURCE="CMUX_INSTALLED_APP_PATH ($READINESS_APP)"
  elif [[ "$TARGET" == "simulator" ]]; then
    # Read-only lookup of the app installed on the simulator.
    READINESS_SIM_UDID="$SIMULATOR_ID"
    if [[ -z "$READINESS_SIM_UDID" ]]; then
      READINESS_SIM_UDID="$(xcrun simctl list devices booted 2>/dev/null | grep -F "$SIMULATOR_NAME" | grep -oE '[0-9A-F-]{36}' | head -1 || true)"
    fi
    if [[ -n "$READINESS_SIM_UDID" ]]; then
      READINESS_APP="$(xcrun simctl get_app_container "$READINESS_SIM_UDID" "$BUNDLE_ID" app 2>/dev/null || true)"
    fi
    READINESS_SOURCE="the simulator's installed $BUNDLE_ID${READINESS_APP:+ ($READINESS_APP)}"
  else
    # A physical device does not expose the installed Info.plist.
    READINESS_SOURCE="a physical device without CMUX_INSTALLED_APP_PATH"
  fi
  READINESS_MODE="$(cmux_attach_app_readiness_mode "$READINESS_APP")" || exit 2
  if [[ "$READINESS_MODE" != "app-receipt" ]]; then
    echo "error: --readiness auto found no CMUXDogfoodReadiness = app-receipt-v1 in $READINESS_SOURCE" >&2
    echo "error: the mac-rpc fallback has no target: $NO_MAC_RPC" >&2
    echo "error: use --readiness app-receipt, or set CMUX_INSTALLED_APP_PATH to the installed .app" >&2
    exit 2
  fi
fi
if [[ ! "$APP_RECEIPT_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: CMUX_APP_RECEIPT_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi

cmux_dev_secrets_load "${credential_args[@]}" || exit $?
EXPECTED_ACCOUNT="$CMUX_DEV_AUTH_ACCOUNT"
MDL_AUTH_CONTRACT_ARGS="--auth-profile $CMUX_DEV_AUTH_PROFILE --expected-account $CMUX_DEV_AUTH_ACCOUNT"
if [[ -n "$AUTH_CREDENTIALS_FILE" ]]; then
  printf -v AUTH_CREDENTIALS_FILE_QUOTED '%q' "$AUTH_CREDENTIALS_FILE"
  MDL_AUTH_CONTRACT_ARGS+=" --credentials-file $AUTH_CREDENTIALS_FILE_QUOTED"
fi

# --- first (and only) device reachability probe -------------------------------
# A phone that is offline on the FIRST probe defers delivery: notify, print the
# retry command, and exit promptly with EXIT_PHONE_AWAY. Never retry or watch
# for unlock here — the install queue's LaunchAgent is the delivery mechanism.
if [[ "$TARGET" == "device" ]]; then
  if [[ -z "$DEVICE_ID" ]]; then
    DEVICE_ID="$(xcrun devicectl list devices 2>/dev/null \
      | awk '/iPhone/ && !/unavailable/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9A-Fa-f-]{36}$/){print $i; exit}}')"
    [[ -n "$DEVICE_ID" ]] || { echo "error: no connected iPhone found (pass --device-id)" >&2; exit 1; }
  fi
  MDL_RETRY_CMD="scripts/mobile-dev-launch.sh --tag $TAG --device --device-id $DEVICE_ID --readiness app-receipt $MDL_AUTH_CONTRACT_ARGS"
  QUEUE_SCRIPT_FOR_PROBE="$SCRIPT_DIR/iphone-install-queue.sh"
  if [[ -x "$QUEUE_SCRIPT_FOR_PROBE" ]] \
      && ! "$QUEUE_SCRIPT_FOR_PROBE" probe --device-id "$DEVICE_ID" >/dev/null 2>&1; then
    echo "==> iPhone $DEVICE_ID is offline (asleep or off network); delivery deferred, not retrying" >&2
    echo "==> queued installs land via the install queue on reconnect; retry: $MDL_RETRY_CMD" >&2
    cmux_mdl_notify "iPhone offline: $TAG launch deferred" \
      "Reconnect/unlock the iPhone to receive the '$TAG' dev build. Retry: $MDL_RETRY_CMD"
    exit "$EXIT_PHONE_AWAY"
  fi
fi
if [[ "$ATTACH" -eq 1 ]]; then
  echo "==> app-receipt readiness: this app has no tagged Mac pairing; --attach/--ensure-mac ignored, the app's own signed-in receipt is the gate"
fi
READINESS_NONCE="$(cmux_attach_readiness_nonce)"
[[ -n "$READINESS_NONCE" ]] || { echo "error: could not create a readiness nonce" >&2; exit 1; }
export SIMCTL_CHILD_CMUX_DOGFOOD_READINESS_NONCE="$READINESS_NONCE"
export DEVICECTL_CHILD_CMUX_DOGFOOD_READINESS_NONCE="$READINESS_NONCE"

# Never print credentials. One-shot production-account identities are redacted
# too; ordinary dogfood launches retain their existing account label so
# developers can detect accidental account selection.
SIGN_IN_ACCOUNT_LABEL="$CMUX_UITEST_STACK_EMAIL"
if [[ -n "$AUTH_CREDENTIALS_FILE" ]]; then
  SIGN_IN_ACCOUNT_LABEL="[redacted]"
fi
echo "==> launching $BUNDLE_ID on $TARGET (profile $CMUX_DEV_AUTH_PROFILE, signed in as $SIGN_IN_ACCOUNT_LABEL)"
READINESS_STARTED_MS="$(cmux_attach_monotonic_milliseconds)"

if [[ "$TARGET" == "simulator" ]]; then
  if [[ -n "$SIMULATOR_ID" ]]; then
    # Exact UDID the caller installed onto; do not re-resolve by name (multiple
    # booted sims can share a name across runtimes).
    SIM_UDID="$SIMULATOR_ID"
  else
    SIM_UDID="$(xcrun simctl list devices booted 2>/dev/null | grep -F "$SIMULATOR_NAME" | grep -oE '[0-9A-F-]{36}' | head -1)"
  fi
  if [[ -z "$SIM_UDID" ]]; then
    echo "error: simulator '${SIMULATOR_ID:-$SIMULATOR_NAME}' is not booted (boot it or pass --simulator <name>)" >&2
    exit 1
  fi
  DOGFOOD_CLIENT_ID="$(cmux_attach_dogfood_client_id "$BUNDLE_ID" "$SIM_UDID")"
  xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  SIMULATOR_DEVICE_ID="$(
    cmux_attach_seed_simulator_device_id "$SIM_UDID" "$BUNDLE_ID"
  )"
  # The app-receipt gate runs after launch returns, so the launch never
  # attaches the console (an attached console would block until the app exits).
  # The attach URLs stay empty so an ambient value can never pair the app.
  SIMCTL_CHILD_CMUX_UITEST_STACK_EMAIL="$CMUX_UITEST_STACK_EMAIL" \
  SIMCTL_CHILD_CMUX_UITEST_STACK_PASSWORD="$CMUX_UITEST_STACK_PASSWORD" \
  SIMCTL_CHILD_CMUX_DEV_AUTH_REPLACE_SESSION="${CMUX_DEV_AUTH_REPLACE_SESSION:-1}" \
  SIMCTL_CHILD_CMUX_SIMULATOR_DEVICE_ID="$SIMULATOR_DEVICE_ID" \
  SIMCTL_CHILD_CMUX_UITEST_MOCK_DATA="0" \
  SIMCTL_CHILD_CMUX_DOGFOOD_ATTACH_URL="" \
  SIMCTL_CHILD_CMUX_UITEST_ATTACH_URL="" \
  SIMCTL_CHILD_CMUX_DOGFOOD_CLIENT_ID="$DOGFOOD_CLIENT_ID" \
  SIMCTL_CHILD_CMUX_UITEST_SUPPRESS_WHATS_NEW="${CMUX_UITEST_SUPPRESS_WHATS_NEW:-0}" \
    xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID"
else
  if [[ -z "$DEVICE_ID" ]]; then
    DEVICE_ID="$(xcrun devicectl list devices 2>/dev/null \
      | awk '/iPhone/ && !/unavailable/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9A-Fa-f-]{36}$/){print $i; exit}}')"
  fi
  [[ -n "$DEVICE_ID" ]] || { echo "error: no connected iPhone found (pass --device-id)" >&2; exit 1; }
  DOGFOOD_CLIENT_ID="$(cmux_attach_dogfood_client_id "$BUNDLE_ID" "$DEVICE_ID")"
  # Pass the password via the DEVICECTL_CHILD_ prefix (calling-env
  # injection), NOT --environment-variables, which would expose these bearer
  # credentials in argv. devicectl strips DEVICECTL_CHILD_<NAME> from its own
  # environment and forwards it to the app as <NAME>, mirroring the simulator's
  # SIMCTL_CHILD_ path. This is documented in `devicectl device process launch
  # --help` (518.31): "set them in the calling environment with a DEVICECTL_CHILD_
  # prefix", and the -e note "Using the environment-variables flag will override
  # the caller environment variables prefixed with DEVICECTL_CHILD_".
  LAUNCH_ERR="$(mktemp "${TMPDIR:-/tmp}/cmux-mdl-launch-err.XXXXXX")"
  if ! DEVICECTL_CHILD_CMUX_UITEST_STACK_EMAIL="$CMUX_UITEST_STACK_EMAIL" \
  DEVICECTL_CHILD_CMUX_UITEST_STACK_PASSWORD="$CMUX_UITEST_STACK_PASSWORD" \
  DEVICECTL_CHILD_CMUX_DEV_AUTH_REPLACE_SESSION="${CMUX_DEV_AUTH_REPLACE_SESSION:-1}" \
  DEVICECTL_CHILD_CMUX_UITEST_MOCK_DATA="0" \
  DEVICECTL_CHILD_CMUX_DOGFOOD_ATTACH_URL="" \
  DEVICECTL_CHILD_CMUX_DOGFOOD_CLIENT_ID="$DOGFOOD_CLIENT_ID" \
    xcrun devicectl device process launch --terminate-existing \
      --device "$DEVICE_ID" "$BUNDLE_ID" 2>"$LAUNCH_ERR"; then
    cat "$LAUNCH_ERR" >&2
    if grep -qi "locked" "$LAUNCH_ERR"; then
      rm -f "$LAUNCH_ERR"
      # Locked phone: defer, notify, exit promptly. No unlock watcher.
      echo "==> iPhone is LOCKED; delivery deferred, not retrying" >&2
      echo "==> unlock the iPhone, then retry: $MDL_RETRY_CMD" >&2
      cmux_mdl_notify "iPhone locked: $TAG launch deferred" \
        "Unlock the iPhone to receive the '$TAG' dev build. Retry: $MDL_RETRY_CMD"
      exit "$EXIT_PHONE_AWAY"
    fi
    rm -f "$LAUNCH_ERR"
    echo "error: could not launch $BUNDLE_ID on $DEVICE_ID" >&2
    echo "error: retry: $MDL_RETRY_CMD" >&2
    exit 1
  fi
  rm -f "$LAUNCH_ERR"
fi

if [[ "$TARGET" == "device" ]]; then
  RECEIPT_TARGET="physical_device"
  RECEIPT_TARGET_ID="$DEVICE_ID"
else
  RECEIPT_TARGET="simulator_injection"
  RECEIPT_TARGET_ID="$SIM_UDID"
fi
if ! APP_RECEIPT_JSON="$(cmux_attach_wait_for_app_receipt \
    "$RECEIPT_TARGET" \
    "$RECEIPT_TARGET_ID" \
    "$BUNDLE_ID" \
    "$READINESS_NONCE" \
    "$DOGFOOD_CLIENT_ID" \
    "$CMUX_DEV_AUTH_ACCOUNT" \
    "" \
    "$APP_RECEIPT_TIMEOUT_SECONDS")"; then
  if [[ "$TARGET" == "device" ]]; then
    echo "error: iPhone auth gate FAILED: $BUNDLE_ID never published a signed-in app receipt for profile $CMUX_DEV_AUTH_PROFILE ($CMUX_DEV_AUTH_ACCOUNT)" >&2
    echo "error: retry: $MDL_RETRY_CMD" >&2
  else
    echo "error: $BUNDLE_ID never published a signed-in app receipt for profile $CMUX_DEV_AUTH_PROFILE ($CMUX_DEV_AUTH_ACCOUNT)" >&2
  fi
  exit 1
fi
READINESS_FINISHED_MS="$(cmux_attach_monotonic_milliseconds)"
READINESS_LATENCY_MS="$((READINESS_FINISHED_MS - READINESS_STARTED_MS))"
GIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
INSTALLED_BUNDLE_METADATA="$(cmux_attach_installed_bundle_metadata \
  "$RECEIPT_TARGET" "$RECEIPT_TARGET_ID" "$BUNDLE_ID")" || {
  echo "error: app receipt passed but installed bundle metadata could not be inspected" >&2
  exit 1
}
RECEIPT_DIR="${CMUX_READINESS_RECEIPT_DIR:-/tmp/cmux-ios-dogfood-readiness}"
RECEIPT_PATH="$RECEIPT_DIR/${slug}-$(cmux_attach__slug "$RECEIPT_TARGET_ID").json"
cmux_attach_write_app_readiness_receipt \
  "$RECEIPT_PATH" \
  "$GIT_SHA" \
  "$TAG" \
  "$BUNDLE_ID" \
  "$RECEIPT_TARGET" \
  "$RECEIPT_TARGET_ID" \
  "$READINESS_LATENCY_MS" \
  "${CMUX_DOGFOOD_LAUNCH_ATTEMPT_COUNT:-1}" \
  "$APP_RECEIPT_JSON" \
  "$INSTALLED_BUNDLE_METADATA"
echo "==> signed-in app receipt verified for $BUNDLE_ID (account $CMUX_DEV_AUTH_ACCOUNT)"
echo "==> readiness receipt: $RECEIPT_PATH"
if [[ "$TARGET" == "device" ]]; then
  echo "==> iPhone auth gate: PASS — $BUNDLE_ID on $DEVICE_ID verified profile $CMUX_DEV_AUTH_PROFILE ($CMUX_DEV_AUTH_ACCOUNT), signed in (app receipt)"
fi
