#!/usr/bin/env bash
# Launch a tagged cmux iOS DEV build fully signed in (and optionally paired to a
# running Mac), with NO human OAuth, so an agent can autonomously reproduce and
# dogfood on the simulator or a device.
#
# It reuses the app's existing DEBUG launch hooks:
#   CMUX_UITEST_STACK_EMAIL / CMUX_UITEST_STACK_PASSWORD  -> real Stack sign-in
#   CMUX_UITEST_MOCK_DATA=0                               -> real backend, not mock
#   CMUX_UITEST_ATTACH_URL=<cmux-ios://attach...>         -> auto-pair after sign-in
# (sim env via SIMCTL_CHILD_*, device env via DEVICECTL_CHILD_*).
#
# Credentials come from the environment or ~/.secrets/cmux.env (preferred) /
# ~/.secrets/cmuxterm-dev.env. Use a DEDICATED dev/agent Stack account, never a
# real user's primary login.
#
# Usage:
#   scripts/mobile-dev-launch.sh --tag grid [--simulator "iPhone 17"] [--attach]
#   scripts/mobile-dev-launch.sh --tag grid --device [--device-id <id>] [--attach]
#
#   --attach   also pair to the running Mac by minting a fresh attach ticket from
#              the mobile-attach QR server (default :17321). Requires that server
#              + the tagged Mac app to be running.

set -euo pipefail

TAG=""
TARGET="simulator"          # simulator | device
SIMULATOR_NAME="iPhone 17"
DEVICE_ID=""
ATTACH=0
QR_PORT="${CMUX_QR_PORT:-17321}"

usage() { sed -n '2,30p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --simulator) TARGET="simulator"; SIMULATOR_NAME="${2:-}"; shift 2 ;;
    --device) TARGET="device"; shift ;;
    --device-id) DEVICE_ID="${2:-}"; shift 2 ;;
    --attach) ATTACH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown arg $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$TAG" ]] || { echo "error: --tag is required" >&2; usage >&2; exit 2; }

# --- credentials ------------------------------------------------------------
load_secret_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  # Only pull the two keys we need; don't blanket-source arbitrary secrets.
  while IFS= read -r line; do
    case "$line" in
      CMUX_UITEST_STACK_EMAIL=*) : "${CMUX_UITEST_STACK_EMAIL:=${line#*=}}" ;;
      CMUX_UITEST_STACK_PASSWORD=*) : "${CMUX_UITEST_STACK_PASSWORD:=${line#*=}}" ;;
    esac
  done < "$f"
}
load_secret_file "$HOME/.secrets/cmux.env"
load_secret_file "$HOME/.secrets/cmuxterm-dev.env"

if [[ -z "${CMUX_UITEST_STACK_EMAIL:-}" || -z "${CMUX_UITEST_STACK_PASSWORD:-}" ]]; then
  cat >&2 <<EOF
error: no dev sign-in credentials found.

Set a DEDICATED dev/agent Stack account (not your primary login) in
~/.secrets/cmux.env:

  CMUX_UITEST_STACK_EMAIL=agent-dev@manaflow.ai
  CMUX_UITEST_STACK_PASSWORD=<password>

(or export them in the environment before running this script).
EOF
  exit 2
fi

# --- bundle id (matches ios/scripts/reload.sh sanitize_tag) ------------------
slug="$(echo "$TAG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
[[ -n "$slug" ]] || slug="dev"
BUNDLE_ID="dev.cmux.ios.$slug"

# --- optional fresh attach ticket -------------------------------------------
ATTACH_URL=""
if [[ "$ATTACH" -eq 1 ]]; then
  ATTACH_URL="$(curl -fsS -m 8 "http://127.0.0.1:${QR_PORT}/ticket.json" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("attach_url",""))' 2>/dev/null || true)"
  if [[ -z "$ATTACH_URL" ]]; then
    echo "warning: --attach requested but no ticket from :${QR_PORT} (is the QR server + tagged Mac app running?); launching signed-in only" >&2
  fi
fi

echo "==> launching $BUNDLE_ID on $TARGET (signed in as $CMUX_UITEST_STACK_EMAIL${ATTACH_URL:+, auto-pairing})"

if [[ "$TARGET" == "simulator" ]]; then
  SIM_UDID="$(xcrun simctl list devices booted 2>/dev/null | grep -F "$SIMULATOR_NAME" | grep -oE '[0-9A-F-]{36}' | head -1)"
  if [[ -z "$SIM_UDID" ]]; then
    echo "error: simulator '$SIMULATOR_NAME' is not booted (boot it or pass --simulator <name>)" >&2
    exit 1
  fi
  xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  SIMCTL_CHILD_CMUX_UITEST_STACK_EMAIL="$CMUX_UITEST_STACK_EMAIL" \
  SIMCTL_CHILD_CMUX_UITEST_STACK_PASSWORD="$CMUX_UITEST_STACK_PASSWORD" \
  SIMCTL_CHILD_CMUX_UITEST_MOCK_DATA="0" \
  SIMCTL_CHILD_CMUX_UITEST_ATTACH_URL="$ATTACH_URL" \
    xcrun simctl launch --console-pty "$SIM_UDID" "$BUNDLE_ID"
else
  if [[ -z "$DEVICE_ID" ]]; then
    DEVICE_ID="$(xcrun devicectl list devices 2>/dev/null \
      | awk '/iPhone/ && !/unavailable/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9A-Fa-f-]{36}$/){print $i; exit}}')"
  fi
  [[ -n "$DEVICE_ID" ]] || { echo "error: no connected iPhone found (pass --device-id)" >&2; exit 1; }
  ENV_JSON="$(CMUX_UITEST_STACK_EMAIL="$CMUX_UITEST_STACK_EMAIL" \
              CMUX_UITEST_STACK_PASSWORD="$CMUX_UITEST_STACK_PASSWORD" \
              ATTACH_URL="$ATTACH_URL" python3 -c '
import json, os
env = {
  "CMUX_UITEST_STACK_EMAIL": os.environ["CMUX_UITEST_STACK_EMAIL"],
  "CMUX_UITEST_STACK_PASSWORD": os.environ["CMUX_UITEST_STACK_PASSWORD"],
  "CMUX_UITEST_MOCK_DATA": "0",
}
if os.environ.get("ATTACH_URL"): env["CMUX_UITEST_ATTACH_URL"] = os.environ["ATTACH_URL"]
print(json.dumps(env))')"
  xcrun devicectl device process launch --terminate-existing \
    --device "$DEVICE_ID" --environment-variables "$ENV_JSON" "$BUNDLE_ID"
fi
