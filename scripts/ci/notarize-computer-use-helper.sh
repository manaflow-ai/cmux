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
--finish waits for that exact helper slice set, staples it, and reseals the host.
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
# shellcheck source=lib/notarization-ticket.sh
source "$ROOT_DIR/scripts/ci/lib/notarization-ticket.sh"
# shellcheck source=lib/notary-auth.sh
source "$ROOT_DIR/scripts/ci/lib/notary-auth.sh"
DEFER_GATEKEEPER_ASSESSMENT="${CMUX_DEFER_GATEKEEPER_ASSESSMENT:-false}"

case "$DEFER_GATEKEEPER_ASSESSMENT" in
  true|false) ;;
  *)
    echo "CMUX_DEFER_GATEKEEPER_ASSESSMENT must be true or false" >&2
    exit 2
    ;;
esac

# shellcheck source=lib/gatekeeper-assessment.sh
source "$ROOT_DIR/scripts/ci/lib/gatekeeper-assessment.sh"
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
if [ -z "${ASC_API_KEY_ID:-}" ] \
  || [ -z "${ASC_API_ISSUER_ID:-}" ] \
  || [ -z "${ASC_API_KEY_P8_BASE64:-}" ]; then
  echo "Missing notarization secrets (ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_P8_BASE64)" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
# The decoded API key lives in TMP_DIR, which the EXIT trap removes.
notary_auth_init "$TMP_DIR"

HELPER_ZIP="$TMP_DIR/cmux-cua-notary.zip"
STANDALONE_DIR="$TMP_DIR/standalone"
STANDALONE_HELPER="$STANDALONE_DIR/cmux Computer Use.app"

helper_cdhashes() {
  slice_cdhashes "$HELPER_PATH" | paste -sd ',' -
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

  # A signing timestamp does not change a slice CDHash. Isolate this
  # submission before signing so thin and universal builds cannot retrieve
  # each other's notarization tickets through a shared CDHash.
  isolate_helper_submission "$HELPER_PATH"

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
  submitted_cdhash="$(helper_cdhashes)"
  if [ -z "$submitted_cdhash" ]; then
    echo "Could not resolve Computer Use helper CDHash before notarization" >&2
    exit 1
  fi
  "$DITTO_TOOL" -c -k --sequesterRsrc --keepParent "$HELPER_PATH" "$HELPER_ZIP"

  submit_json="$("$XCRUN_TOOL" notarytool submit "$HELPER_ZIP" \
    "${NOTARY_AUTH_ARGS[@]}" \
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
    printf 'cdhashes=%s\n' "$submitted_cdhash"
  } > "$state_tmp"
  /bin/mv "$state_tmp" "$SUBMISSION_FILE"
  echo "Computer Use helper notarization submitted: $submit_id ($submit_status)"
}

finish_submission() {
  local submit_id submitted_cdhash current_cdhash wait_json wait_status submit_status
  local wait_output wait_evidence wait_evidence_parent state_tmp
  if [ ! -f "$SUBMISSION_FILE" ]; then
    echo "Computer Use notarization state not found: $SUBMISSION_FILE" >&2
    exit 1
  fi
  submit_id="$(submission_value submission_id)"
  submitted_cdhash="$(submission_value cdhashes)"
  if [ -z "$submit_id" ] || [ -z "$submitted_cdhash" ]; then
    echo "Computer Use notarization state is incomplete: $SUBMISSION_FILE" >&2
    exit 1
  fi

  "$CODESIGN_TOOL" --verify --strict --verbose=2 "$HELPER_PATH"
  current_cdhash="$(helper_cdhashes)"
  if [ "$current_cdhash" != "$submitted_cdhash" ]; then
    echo "Computer Use helper changed after notarization submission" >&2
    echo "  submitted CDHash: $submitted_cdhash" >&2
    echo "  current CDHash:   ${current_cdhash:-<missing>}" >&2
    exit 1
  fi

  wait_output="$TMP_DIR/helper-notary-wait-output"
  wait_evidence="${CMUX_HELPER_NOTARY_OUTPUT_FILE:-${SUBMISSION_FILE}.log}"
  wait_evidence_parent="$(dirname "$wait_evidence")"
  if [ ! -d "$wait_evidence_parent" ] || [ ! -w "$wait_evidence_parent" ]; then
    echo "Computer Use notarization evidence parent must be an existing writable directory: $wait_evidence_parent" >&2
    exit 1
  fi
  HELPER_WAIT_TIMEOUT="${CMUX_HELPER_WAIT_TIMEOUT:-25m}"
  set +e
  "$XCRUN_TOOL" notarytool wait "$submit_id" \
    "${NOTARY_AUTH_ARGS[@]}" \
    --output-format json --timeout "$HELPER_WAIT_TIMEOUT" \
    >"$wait_output" 2>&1
  wait_status=$?
  set -e
  wait_json="$(cat "$wait_output")"
  if [ -n "$wait_json" ]; then
    submit_status="$(python3 -c 'import json,re,sys; raw=sys.stdin.read(); d=json.JSONDecoder(); status="unknown";
for m in re.finditer(r"\{", raw):
 try: value,_=d.raw_decode(raw[m.start():])
 except json.JSONDecodeError: continue
 if isinstance(value,dict) and value.get("status"): status=value["status"]
print(status)' <<<"$wait_json" 2>/dev/null || true)"
    [ -n "$submit_status" ] || submit_status="unknown"
  else
    submit_status="unknown"
  fi
  if [ "$wait_status" -ne 0 ] || [ "$submit_status" != "Accepted" ]; then
    # Keep the exact helper state and all Apple diagnostics. A timeout means
    # the submission is still independently recoverable; the nightly workflow
    # uploads this state with the signed app because no DMG exists yet.
    state_tmp="$SUBMISSION_FILE.tmp.$$"
    umask 077
    {
      printf 'submission_id=%s\n' "$submit_id"
      printf 'cdhashes=%s\n' "$submitted_cdhash"
      printf 'status=%s\n' "${submit_status:-unknown}"
      printf 'wait_exit=%s\n' "$wait_status"
      printf 'output_file=%s\n' "$wait_evidence"
    } > "$state_tmp"
    /bin/mv "$state_tmp" "$SUBMISSION_FILE"
    /bin/cp "$wait_output" "$wait_evidence"
    {
      printf '\n--- notarytool info for submission %s ---\n' "$submit_id"
      "$XCRUN_TOOL" notarytool info "$submit_id" \
        "${NOTARY_AUTH_ARGS[@]}" || true
      printf '\n--- notarytool log for submission %s ---\n' "$submit_id"
      "$XCRUN_TOOL" notarytool log "$submit_id" \
        "${NOTARY_AUTH_ARGS[@]}" || true
    } >> "$wait_evidence" 2>&1
    info_status="$(python3 - "$wait_evidence" <<'PYINFO'
import json
import re
import sys
raw = open(sys.argv[1], encoding="utf-8").read().split("--- notarytool log", 1)[0]
decoder = json.JSONDecoder()
status = "unknown"
for match in re.finditer(r"\{", raw):
    try:
        value, _ = decoder.raw_decode(raw[match.start():])
    except json.JSONDecodeError:
        continue
    if isinstance(value, dict) and value.get("status"):
        status = value["status"]
print(status)
PYINFO
    )"
    if [ "$info_status" != unknown ]; then
      python3 - "$SUBMISSION_FILE" "$info_status" <<'PYSTATE'
from pathlib import Path
import sys
path, status = Path(sys.argv[1]), sys.argv[2]
lines = path.read_text(encoding="utf-8").splitlines()
path.write_text("\n".join((f"status={status}" if line.startswith("status=") else line) for line in lines) + "\n", encoding="utf-8")
PYSTATE
    fi
    cat "$wait_evidence" >&2
    echo "Computer Use helper notarization failed with status: $submit_status (wait exit $wait_status)" >&2
    if [ "$info_status" = "In Progress" ] || [ "$info_status" = "Submitted" ] || [ "$info_status" = "Waiting for Upload" ] || { [ "$info_status" = unknown ] && [ "$wait_status" -ne 0 ]; }; then
      printf 'pending=true\n' >> "$SUBMISSION_FILE"
      echo "Computer Use helper notarization remains pending; state retained at $SUBMISSION_FILE" >&2
      exit 75
    fi
    exit 1
  fi

  "$XCRUN_TOOL" notarytool log "$submit_id" \
    "${NOTARY_AUTH_ARGS[@]}" > "$TMP_DIR/notary-log.json"
  cat "$TMP_DIR/notary-log.json"
  verify_ticket_contents_cover_slices "$TMP_DIR/notary-log.json" "$HELPER_PATH"
  "$XCRUN_TOOL" stapler staple "$HELPER_PATH"
  "$XCRUN_TOOL" stapler validate "$HELPER_PATH"
  verify_stapled_ticket_covers_slices "$HELPER_PATH"
  "$CODESIGN_TOOL" --verify --strict --verbose=2 "$HELPER_PATH"

  # Validate the same shape the runtime launches: a standalone copy outside the
  # host app. This also proves that the stapled ticket survives the copy.
  mkdir -p "$STANDALONE_DIR"
  "$DITTO_TOOL" "$HELPER_PATH" "$STANDALONE_HELPER"
  "$XCRUN_TOOL" stapler validate "$STANDALONE_HELPER"
  verify_stapled_ticket_covers_slices "$STANDALONE_HELPER"
  "$CODESIGN_TOOL" --verify --strict --verbose=2 "$STANDALONE_HELPER"
  if [ "$DEFER_GATEKEEPER_ASSESSMENT" = true ]; then
    # Gatekeeper's CDN-backed assessment can lag an Accepted ticket by many
    # minutes. Published continuation performs this same check after the
    # outer Apple wait, so the signing lane can finish without weakening the
    # ticket, stapler, or code-signature gates above.
    echo "Deferring Gatekeeper assessment for the published continuation"
  else
    assess_with_gatekeeper "$STANDALONE_HELPER"
  fi

  # Stapling the nested app changes the host's resource seal. Re-sign only the
  # outer app: re-signing nested code here would discard the helper's ticket.
  CMUX_SIGN_MODE=main-only \
    "$SIGN_BUNDLE_TOOL" "$APP_PATH" "$APP_ENTITLEMENTS" "$SIGNING_IDENTITY"
  "$CODESIGN_TOOL" --verify --deep --strict --verbose=2 "$APP_PATH"
  "$XCRUN_TOOL" stapler validate "$HELPER_PATH"
  verify_stapled_ticket_covers_slices "$HELPER_PATH"
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
