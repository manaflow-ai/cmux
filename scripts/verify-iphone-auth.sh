#!/usr/bin/env bash
# Post-install auth gate for a tagged cmux iOS DEV build on a physical iPhone.
# Answers programmatically, with no screenshots: "is this tagged build on the
# phone signed in and paired to its tagged Mac right now?"
#
# Mechanism (persisted-state probe): relaunch the installed app WITHOUT
# injecting credentials or an attach ticket, then wait for the tagged Mac to
# publish its `mobile.rpc.ready` event carrying this device's deterministic
# dogfood client id. The Mac emits that event only after the app completes a
# workspace.list AND holds a live event subscription with workspace+terminal
# topics over the paired route (Sources/Mobile/MobileHostService.swift), which
# a signed-out or unpaired install can never reach from the login screen.
# Because the relaunch injects nothing, only PERSISTED sign-in/pairing state
# can pass, so this detects exactly the installed-but-signed-out builds that
# raw `devicectl device install app` or CMUX_ALLOW_UNAUTHENTICATED_INSTALL
# produce.
#
# App-receipt mode (apps whose Info.plist declares CMUXDogfoodReadiness =
# app-receipt-v1): no tagged Mac takes part. The credential-free relaunch
# injects only the client id and a fresh CMUX_DOGFOOD_READINESS_NONCE; the app
# must then publish a receipt in its data container with that nonce, the
# selected account, and session_source "restored". A fresh sign-in cannot
# pass, so this still proves PERSISTED sign-in.
#
# Usage:
#   scripts/verify-iphone-auth.sh --tag <tag> [--device-id <id>] [--timeout <s>]
#       [--auth-profile personal] [--expected-account <email>]
#       [--credentials-file <path>] [--readiness mac-rpc|app-receipt|auto]
#
# Device id defaults to CMUX_IPHONE_DEVICE_ID, then the first line of
# ~/.config/cmux/iphone-device-id. Timeout defaults to
# CMUX_VERIFY_IPHONE_AUTH_TIMEOUT_SECONDS or 45 (a plain relaunch must rebuild
# its broker discovery + Iroh route before the RPC session is usable); the
# app-receipt mode defaults to CMUX_APP_RECEIPT_TIMEOUT_SECONDS or 90.
# --readiness auto (default) reads CMUXDogfoodReadiness from
# CMUX_INSTALLED_APP_PATH when set, else reuses the mode recorded in this
# tag+device's last launcher readiness receipt, else mac-rpc.
#
# Prints exactly one final PASS:/FAIL: line on stdout; FAIL includes the
# reason and the exact retry command. Exit 0 PASS, 1 FAIL, 2 usage/environment.
set -euo pipefail

TAG=""
DEVICE_ID=""
TIMEOUT="${CMUX_VERIFY_IPHONE_AUTH_TIMEOUT_SECONDS:-45}"
TIMEOUT_EXPLICIT=0
READINESS_REQUEST="auto"
AUTH_PROFILE="personal"
EXPECTED_ACCOUNT=""
AUTH_CREDENTIALS_FILE="${CMUX_IOS_DOGFOOD_CREDENTIALS_FILE:-$HOME/.secrets/cmuxterm-dev.env}"

usage() { sed -n '2,38p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --device-id) DEVICE_ID="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; TIMEOUT_EXPLICIT=1; shift 2 ;;
    --auth-profile) AUTH_PROFILE="${2:-}"; shift 2 ;;
    --expected-account) EXPECTED_ACCOUNT="${2:-}"; shift 2 ;;
    --credentials-file) AUTH_CREDENTIALS_FILE="${2:-}"; shift 2 ;;
    --readiness) READINESS_REQUEST="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown arg $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$TAG" ]] || { echo "error: --tag is required" >&2; usage >&2; exit 2; }
if [[ ! "$TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: --timeout must be a positive integer" >&2
  exit 2
fi
case "$READINESS_REQUEST" in
  auto|mac-rpc|app-receipt) ;;
  *) echo "error: --readiness must be mac-rpc, app-receipt, or auto" >&2; exit 2 ;;
esac
# This gate proves persisted auth on the user's physical iPhone. The shared
# agent profile is intentionally simulator-only; fail closed before loading
# credentials or probing the device/Mac.
if [[ "$AUTH_PROFILE" != "personal" ]]; then
  echo "error: physical iPhone auth verification requires --auth-profile personal (agent is simulator-only)" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/mobile-attach.sh
source "$SCRIPT_DIR/lib/mobile-attach.sh"
# shellcheck source=scripts/lib/dev-secrets.sh
source "$SCRIPT_DIR/lib/dev-secrets.sh"
cmux_attach_validate_dev_tag "$TAG" || exit 2
credential_args=(--profile "$AUTH_PROFILE" --credentials-file "$AUTH_CREDENTIALS_FILE")
[[ -n "$EXPECTED_ACCOUNT" ]] && credential_args+=(--expected-account "$EXPECTED_ACCOUNT")
cmux_dev_secrets_load "${credential_args[@]}" >/dev/null || exit $?
EXPECTED_ACCOUNT="$CMUX_DEV_AUTH_ACCOUNT"
unset CMUX_UITEST_STACK_EMAIL CMUX_UITEST_STACK_PASSWORD

SLUG="$(cmux_attach__slug "$TAG")"
BUNDLE_ID="dev.cmux.ios.$SLUG"

if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="${CMUX_IPHONE_DEVICE_ID:-}"
fi
if [[ -z "$DEVICE_ID" ]]; then
  device_id_file="${CMUX_CONFIG_DIR:-$HOME/.config/cmux}/iphone-device-id"
  if [[ -f "$device_id_file" ]]; then
    DEVICE_ID="$(head -n1 "$device_id_file" | tr -d '[:space:]')"
  fi
fi
if [[ -z "$DEVICE_ID" ]]; then
  echo "error: no device id (pass --device-id, set CMUX_IPHONE_DEVICE_ID, or write ~/.config/cmux/iphone-device-id)" >&2
  exit 2
fi

RECEIPT_DIR="${CMUX_READINESS_RECEIPT_DIR:-/tmp/cmux-ios-dogfood-readiness}"
RECEIPT_PATH="$RECEIPT_DIR/${SLUG}-$(cmux_attach__slug "$DEVICE_ID").json"

# --- readiness mode -------------------------------------------------------------
READINESS_MODE="$READINESS_REQUEST"
READINESS_HINT=""
if [[ "$READINESS_MODE" == "auto" ]]; then
  if [[ -n "${CMUX_INSTALLED_APP_PATH:-}" && -f "${CMUX_INSTALLED_APP_PATH}/Info.plist" ]]; then
    READINESS_MODE="$(cmux_attach_app_readiness_mode "$CMUX_INSTALLED_APP_PATH")" || exit 2
  elif [[ -f "$RECEIPT_PATH" ]] && RECORDED_MODE="$(/usr/bin/python3 - "$RECEIPT_PATH" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        receipt = json.load(stream)
except (OSError, ValueError):
    raise SystemExit(1)
print("app-receipt" if isinstance(receipt, dict) and receipt.get("readiness") == "app-receipt" else "mac-rpc")
PY
  )"; then
    READINESS_MODE="$RECORDED_MODE"
  else
    READINESS_MODE="mac-rpc"
    READINESS_HINT="readiness mode guessed as mac-rpc (no installed app path or launcher receipt); for a build that declares CMUXDogfoodReadiness, rerun with --readiness app-receipt"
  fi
fi
if [[ "$READINESS_MODE" == "app-receipt" && "$TIMEOUT_EXPLICIT" -eq 0 ]]; then
  TIMEOUT="${CMUX_APP_RECEIPT_TIMEOUT_SECONDS:-90}"
  if [[ ! "$TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: CMUX_APP_RECEIPT_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 2
  fi
fi

printf -v AUTH_CREDENTIALS_FILE_QUOTED '%q' "$AUTH_CREDENTIALS_FILE"
if [[ "$READINESS_MODE" == "app-receipt" ]]; then
  RETRY_CMD="scripts/mobile-dev-launch.sh --tag $TAG --device --device-id $DEVICE_ID --readiness app-receipt --auth-profile $AUTH_PROFILE --expected-account $EXPECTED_ACCOUNT --credentials-file $AUTH_CREDENTIALS_FILE_QUOTED"
  VERIFIED_STATE="signed in"
else
  RETRY_CMD="scripts/mobile-dev-launch.sh --tag $TAG --device --device-id $DEVICE_ID --ensure-mac --auth-profile $AUTH_PROFILE --expected-account $EXPECTED_ACCOUNT --credentials-file $AUTH_CREDENTIALS_FILE_QUOTED"
  VERIFIED_STATE="signed in + paired"
fi

fail() {
  local reason="$1"
  printf 'FAIL: %s on %s is NOT verified %s\n' "$BUNDLE_ID" "$DEVICE_ID" "$VERIFIED_STATE"
  printf 'reason: %s\n' "$reason"
  [[ -z "$READINESS_HINT" ]] || printf 'hint: %s\n' "$READINESS_HINT"
  printf 'retry: %s\n' "$RETRY_CMD"
  exit 1
}

# --- device + app preconditions ----------------------------------------------
APPS_JSON="$(mktemp "${TMPDIR:-/tmp}/cmux-verify-auth-apps.XXXXXX")"
trap 'rm -f "$APPS_JSON"' EXIT
if ! xcrun devicectl device info apps \
    --device "$DEVICE_ID" --json-output "$APPS_JSON" >/dev/null 2>&1; then
  fail "iPhone $DEVICE_ID is unreachable (asleep, off network, or unpaired)"
fi
if ! BUNDLE_ID="$BUNDLE_ID" /usr/bin/python3 - "$APPS_JSON" <<'PY'
import json, os, sys
want = os.environ["BUNDLE_ID"]
try:
    data = json.load(open(sys.argv[1]))
except ValueError:
    raise SystemExit(1)
for app in data.get("result", {}).get("apps", []):
    if app.get("bundleIdentifier") == want:
        raise SystemExit(0)
raise SystemExit(1)
PY
then
  fail "$BUNDLE_ID is not installed on the phone (install first: ios/scripts/reload-cloud.sh --tag $TAG --device-id $DEVICE_ID)"
fi

# --- app-receipt mode: the app proves its persisted sign-in itself --------------
if [[ "$READINESS_MODE" == "app-receipt" ]]; then
  EXPECTED_CLIENT_ID="$(cmux_attach_dogfood_client_id "$BUNDLE_ID" "$DEVICE_ID")"
  READINESS_NONCE="$(cmux_attach_readiness_nonce)"
  [[ -n "$READINESS_NONCE" ]] || fail "could not create a readiness nonce"
  STARTED_MS="$(cmux_attach_monotonic_milliseconds)"
  # Credential-free relaunch: only the client id and a fresh nonce. A replaced
  # session or injected credentials would turn this probe into a fresh sign-in.
  if ! env -u DEVICECTL_CHILD_CMUX_UITEST_STACK_EMAIL \
          -u DEVICECTL_CHILD_CMUX_UITEST_STACK_PASSWORD \
          -u DEVICECTL_CHILD_CMUX_DOGFOOD_ATTACH_URL \
          -u DEVICECTL_CHILD_CMUX_DEV_AUTH_REPLACE_SESSION \
          DEVICECTL_CHILD_CMUX_DOGFOOD_CLIENT_ID="$EXPECTED_CLIENT_ID" \
          DEVICECTL_CHILD_CMUX_DOGFOOD_READINESS_NONCE="$READINESS_NONCE" \
          DEVICECTL_CHILD_CMUX_UITEST_MOCK_DATA=0 \
          xcrun devicectl device process launch --terminate-existing \
          --device "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1; then
    fail "could not relaunch $BUNDLE_ID (device locked? unlock the iPhone and rerun)"
  fi
  RECEIPT_ERR="$(mktemp "${TMPDIR:-/tmp}/cmux-verify-auth-receipt.XXXXXX")"
  trap 'rm -f "$APPS_JSON" "$RECEIPT_ERR"' EXIT
  if ! APP_RECEIPT_JSON="$(cmux_attach_wait_for_app_receipt \
      physical_device "$DEVICE_ID" "$BUNDLE_ID" "$READINESS_NONCE" \
      "$EXPECTED_CLIENT_ID" "$EXPECTED_ACCOUNT" restored "$TIMEOUT" \
      2>"$RECEIPT_ERR")"; then
    fail "no restored signed-in app receipt within ${TIMEOUT}s of a credential-free relaunch: $(sed 's/^error: //' "$RECEIPT_ERR" | head -n1)"
  fi
  LATENCY_MS="$(($(cmux_attach_monotonic_milliseconds) - STARTED_MS))"
  GIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  INSTALLED_BUNDLE_METADATA="$(cmux_attach_installed_bundle_metadata \
    physical_device "$DEVICE_ID" "$BUNDLE_ID" 2>/dev/null || true)"
  if cmux_attach_write_app_readiness_receipt \
      "$RECEIPT_PATH" "$GIT_SHA" "$TAG" "$BUNDLE_ID" \
      physical_device "$DEVICE_ID" "$LATENCY_MS" 1 \
      "$APP_RECEIPT_JSON" "$INSTALLED_BUNDLE_METADATA" 2>/dev/null; then
    echo "==> readiness receipt: $RECEIPT_PATH" >&2
  else
    echo "warning: verification passed but the readiness receipt could not be persisted at $RECEIPT_PATH; this PASS exit code is authoritative, receipt-consuming automation will not see this run" >&2
  fi
  printf 'PASS: %s on %s is signed in as profile %s (%s), restored session proven by app receipt in %sms\n' \
    "$BUNDLE_ID" "$DEVICE_ID" "$AUTH_PROFILE" "$EXPECTED_ACCOUNT" "$LATENCY_MS"
  exit 0
fi

# --- tagged Mac must be observable -------------------------------------------
# The proof is an event on the tagged Mac's debug socket, so the Mac app must
# be running. A plain launch is enough (no pairing-host arming or ticket
# minting: the phone must reconnect from persisted state on its own).
if ! cmux_attach_mac_socket_ready "$TAG"; then
  MAC_APP="$(cmux_attach_mac_app_path "$TAG")"
  if [[ ! -d "$MAC_APP" ]]; then
    fail "tagged Mac '$TAG' is not running and no local build exists (build it: ./scripts/reload-cloud.sh --tag $TAG, then rerun)"
  fi
  echo "==> launching tagged Mac app so the readiness event stream is observable ($TAG)" >&2
  open -g "$MAC_APP" >/dev/null 2>&1 || open "$MAC_APP" >/dev/null 2>&1 || true
  for _i in $(seq 1 60); do
    cmux_attach_mac_socket_ready "$TAG" && break
    sleep 0.2
  done
  cmux_attach_mac_socket_ready "$TAG" \
    || fail "tagged Mac '$TAG' did not bind its debug socket after launch"
fi
if ! cmux_attach_wait_for_mac_auth_account "$TAG" "$REPO_ROOT" "$EXPECTED_ACCOUNT"; then
  fail "tagged Mac '$TAG' is not authenticated as the selected $AUTH_PROFILE account ($EXPECTED_ACCOUNT)"
fi

if ! READINESS_CURSOR="$(cmux_attach_readiness_cursor "$TAG" "$REPO_ROOT")"; then
  fail "could not read the tagged Mac's event stream (socket up but not answering)"
fi

# --- credential-free relaunch -------------------------------------------------
# Inject ONLY the deterministic client id (needed to attribute the readiness
# event to this exact phone+bundle; it is not a secret and the app persists it
# anyway). Explicitly drop any ambient credential/ticket injection so a caller
# that exports DEVICECTL_CHILD_* cannot turn this probe into a fresh sign-in.
EXPECTED_CLIENT_ID="$(cmux_attach_dogfood_client_id "$BUNDLE_ID" "$DEVICE_ID")"
STARTED_MS="$(cmux_attach_monotonic_milliseconds)"
if ! env -u DEVICECTL_CHILD_CMUX_UITEST_STACK_EMAIL \
        -u DEVICECTL_CHILD_CMUX_UITEST_STACK_PASSWORD \
        -u DEVICECTL_CHILD_CMUX_DOGFOOD_ATTACH_URL \
        DEVICECTL_CHILD_CMUX_DOGFOOD_CLIENT_ID="$EXPECTED_CLIENT_ID" \
        xcrun devicectl device process launch --terminate-existing \
        --device "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1; then
  fail "could not relaunch $BUNDLE_ID (device locked? unlock the iPhone and rerun)"
fi

if ! READY_EVENT="$(cmux_attach_wait_for_usable_session \
    "$TAG" "$REPO_ROOT" "$READINESS_CURSOR" "$TIMEOUT" "$EXPECTED_CLIENT_ID" \
    2>/dev/null)"; then
  fail "no usable RPC session within ${TIMEOUT}s of a credential-free relaunch: the app is signed out, unpaired, or its Mac route is down"
fi
LATENCY_MS="$(($(cmux_attach_monotonic_milliseconds) - STARTED_MS))"

# Durable secret-free proof, same schema and path as a mobile-dev-launch gate
# pass, so downstream automation has ONE receipt location to check.
GIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
if cmux_attach_write_readiness_receipt \
    "$RECEIPT_PATH" "$GIT_SHA" "$TAG" "$BUNDLE_ID" \
    "physical_device" "$DEVICE_ID" "$TAG" \
    "$(cmux_attach_socket_path "$TAG")" \
    "$LATENCY_MS" 1 "$READY_EVENT" 2>/dev/null; then
  echo "==> readiness receipt: $RECEIPT_PATH" >&2
else
  echo "warning: verification passed but the readiness receipt could not be persisted at $RECEIPT_PATH; this PASS exit code is authoritative, receipt-consuming automation will not see this run" >&2
fi

printf 'PASS: %s on %s is signed in + paired as profile %s (%s), usable RPC session with tagged Mac '\''%s'\'' in %sms\n' \
  "$BUNDLE_ID" "$DEVICE_ID" "$AUTH_PROFILE" "$EXPECTED_ACCOUNT" "$TAG" "$LATENCY_MS"
