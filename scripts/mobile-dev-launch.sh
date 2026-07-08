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
#   scripts/mobile-dev-launch.sh --tag grid [--simulator "iPhone 17"] [--attach] [--detach]
#   scripts/mobile-dev-launch.sh --tag grid --device [--device-id <id>] [--attach]
#   scripts/mobile-dev-launch.sh --tag grid --agent  [--attach]
#
#   --attach   also pair to the running Mac. Uses CMUX_DOGFOOD_ATTACH_URL when it
#              is already set (as dev-setup.sh passes it), else mints a fresh
#              tag-scoped ticket directly against THIS tag's Mac debug socket
#              (never an untagged QR-server ticket, which could pair the wrong
#              Mac). Needs the tagged Mac app running with the pairing host
#              enabled (see --ensure-mac).
#   --ensure-mac  imply --attach and, before minting, enable the tagged Mac app's
#              pairing host + launch it if its debug socket is down. Lets a device
#              reload auto-pair with no separately-running Mac app.
#   --agent    sign in with the shared agent account instead of the dogfood one.
#   --detach   simulator only: launch without attaching stdio, so the app keeps
#              running after this script exits.

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
ATTACH_TTL_SECONDS="${CMUX_ATTACH_TTL_SECONDS:-600}"

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
    # --ensure-mac: before minting, enable the tagged Mac app's pairing host and
    # launch it if its debug socket is down, so --attach can mint without a
    # separately-running Mac app. Implies --attach.
    --ensure-mac) ENSURE_MAC=1; ATTACH=1; shift ;;
    --agent) AGENT=1; shift ;;
    --detach) DETACH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown arg $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$TAG" ]] || { echo "error: --tag is required" >&2; usage >&2; exit 2; }
if [[ "$DETACH" -eq 1 && "$TARGET" != "simulator" ]]; then
  echo "error: --detach is supported only with simulator launches" >&2
  usage >&2
  exit 2
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
# Fail closed on tags that have no alphanumerics: their slug would collapse onto
# the shared fallback identity and target an unrelated app/socket.
if ! cmux_attach_tag_has_alnum "$TAG"; then
  echo "error: --tag '$TAG' has no letters or digits; pick a tag with at least one alphanumeric character" >&2
  exit 2
fi
if [[ "$AGENT" -eq 1 ]]; then
  cmux_dev_secrets_load --agent || exit $?
else
  cmux_dev_secrets_load || exit $?
fi

# --- bundle id (matches ios/scripts/reload.sh sanitize_tag) ------------------
slug="$(cmux_attach__slug "$TAG")"
BUNDLE_ID="dev.cmux.ios.$slug"

# --- attach ticket ----------------------------------------------------------
# ATTACH_URL stays empty unless attach was explicitly requested, so a stale
# ambient CMUX_DOGFOOD_ATTACH_URL can NEVER auto-pair an unrequested launch
# (e.g. --no-attach from the reload scripts leaves ATTACH=0). The URL is injected
# as CMUX_DOGFOOD_ATTACH_URL, the NOT-mock-gated var the app reads with the real
# backend (CMUX_UITEST_MOCK_DATA=0).
ATTACH_URL=""
if [[ "$ATTACH" -eq 1 ]]; then
  # An attach URL the caller deliberately pre-minted (dev-setup.sh sets it +
  # --attach) wins. Ignore it under --ensure-mac, which is an explicit "(re)pair
  # to THIS tag's Mac" intent that must always mint fresh for this tag.
  if [[ "$ENSURE_MAC" -eq 0 ]]; then
    ATTACH_URL="${CMUX_DOGFOOD_ATTACH_URL:-}"
  fi
  if [[ -z "$ATTACH_URL" ]]; then
    if [[ "$ENSURE_MAC" -eq 1 ]]; then
      cmux_attach_ensure_mac "$TAG" "$REPO_ROOT" || true
    fi
    # Always mint tag-scoped from THIS tag's socket. Never consult the
    # tag-agnostic QR server: its /ticket.json has no tag parameter and is served
    # from whatever tag the QR server last set, so it could hand back a different
    # Mac's ticket and silently pair the phone to the wrong app.
    if cmux_attach_mac_socket_ready "$TAG"; then
      ATTACH_URL="$(cmux_attach_mint_url "$TAG" "$ATTACH_TTL_SECONDS" "$REPO_ROOT" || true)"
    fi
  fi
  if [[ -z "$ATTACH_URL" ]]; then
    if [[ "$ENSURE_MAC" -eq 1 ]]; then
      echo "warning: could not mint an attach ticket (the tagged Mac app's pairing listener may still be binding, or the macOS Local Network prompt is unanswered — click Allow, then re-run); launching signed-in only" >&2
    else
      echo "warning: --attach requested but no attach ticket could be minted (is the tagged Mac app for '$TAG' running with the pairing host enabled? try --ensure-mac); launching signed-in only" >&2
    fi
  fi
fi

# Never print the attach URL (bearer credential); just whether auto-pair is on.
echo "==> launching $BUNDLE_ID on $TARGET (signed in as $CMUX_UITEST_STACK_EMAIL${ATTACH_URL:+, auto-pairing})"

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
