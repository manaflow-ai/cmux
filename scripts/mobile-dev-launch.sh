#!/usr/bin/env bash
# Launch a tagged cmux iOS DEV build fully signed in (and optionally paired to a
# running Mac), with NO human OAuth, so a dev or agent can autonomously dogfood
# on the simulator or a device.
#
# It reuses the app's existing DEBUG launch hooks:
#   CMUX_UITEST_STACK_EMAIL / CMUX_UITEST_STACK_PASSWORD  -> real Stack sign-in
#   CMUX_UITEST_MOCK_DATA=0                               -> real backend, not mock
#   CMUX_DOGFOOD_ATTACH_URL=<cmux-ios://attach...>        -> auto-pair after sign-in
# (sim env via SIMCTL_CHILD_*, device env via DEVICECTL_CHILD_*).
#
# Physical devices select the personal profile. Simulators select the shared
# agent profile unless their caller chooses a profile explicitly. No profile
# can fall through to credentials belonging to another profile.
#
# Usage:
#   scripts/mobile-dev-launch.sh --tag grid [--simulator "iPhone 17"] [--attach|--no-attach] [--detach]
#   scripts/mobile-dev-launch.sh --tag grid --device [--device-id <id>] [--attach|--no-attach]
#   scripts/mobile-dev-launch.sh --tag grid --agent  [--attach|--no-attach]
#
#   --attach   also pair to the running Mac. Mints a fresh target-specific,
#              tag-scoped ticket directly against THIS tag's Mac debug socket
#              (never an untagged QR-server ticket, which could pair the wrong
#              Mac). Needs the tagged Mac app running with the pairing host
#              enabled (see --ensure-mac).
#   --ensure-mac  imply --attach and, before minting, enable the tagged Mac app's
#              pairing host + launch it if its debug socket is down. Lets a device
#              reload auto-pair with no separately-running Mac app. This is the
#              DEFAULT for --device launches: a phone dogfood install must end
#              signed in AND paired, and the post-launch readiness wait is the
#              mechanical proof of both (the iPhone auth gate).
#   --no-attach  launch signed in without pairing. Also cancels --ensure-mac.
#              When attach flags are repeated, the last flag wins. On --device
#              this produces an UNVERIFIABLE install, so it is refused unless a
#              human set CMUX_ALLOW_UNAUTHENTICATED_INSTALL=1 (agents never set
#              it; same convention as CMUX_ALLOW_LOCAL_XCODEBUILD).
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
#   --iroh-release-gate <automatic|relayOnly|directOnly>
#              simulator only: run the credential-free Iroh release-gate probe
#              after sign-in and attach.
#   --credentials-file <absolute-path>
#              load one 0600 credential file exclusively. Intended for an
#              isolated temporary production release-gate account.
#
# Exit codes: 0 success (device: auth gate PASS), 1 launch/gate failure,
# 2 usage or refused-unverifiable launch, 75 phone offline or locked
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

TAG=""
TARGET="simulator"          # simulator | device
SIMULATOR_NAME="iPhone 17"
SIMULATOR_ID=""             # exact booted sim UDID (wins over name when set)
DEVICE_ID=""
ATTACH=0
ATTACH_EXPLICIT=0
ENSURE_MAC=0
DETACH=0
IROH_RELEASE_GATE_MODE=""
AUTH_CREDENTIALS_FILE=""
AUTH_PROFILE=""
AUTH_PROFILE_EXPLICIT=0
EXPECTED_ACCOUNT=""
CHECK_AUTH_CONTRACT=0
ATTACH_TTL_SECONDS="${CMUX_ATTACH_TTL_SECONDS:-600}"
ATTACH_MINT_MAX_ATTEMPTS="${CMUX_ATTACH_MINT_MAX_ATTEMPTS:-20}"
# Stack session restore and the first control-plane snapshot can take longer
# than the attach handshake itself on a physical device. Keep the default
# bounded, but leave enough room for a cold auth bootstrap before declaring the
# install unusable; callers can still tighten or extend it explicitly.
ATTACH_READY_TIMEOUT_SECONDS="${CMUX_ATTACH_READY_TIMEOUT_SECONDS:-60}"

usage() { sed -n '2,58p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --simulator) TARGET="simulator"; SIMULATOR_NAME="${2:-}"; shift 2 ;;
    # Exact booted simulator UDID; wins over --simulator name so callers that
    # already resolved/installed onto a specific sim launch on THAT one.
    --simulator-id) TARGET="simulator"; SIMULATOR_ID="${2:-}"; shift 2 ;;
    --device) TARGET="device"; shift ;;
    --device-id) DEVICE_ID="${2:-}"; shift 2 ;;
    --attach) ATTACH=1; ATTACH_EXPLICIT=1; shift ;;
    --no-attach) ATTACH=0; ENSURE_MAC=0; ATTACH_EXPLICIT=1; shift ;;
    # --ensure-mac: before minting, enable the tagged Mac app's pairing host and
    # launch it if its debug socket is down, so --attach can mint without a
    # separately-running Mac app. Implies --attach.
    --ensure-mac) ENSURE_MAC=1; ATTACH=1; ATTACH_EXPLICIT=1; shift ;;
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
    --iroh-release-gate) IROH_RELEASE_GATE_MODE="${2:-}"; shift 2 ;;
    --credentials-file)
      [[ -n "${2:-}" ]] || { echo "error: --credentials-file requires a path" >&2; exit 2; }
      AUTH_CREDENTIALS_FILE="$2"; shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown arg $1" >&2; usage >&2; exit 2 ;;
  esac
done

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
# iPhone auth gate policy: installed-but-signed-out is a failed install. A
# device launch therefore defaults to the full --ensure-mac flow, whose
# post-launch readiness wait is the mechanical proof of signed-in + paired. An
# explicitly unpaired device launch cannot be verified, so it hard-fails unless
# a HUMAN set CMUX_ALLOW_UNAUTHENTICATED_INSTALL=1 (agents never set it).
if [[ "$TARGET" == "device" ]]; then
  if [[ "$ATTACH_EXPLICIT" -eq 0 ]]; then
    ATTACH=1
    ENSURE_MAC=1
    echo "==> device launch defaults to --ensure-mac so the iPhone auth gate can verify signed-in + paired"
  elif [[ "$ATTACH" -eq 0 && "${CMUX_ALLOW_UNAUTHENTICATED_INSTALL:-0}" != "1" ]]; then
    echo "error: refusing an unverifiable iPhone launch: --no-attach skips the signed-in+paired auth gate" >&2
    echo "error: retry: scripts/mobile-dev-launch.sh --tag $TAG --device${DEVICE_ID:+ --device-id $DEVICE_ID} --ensure-mac  (humans only: CMUX_ALLOW_UNAUTHENTICATED_INSTALL=1 to skip the gate)" >&2
    exit 2
  fi
fi
if [[ ! "$ATTACH_MINT_MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: CMUX_ATTACH_MINT_MAX_ATTEMPTS must be a positive integer" >&2
  exit 2
fi
if [[ ! "$ATTACH_READY_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: CMUX_ATTACH_READY_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi
if [[ "$DETACH" -eq 1 && "$TARGET" != "simulator" ]]; then
  echo "error: --detach is supported only with simulator launches" >&2
  usage >&2
  exit 2
fi
if [[ -n "$IROH_RELEASE_GATE_MODE" ]]; then
  if [[ "$TARGET" != "simulator" ]]; then
    echo "error: --iroh-release-gate is simulator-only" >&2
    exit 2
  fi
  case "$IROH_RELEASE_GATE_MODE" in
    automatic|relayOnly|directOnly) ;;
    *)
      echo "error: invalid --iroh-release-gate mode '$IROH_RELEASE_GATE_MODE'" >&2
      exit 2
      ;;
  esac
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CMUX_MOBILE_SOURCE_CHECKOUT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=scripts/lib/dev-secrets.sh
source "$SCRIPT_DIR/lib/dev-secrets.sh"
# shellcheck source=scripts/lib/mobile-attach.sh
source "$SCRIPT_DIR/lib/mobile-attach.sh"
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
cmux_dev_secrets_load "${credential_args[@]}" || exit $?
EXPECTED_ACCOUNT="$CMUX_DEV_AUTH_ACCOUNT"
MDL_AUTH_CONTRACT_ARGS="--auth-profile $CMUX_DEV_AUTH_PROFILE --expected-account $CMUX_DEV_AUTH_ACCOUNT"
if [[ -n "$AUTH_CREDENTIALS_FILE" ]]; then
  printf -v AUTH_CREDENTIALS_FILE_QUOTED '%q' "$AUTH_CREDENTIALS_FILE"
  MDL_AUTH_CONTRACT_ARGS+=" --credentials-file $AUTH_CREDENTIALS_FILE_QUOTED"
fi

# --- bundle id (matches ios/scripts/reload.sh sanitize_tag) ------------------
slug="$(cmux_attach__slug "$TAG")"
BUNDLE_ID="dev.cmux.ios.$slug"

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
  MDL_RETRY_CMD="scripts/mobile-dev-launch.sh --tag $TAG --device --device-id $DEVICE_ID --ensure-mac $MDL_AUTH_CONTRACT_ARGS"
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
if [[ "$TARGET" == "device" || -n "$IROH_RELEASE_GATE_MODE" ]]; then
  # The release gate runs in a simulator but must fail closed until the Mac can
  # mint an identity-only Iroh route. Reuse the physical-device ticket policy,
  # which polls for Iroh and never falls back to loopback.
  ATTACH_TARGET="physical_device"
else
  ATTACH_TARGET="simulator_injection"
fi

# --- attach ticket ----------------------------------------------------------
# ATTACH_URL stays empty unless attach was explicitly requested, so a stale
# ambient CMUX_DOGFOOD_ATTACH_URL can NEVER auto-pair an unrequested launch
# (reload scripts that opt out simply leave ATTACH=0). The URL is injected
# as CMUX_DOGFOOD_ATTACH_URL, the NOT-mock-gated var the app reads with the real
# backend (CMUX_UITEST_MOCK_DATA=0).
ATTACH_URL=""
if [[ "$ATTACH" -eq 1 ]]; then
  ATTACH_SOCKET_READY=0
  ATTACH_MINT_STATUS=1
  if [[ "$ENSURE_MAC" -eq 1 ]]; then
    # Reuse a ready tagged Mac whose account already matches. If an
    # authenticated profile is selected while the socket is down, force a
    # clean process so `open` cannot reuse a stale app with the old identity.
    ENSURE_MAC_FORCE_RELAUNCH=0
    if [[ -n "$CMUX_DEV_AUTH_PROFILE" ]] \
        && ! cmux_attach_mac_socket_ready "$TAG"; then
      ENSURE_MAC_FORCE_RELAUNCH=1
    fi
    if ! cmux_attach_ensure_mac \
        "$TAG" \
        "$REPO_ROOT" \
        "$ATTACH_TARGET" \
        "$ENSURE_MAC_FORCE_RELAUNCH" \
        "$CMUX_DEV_AUTH_PROFILE" \
        "$AUTH_CREDENTIALS_FILE" \
        "$CMUX_DEV_AUTH_ACCOUNT"; then
      echo "error: could not prepare tagged Mac '$TAG' for auto-pair" >&2
      echo "error: expected the tagged Mac to authenticate as $CMUX_DEV_AUTH_ACCOUNT before pairing" >&2
      exit 1
    fi
  fi
  # Always mint from THIS tag's socket for the selected launch target. Never
  # trust an ambient URL or the tag-agnostic QR server, either of which could
  # pair this app with another tagged Mac instance.
  if cmux_attach_mac_socket_ready "$TAG"; then
    ATTACH_SOCKET_READY=1
    ATTACH_URL="$(cmux_attach_mint_url "$TAG" "$ATTACH_TTL_SECONDS" "$REPO_ROOT" "$ATTACH_TARGET" "$ATTACH_MINT_MAX_ATTEMPTS")" \
      || ATTACH_MINT_STATUS=$?
    if [[ -n "$ATTACH_URL" ]]; then
      ATTACH_MINT_STATUS=0
    fi
  fi
  if [[ -z "$ATTACH_URL" ]]; then
    if [[ "$ATTACH_TARGET" == "physical_device" ]]; then
      if [[ "$ATTACH_SOCKET_READY" -eq 0 ]]; then
        echo "error: tagged Mac '$TAG' is not running or its debug socket is not ready" >&2
        echo "error: start it and re-run with --ensure-mac, or re-run without --attach for an intentionally unpaired launch" >&2
      elif [[ "$ATTACH_MINT_STATUS" -eq 2 ]]; then
        echo "error: tagged Mac '$TAG' advertised routes, but no encrypted Iroh route became ready" >&2
        echo "error: Tailscale-only tickets are rejected because they cannot safely carry account credentials" >&2
        echo "error: repair the tagged Mac's web/Iroh setup and re-run, or re-run without --attach for an intentionally unpaired launch" >&2
      else
        echo "error: could not mint a trusted physical-device attach ticket for '$TAG'" >&2
        echo "error: the Iroh route may still be binding or its backend policy may be unavailable; retry after repairing the tagged Mac, or re-run without --attach" >&2
      fi
      exit 1
    elif [[ "$ENSURE_MAC" -eq 1 ]]; then
      echo "error: could not mint an attach ticket after preparing tagged Mac '$TAG'" >&2
    else
      echo "error: --attach requested but no attach ticket could be minted (try --ensure-mac, or use --no-attach for an intentionally unpaired launch)" >&2
    fi
    exit 1
  fi
fi

READINESS_CURSOR=""
if [[ -n "$ATTACH_URL" ]]; then
  if ! READINESS_CURSOR="$(cmux_attach_readiness_cursor "$TAG" "$REPO_ROOT")"; then
    echo "error: could not read tagged Mac diagnostics before mobile launch" >&2
    exit 1
  fi
fi

# Never print the attach URL (bearer credential). One-shot production-account
# identities are redacted too; ordinary dogfood launches retain their existing
# account label so developers can detect accidental account selection.
SIGN_IN_ACCOUNT_LABEL="$CMUX_UITEST_STACK_EMAIL"
if [[ -n "$AUTH_CREDENTIALS_FILE" ]]; then
  SIGN_IN_ACCOUNT_LABEL="[redacted]"
fi
echo "==> launching $BUNDLE_ID on $TARGET (profile $CMUX_DEV_AUTH_PROFILE, signed in as $SIGN_IN_ACCOUNT_LABEL${ATTACH_URL:+, auto-pairing})"
READINESS_STARTED_MS=""
# Ordinary dogfood needs this launcher to prove the app reached an authenticated
# RPC session. Release-gate launches instead let the in-app runner own readiness,
# path validation, and its longer relay-rollover deadline so its report survives.
if [[ -n "$READINESS_CURSOR" && -z "$IROH_RELEASE_GATE_MODE" ]]; then
  READINESS_STARTED_MS="$(cmux_attach_monotonic_milliseconds)"
fi

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
  launch_args=(launch)
  if [[ "$DETACH" -ne 1 ]]; then
    launch_args+=(--console-pty)
  fi
  SIMCTL_CHILD_CMUX_UITEST_STACK_EMAIL="$CMUX_UITEST_STACK_EMAIL" \
  SIMCTL_CHILD_CMUX_UITEST_STACK_PASSWORD="$CMUX_UITEST_STACK_PASSWORD" \
  SIMCTL_CHILD_CMUX_DEV_AUTH_REPLACE_SESSION="1" \
  SIMCTL_CHILD_CMUX_SIMULATOR_DEVICE_ID="$SIMULATOR_DEVICE_ID" \
  SIMCTL_CHILD_CMUX_UITEST_MOCK_DATA="0" \
  SIMCTL_CHILD_CMUX_DOGFOOD_ATTACH_URL="$ATTACH_URL" \
  SIMCTL_CHILD_CMUX_DOGFOOD_CLIENT_ID="$DOGFOOD_CLIENT_ID" \
  SIMCTL_CHILD_CMUX_IROH_RELEASE_GATE_MODE="$IROH_RELEASE_GATE_MODE" \
  SIMCTL_CHILD_CMUX_IROH_RELEASE_GATE_SCENARIO="${CMUX_IROH_RELEASE_GATE_SCENARIO:-standard}" \
  SIMCTL_CHILD_CMUX_IROH_DISABLE_RELAY_CREDENTIAL_REFRESH="${CMUX_IROH_DISABLE_RELAY_CREDENTIAL_REFRESH:-0}" \
    xcrun simctl "${launch_args[@]}" "$SIM_UDID" "$BUNDLE_ID"
else
  if [[ -z "$DEVICE_ID" ]]; then
    DEVICE_ID="$(xcrun devicectl list devices 2>/dev/null \
      | awk '/iPhone/ && !/unavailable/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9A-Fa-f-]{36}$/){print $i; exit}}')"
  fi
  [[ -n "$DEVICE_ID" ]] || { echo "error: no connected iPhone found (pass --device-id)" >&2; exit 1; }
  DOGFOOD_CLIENT_ID="$(cmux_attach_dogfood_client_id "$BUNDLE_ID" "$DEVICE_ID")"
  # Pass the password + attach URL via the DEVICECTL_CHILD_ prefix (calling-env
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
  DEVICECTL_CHILD_CMUX_DEV_AUTH_REPLACE_SESSION="1" \
  DEVICECTL_CHILD_CMUX_UITEST_MOCK_DATA="0" \
  DEVICECTL_CHILD_CMUX_DOGFOOD_ATTACH_URL="$ATTACH_URL" \
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

if [[ -n "$READINESS_CURSOR" && -z "$IROH_RELEASE_GATE_MODE" ]]; then
  if ! READY_EVENT="$(cmux_attach_wait_for_usable_session \
      "$TAG" \
      "$REPO_ROOT" \
      "$READINESS_CURSOR" \
      "$ATTACH_READY_TIMEOUT_SECONDS" \
      "$DOGFOOD_CLIENT_ID")"; then
    if [[ "$TARGET" == "device" ]]; then
      echo "error: iPhone auth gate FAILED: $BUNDLE_ID never reached a signed-in + paired session for profile $CMUX_DEV_AUTH_PROFILE ($CMUX_DEV_AUTH_ACCOUNT)" >&2
      echo "error: retry: $MDL_RETRY_CMD" >&2
    fi
    exit 1
  fi
  READINESS_FINISHED_MS="$(cmux_attach_monotonic_milliseconds)"
  READINESS_LATENCY_MS="$((READINESS_FINISHED_MS - READINESS_STARTED_MS))"
  GIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  if [[ "$TARGET" == "device" ]]; then
    RECEIPT_TARGET="physical_device"
    RECEIPT_TARGET_ID="$DEVICE_ID"
  else
    RECEIPT_TARGET="simulator_injection"
    RECEIPT_TARGET_ID="$SIM_UDID"
  fi
  RECEIPT_DIR="${CMUX_READINESS_RECEIPT_DIR:-/tmp/cmux-ios-dogfood-readiness}"
  RECEIPT_PATH="$RECEIPT_DIR/${slug}-$(cmux_attach__slug "$RECEIPT_TARGET_ID").json"
  cmux_attach_write_readiness_receipt \
    "$RECEIPT_PATH" \
    "$GIT_SHA" \
    "$TAG" \
    "$BUNDLE_ID" \
    "$RECEIPT_TARGET" \
    "$RECEIPT_TARGET_ID" \
    "$TAG" \
    "$(cmux_attach_socket_path "$TAG")" \
    "$READINESS_LATENCY_MS" \
    "${CMUX_DOGFOOD_LAUNCH_ATTEMPT_COUNT:-1}" \
    "$READY_EVENT"
  echo "==> usable RPC session established between $BUNDLE_ID and tagged Mac '$TAG'"
  echo "==> readiness receipt: $RECEIPT_PATH"
  if [[ "$TARGET" == "device" ]]; then
    echo "==> iPhone auth gate: PASS — $BUNDLE_ID on $DEVICE_ID verified profile $CMUX_DEV_AUTH_PROFILE ($CMUX_DEV_AUTH_ACCOUNT), signed in + paired"
  fi
elif [[ -n "$READINESS_CURSOR" ]]; then
  echo "==> release-gate app owns authenticated RPC readiness verification"
elif [[ "$TARGET" == "device" ]]; then
  # Only reachable with --no-attach + CMUX_ALLOW_UNAUTHENTICATED_INSTALL=1
  # (any other unverified device path already exited above). Say so loudly so
  # a handoff can never quote this run as an authenticated install.
  echo "==> iPhone auth gate: SKIPPED (CMUX_ALLOW_UNAUTHENTICATED_INSTALL=1) — $BUNDLE_ID is NOT verified signed in; check later with scripts/verify-iphone-auth.sh --tag $TAG --device-id $DEVICE_ID"
fi
