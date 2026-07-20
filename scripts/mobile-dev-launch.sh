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
# Credentials are loaded by scripts/lib/dev-secrets.sh: the personal dogfood
# account (~/.secrets/cmuxterm-dev.env) wins by default; --agent forces the
# shared agent account (~/.secrets/cmux.env).
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
#              reload auto-pair with no separately-running Mac app.
#   --no-attach  launch signed in without pairing. Also cancels --ensure-mac.
#              When attach flags are repeated, the last flag wins.
#   --agent    sign in with the shared agent account instead of the dogfood one.
#   --detach   simulator only: launch without attaching stdio, so the app keeps
#              running after this script exits.
#   --iroh-release-gate <automatic|relayOnly|directOnly>
#              simulator only: run the credential-free Iroh release-gate probe
#              after sign-in and attach.
#   --credentials-file <absolute-path>
#              load one 0600 credential file exclusively. Intended for an
#              isolated temporary production release-gate account.

set -euo pipefail

TAG=""
TARGET="simulator"          # simulator | device
SIMULATOR_NAME="iPhone 17"
SIMULATOR_ID=""             # exact booted sim UDID (wins over name when set)
DEVICE_ID=""
ATTACH=0
ENSURE_MAC=0
AGENT=0
DETACH=0
IROH_RELEASE_GATE_MODE=""
AUTH_CREDENTIALS_FILE=""
ATTACH_TTL_SECONDS="${CMUX_ATTACH_TTL_SECONDS:-600}"
ATTACH_MINT_MAX_ATTEMPTS="${CMUX_ATTACH_MINT_MAX_ATTEMPTS:-20}"

usage() { sed -n '2,30p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --simulator) TARGET="simulator"; SIMULATOR_NAME="${2:-}"; shift 2 ;;
    # Exact booted simulator UDID; wins over --simulator name so callers that
    # already resolved/installed onto a specific sim launch on THAT one.
    --simulator-id) TARGET="simulator"; SIMULATOR_ID="${2:-}"; shift 2 ;;
    --device) TARGET="device"; shift ;;
    --device-id) DEVICE_ID="${2:-}"; shift 2 ;;
    --attach) ATTACH=1; shift ;;
    --no-attach) ATTACH=0; ENSURE_MAC=0; shift ;;
    # --ensure-mac: before minting, enable the tagged Mac app's pairing host and
    # launch it if its debug socket is down, so --attach can mint without a
    # separately-running Mac app. Implies --attach.
    --ensure-mac) ENSURE_MAC=1; ATTACH=1; shift ;;
    --agent) AGENT=1; shift ;;
    --detach) DETACH=1; shift ;;
    --iroh-release-gate) IROH_RELEASE_GATE_MODE="${2:-}"; shift 2 ;;
    --credentials-file) AUTH_CREDENTIALS_FILE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown arg $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$TAG" ]] || { echo "error: --tag is required" >&2; usage >&2; exit 2; }
if [[ ! "$ATTACH_MINT_MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: CMUX_ATTACH_MINT_MAX_ATTEMPTS must be a positive integer" >&2
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

# --- credentials ------------------------------------------------------------
# Dogfood account wins over the agent account so iOS dev builds sign in as the
# human dogfooder by default. Pass --agent for agent-driven flows.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/dev-secrets.sh
source "$SCRIPT_DIR/lib/dev-secrets.sh"
# shellcheck source=scripts/lib/mobile-attach.sh
source "$SCRIPT_DIR/lib/mobile-attach.sh"
# Fail before loading credentials or touching a simulator/device if the tag
# would collide with a fallback/reserved identity or exceed the cloud limit.
if ! cmux_attach_validate_dev_tag "$TAG"; then
  exit 2
fi
if [[ -n "$AUTH_CREDENTIALS_FILE" ]]; then
  cmux_dev_secrets_load --credentials-file "$AUTH_CREDENTIALS_FILE" || exit $?
elif [[ "$AGENT" -eq 1 ]]; then
  cmux_dev_secrets_load --agent || exit $?
else
  cmux_dev_secrets_load || exit $?
fi

# --- bundle id (matches ios/scripts/reload.sh sanitize_tag) ------------------
slug="$(cmux_attach__slug "$TAG")"
BUNDLE_ID="dev.cmux.ios.$slug"
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
    cmux_attach_ensure_mac "$TAG" "$REPO_ROOT" "$ATTACH_TARGET" || true
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
      echo "warning: could not mint an attach ticket (the tagged Mac app's pairing listener may still be binding, or the macOS Local Network prompt is unanswered; click Allow, then re-run); launching signed-in only" >&2
    else
      echo "warning: --attach requested but no attach ticket could be minted (is the tagged Mac app for '$TAG' running with the pairing host enabled? try --ensure-mac); launching signed-in only" >&2
    fi
  fi
fi

# Never print the attach URL (bearer credential). One-shot production-account
# identities are redacted too; ordinary dogfood launches retain their existing
# account label so developers can detect accidental account selection.
SIGN_IN_ACCOUNT_LABEL="$CMUX_UITEST_STACK_EMAIL"
if [[ -n "$AUTH_CREDENTIALS_FILE" ]]; then
  SIGN_IN_ACCOUNT_LABEL="[redacted]"
fi
echo "==> launching $BUNDLE_ID on $TARGET (signed in as $SIGN_IN_ACCOUNT_LABEL${ATTACH_URL:+, auto-pairing})"

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
  xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  launch_args=(launch)
  if [[ "$DETACH" -ne 1 ]]; then
    launch_args+=(--console-pty)
  fi
  SIMCTL_CHILD_CMUX_UITEST_STACK_EMAIL="$CMUX_UITEST_STACK_EMAIL" \
  SIMCTL_CHILD_CMUX_UITEST_STACK_PASSWORD="$CMUX_UITEST_STACK_PASSWORD" \
  SIMCTL_CHILD_CMUX_UITEST_MOCK_DATA="0" \
  SIMCTL_CHILD_CMUX_DOGFOOD_ATTACH_URL="$ATTACH_URL" \
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
  # Pass the password + attach URL via the DEVICECTL_CHILD_ prefix (calling-env
  # injection), NOT --environment-variables, which would expose these bearer
  # credentials in argv. devicectl strips DEVICECTL_CHILD_<NAME> from its own
  # environment and forwards it to the app as <NAME>, mirroring the simulator's
  # SIMCTL_CHILD_ path. This is documented in `devicectl device process launch
  # --help` (518.31): "set them in the calling environment with a DEVICECTL_CHILD_
  # prefix", and the -e note "Using the environment-variables flag will override
  # the caller environment variables prefixed with DEVICECTL_CHILD_".
  DEVICECTL_CHILD_CMUX_UITEST_STACK_EMAIL="$CMUX_UITEST_STACK_EMAIL" \
  DEVICECTL_CHILD_CMUX_UITEST_STACK_PASSWORD="$CMUX_UITEST_STACK_PASSWORD" \
  DEVICECTL_CHILD_CMUX_UITEST_MOCK_DATA="0" \
  DEVICECTL_CHILD_CMUX_DOGFOOD_ATTACH_URL="$ATTACH_URL" \
    xcrun devicectl device process launch --terminate-existing \
      --device "$DEVICE_ID" "$BUNDLE_ID"
fi
