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
#              ticket from the mobile-attach QR server (default :17321). Requires
#              that server + the tagged Mac app to be running.
#   --agent    sign in with the shared agent account instead of the dogfood one.
#   --detach   simulator only: launch without attaching stdio, so the app keeps
#              running after this script exits.

set -euo pipefail

TAG=""
TARGET="simulator"          # simulator | device
SIMULATOR_NAME="iPhone 17"
DEVICE_ID=""
ATTACH=0
AGENT=0
DETACH=0
QR_PORT="${CMUX_QR_PORT:-17321}"

usage() { sed -n '2,30p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --simulator) TARGET="simulator"; SIMULATOR_NAME="${2:-}"; shift 2 ;;
    --device) TARGET="device"; shift ;;
    --device-id) DEVICE_ID="${2:-}"; shift 2 ;;
    --attach) ATTACH=1; shift ;;
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
# shellcheck source=scripts/lib/dev-secrets.sh
source "$SCRIPT_DIR/lib/dev-secrets.sh"
if [[ "$AGENT" -eq 1 ]]; then
  cmux_dev_secrets_load --agent || exit $?
else
  cmux_dev_secrets_load || exit $?
fi

# --- bundle id (matches ios/scripts/reload.sh sanitize_tag) ------------------
slug="$(echo "$TAG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
[[ -n "$slug" ]] || slug="dev"
BUNDLE_ID="dev.cmux.ios.$slug"

# --- attach ticket ----------------------------------------------------------
# Prefer a pre-minted CMUX_DOGFOOD_ATTACH_URL (dev-setup.sh sets it directly,
# so no QR server is needed). With --attach and no pre-set URL, mint a fresh one
# from the mobile-attach QR server. Inject it as CMUX_DOGFOOD_ATTACH_URL, the
# NOT-mock-gated env var the app reads with the real backend (CMUX_UITEST_MOCK_DATA=0).
ATTACH_URL="${CMUX_DOGFOOD_ATTACH_URL:-}"
if [[ -z "$ATTACH_URL" && "$ATTACH" -eq 1 ]]; then
  ATTACH_URL="$(curl -fsS -m 8 "http://127.0.0.1:${QR_PORT}/ticket.json" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("attach_url",""))' 2>/dev/null || true)"
  if [[ -z "$ATTACH_URL" ]]; then
    echo "warning: --attach requested but no ticket from :${QR_PORT} (is the QR server + tagged Mac app running?); launching signed-in only" >&2
  fi
fi

# Never print the attach URL (bearer credential); just whether auto-pair is on.
echo "==> launching $BUNDLE_ID on $TARGET (signed in as $CMUX_UITEST_STACK_EMAIL${ATTACH_URL:+, auto-pairing})"

if [[ "$TARGET" == "simulator" ]]; then
  SIM_UDID="$(xcrun simctl list devices booted 2>/dev/null | grep -F "$SIMULATOR_NAME" | grep -oE '[0-9A-F-]{36}' | head -1)"
  if [[ -z "$SIM_UDID" ]]; then
    echo "error: simulator '$SIMULATOR_NAME' is not booted (boot it or pass --simulator <name>)" >&2
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
