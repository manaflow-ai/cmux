#!/usr/bin/env bash
# Independently notarize and staple the nested cmux Computer Use app.
#
# cmux copies this helper out of the signed host bundle before launch. An
# independent ticket keeps that copied app Gatekeeper-valid even when the Mac
# cannot contact Apple's notarization service. Stapling changes the nested
# bundle, so the outer cmux app is re-sealed afterward without re-signing the
# helper and discarding its ticket.

set -euo pipefail

usage() {
  cat <<EOF >&2
usage: $0 [--start <state-file> | --finish <state-file>] <signed-host-app> <host-entitlements> <signing-identity>

Without a phase flag, submit, wait, staple, and reseal synchronously.
--start uploads the signed helper and returns after persisting its submission.
--finish waits for that exact helper CDHash, staples it, and reseals the host.
EOF
}

MODE="run"
SUBMISSION_FILE=""
case "${1:-}" in
  --start|--finish)
    [ "$#" -ge 2 ] || { usage; exit 2; }
    MODE="${1#--}"
    SUBMISSION_FILE="$2"
    shift 2
    ;;
  -h|--help)
    usage
    exit 0
    ;;
esac

if [ "$#" -ne 3 ]; then
  usage
  exit 2
fi

APP_PATH="$1"
APP_ENTITLEMENTS="$2"
SIGNING_IDENTITY="$3"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DITTO_TOOL="${CMUX_DITTO_TOOL:-/usr/bin/ditto}"
XCRUN_TOOL="${CMUX_XCRUN_TOOL:-xcrun}"
CODESIGN_TOOL="${CMUX_CODESIGN_TOOL:-/usr/bin/codesign}"
SPCTL_TOOL="${CMUX_SPCTL_TOOL:-spctl}"
SIGN_BUNDLE_TOOL="${CMUX_SIGN_BUNDLE_TOOL:-$ROOT_DIR/scripts/sign-cmux-bundle.sh}"
HELPER_ENTITLEMENTS="${CMUX_HELPER_ENTITLEMENTS:-$ROOT_DIR/cmux-helper.entitlements}"
HELPER_PATH="$APP_PATH/Contents/Library/cmux Computer Use.app"

if [ ! -d "$APP_PATH/Contents" ]; then
  echo "Signed host app not found: $APP_PATH" >&2
  exit 1
fi
if [ ! -d "$HELPER_PATH/Contents" ]; then
  echo "Nested cmux Computer Use app not found: $HELPER_PATH" >&2
  exit 1
fi
if [ ! -f "$APP_ENTITLEMENTS" ]; then
  echo "Host entitlements not found: $APP_ENTITLEMENTS" >&2
  exit 1
fi
if [ ! -f "$HELPER_ENTITLEMENTS" ]; then
  echo "Computer Use helper entitlements not found: $HELPER_ENTITLEMENTS" >&2
  exit 1
fi
if [ -z "${APPLE_ID:-}" ] \
  || [ -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" ] \
  || [ -z "${APPLE_TEAM_ID:-}" ]; then
  echo "Missing notarization secrets (APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID)" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

HELPER_ZIP="$TMP_DIR/cmux-cua-notary.zip"
STANDALONE_DIR="$TMP_DIR/standalone"
STANDALONE_HELPER="$STANDALONE_DIR/cmux Computer Use.app"

helper_cdhash() {
  "$CODESIGN_TOOL" -d --verbose=4 "$HELPER_PATH" 2>&1 \
    | awk -F= '/^CDHash=/ { print $2; exit }'
}

submission_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' \
    "$SUBMISSION_FILE"
}

start_submission() {
  local submit_json submit_id submit_status submitted_cdhash state_tmp
  if [ -e "$SUBMISSION_FILE" ]; then
    echo "Refusing to overwrite Computer Use notarization state: $SUBMISSION_FILE" >&2
    exit 1
  fi
  if [ ! -d "$(dirname "$SUBMISSION_FILE")" ]; then
    echo "Computer Use notarization state directory does not exist: $(dirname "$SUBMISSION_FILE")" >&2
    exit 1
  fi

  # Give the helper its final Developer ID signature before upload. Later host
  # signing must use all-except-computer-use so this exact CDHash survives until
  # finish staples the ticket and re-seals only the outer app.
  "$CODESIGN_TOOL" \
    --force \
    --options runtime \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "$HELPER_ENTITLEMENTS" \
    "$HELPER_PATH"
  "$CODESIGN_TOOL" --verify --strict --verbose=2 "$HELPER_PATH"
  submitted_cdhash="$(helper_cdhash)"
  if [ -z "$submitted_cdhash" ]; then
    echo "Could not resolve Computer Use helper CDHash before notarization" >&2
    exit 1
  fi
  "$DITTO_TOOL" -c -k --sequesterRsrc --keepParent "$HELPER_PATH" "$HELPER_ZIP"

  submit_json="$("$XCRUN_TOOL" notarytool submit "$HELPER_ZIP" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --output-format json)"
  submit_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$submit_json")"
  submit_status="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", "unknown"))' <<<"$submit_json")"
  if [ -z "$submit_id" ]; then
    echo "Computer Use helper notarization returned no submission ID" >&2
    exit 1
  fi

  state_tmp="$SUBMISSION_FILE.tmp.$$"
  umask 077
  {
    printf 'submission_id=%s\n' "$submit_id"
    printf 'cdhash=%s\n' "$submitted_cdhash"
  } > "$state_tmp"
  /bin/mv "$state_tmp" "$SUBMISSION_FILE"
  echo "Computer Use helper notarization submitted: $submit_id ($submit_status)"
}

finish_submission() {
  local submit_id submitted_cdhash current_cdhash wait_json wait_status submit_status
  if [ ! -f "$SUBMISSION_FILE" ]; then
    echo "Computer Use notarization state not found: $SUBMISSION_FILE" >&2
    exit 1
  fi
  submit_id="$(submission_value submission_id)"
  submitted_cdhash="$(submission_value cdhash)"
  if [ -z "$submit_id" ] || [ -z "$submitted_cdhash" ]; then
    echo "Computer Use notarization state is incomplete: $SUBMISSION_FILE" >&2
    exit 1
  fi

  current_cdhash="$(helper_cdhash)"
  if [ "$current_cdhash" != "$submitted_cdhash" ]; then
    echo "Computer Use helper changed after notarization submission" >&2
    echo "  submitted CDHash: $submitted_cdhash" >&2
    echo "  current CDHash:   ${current_cdhash:-<missing>}" >&2
    exit 1
  fi

  set +e
  wait_json="$("$XCRUN_TOOL" notarytool wait "$submit_id" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --output-format json)"
  wait_status=$?
  set -e
  if [ -n "$wait_json" ]; then
    submit_status="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", "unknown"))' <<<"$wait_json")"
  else
    submit_status="unknown"
  fi
  if [ "$wait_status" -ne 0 ] || [ "$submit_status" != "Accepted" ]; then
    echo "Computer Use helper notarization failed with status: $submit_status (wait exit $wait_status)" >&2
    "$XCRUN_TOOL" notarytool log "$submit_id" \
      --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_SPECIFIC_PASSWORD" || true
    exit 1
  fi

  "$XCRUN_TOOL" notarytool log "$submit_id" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD"
  "$XCRUN_TOOL" stapler staple "$HELPER_PATH"
  "$XCRUN_TOOL" stapler validate "$HELPER_PATH"
  "$CODESIGN_TOOL" --verify --strict --verbose=2 "$HELPER_PATH"

  # Validate the same shape the runtime launches: a standalone copy outside the
  # host app. This also proves that the stapled ticket survives the copy.
  mkdir -p "$STANDALONE_DIR"
  "$DITTO_TOOL" "$HELPER_PATH" "$STANDALONE_HELPER"
  "$XCRUN_TOOL" stapler validate "$STANDALONE_HELPER"
  "$CODESIGN_TOOL" --verify --strict --verbose=2 "$STANDALONE_HELPER"
  "$SPCTL_TOOL" -a -vv --type execute "$STANDALONE_HELPER"

  # Stapling the nested app changes the host's resource seal. Re-sign only the
  # outer app: re-signing nested code here would discard the helper's ticket.
  CMUX_SIGN_MODE=main-only \
    "$SIGN_BUNDLE_TOOL" "$APP_PATH" "$APP_ENTITLEMENTS" "$SIGNING_IDENTITY"
  "$CODESIGN_TOOL" --verify --deep --strict --verbose=2 "$APP_PATH"
  "$XCRUN_TOOL" stapler validate "$HELPER_PATH"
  rm -f "$SUBMISSION_FILE"

  echo "Computer Use helper notarized and stapled: $HELPER_PATH"
}

case "$MODE" in
  start)
    start_submission
    ;;
  finish)
    finish_submission
    ;;
  run)
    SUBMISSION_FILE="$TMP_DIR/submission.state"
    start_submission
    finish_submission
    ;;
esac
