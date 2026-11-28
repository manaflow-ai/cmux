#!/usr/bin/env bash
# Continue an accepted DMG submission so the published DMG carries the app
# with its own stapled ticket (published nightly and RC builds, which submit
# only and are finished after the Ubuntu poller saw Accepted).
#
# Apple keys a ticket by code-directory hash. The first DMG submission's ticket
# covers the app inside, so the app is stapled from it. A DMG rebuilt around
# the stapled app is new data that no ticket covers, so it is signed and
# submitted once more (no wait), and that second submission is continued like
# any outer DMG: a bounded wait here, else the caller hands <outer-state>, its
# log and the DMG it names to its outer recovery path. That state has
# stapled_app=true; a state that already has it is only continued.
#
# Usage: resume-stapled-app-notarization.sh <state> <signed-app> <release-dmg> <immutable-dmg> <app-entitlements> <outer-state>
#
# - The first wait uses CMUX_NOTARY_WAIT_TIMEOUT and CMUX_NOTARY_EVIDENCE_FILE;
#   the second wait uses CMUX_STAPLED_APP_NOTARY_WAIT_TIMEOUT (default 40m).
# - The DMG around the stapled app is built at
#   <release-dmg dir>/stapled-app/<release-dmg name> (CMUX_STAPLED_APP_DMG)
#   and replaces <release-dmg> only after Apple accepted it and it is stapled.
#   Until then <release-dmg> stays the accepted, stapled first DMG.
# - The state of the DMG around the stapled app records the accepted first DMG
#   (first_submission_id, first_dmg_sha256; the DMG itself travels as
#   <stapled-app DMG>.first.dmg) and stapled_submitted_at, the epoch of the
#   second submission. Every hand-off keeps that state as it is.
# - 6 h fallback: when the second submission is not Accepted (still queued or
#   refused) CMUX_STAPLED_APP_FALLBACK_SECONDS (21600) after
#   stapled_submitted_at, the accepted first DMG ships instead: its
#   submission is checked Accepted again, its bytes against the record, and it
#   is stapled. The app inside it has no ticket of its own, so the script
#   writes <immutable-dmg>.stapled-app-fallback (the pending submission id) for
#   the smoke (smoke-dmg.sh --stapled-app-fallback) and logs a warning. An
#   unstapled DMG never ships.
# - APPLE_CERTIFICATE_BASE64 and APPLE_CERTIFICATE_PASSWORD go only to the
#   package tool, which makes the keychain just before the second signature
#   (CMUX_PACKAGE_CREATES_KEYCHAIN) and deletes it after that signature.
# - An upload of the second DMG that fails is tried again
#   (CMUX_STAPLED_APP_SUBMIT_ATTEMPTS, 3). When every try fails, the state
#   records submission_id=unsubmitted: it is never accepted, so it reaches the
#   6 h fallback like a refused submission.
set -euo pipefail
if [ "$#" -ne 6 ]; then
  echo "usage: resume-stapled-app-notarization.sh <state> <signed-app> <release-dmg> <immutable-dmg> <app-entitlements> <outer-state>" >&2
  exit 2
fi
STATE_FILE="$1"
APP_PATH="$2"
DMG_RELEASE="$3"
DMG_IMMUTABLE="$4"
APP_ENTITLEMENTS="$5"
OUTER_STATE="$6"
OUTER_LOG="${OUTER_STATE}.log"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PACKAGE_TOOL="${CMUX_NOTARIZE_NIGHTLY_DMG_TOOL:-$ROOT_DIR/scripts/ci/notarize-nightly-dmg.sh}"
RESUME_TOOL="${CMUX_RESUME_NIGHTLY_NOTARIZATION_TOOL:-$ROOT_DIR/scripts/ci/resume-nightly-notarization.sh}"
SIGNING_KEYCHAIN_TOOL="${CMUX_SIGNING_KEYCHAIN_TOOL:-$ROOT_DIR/scripts/ci/signing-keychain.sh}"
STAPLED_DMG="${CMUX_STAPLED_APP_DMG:-$(dirname "$DMG_RELEASE")/stapled-app/$(basename "$DMG_RELEASE")}"
STAPLED_WAIT_TIMEOUT="${CMUX_STAPLED_APP_NOTARY_WAIT_TIMEOUT:-40m}"
FALLBACK_SECONDS="${CMUX_STAPLED_APP_FALLBACK_SECONDS:-21600}"
SUBMIT_ATTEMPTS="${CMUX_STAPLED_APP_SUBMIT_ATTEMPTS:-3}"
SUBMIT_RETRY_SECONDS="${CMUX_STAPLED_APP_SUBMIT_RETRY_SECONDS:-60}"
# A continuation that the poll decided as due within its slack waits at most
# this long for the deadline before its date check (0: no wait).
DEADLINE_WAIT_SECONDS="${CMUX_STAPLED_APP_DEADLINE_WAIT_SECONDS:-0}"
for value in "$FALLBACK_SECONDS" "$DEADLINE_WAIT_SECONDS"; do
  case "$value" in
    ''|*[!0-9]*) echo "CMUX_STAPLED_APP_FALLBACK_SECONDS and CMUX_STAPLED_APP_DEADLINE_WAIT_SECONDS must be numbers of seconds" >&2; exit 2 ;;
  esac
done
# The helper recheck is skipped only for an app whose helper this process
# (step 1 below) or its caller (resume-helper-notarization.sh) checked.
HELPER_CHECKED_BY_CALLER="${CMUX_SKIP_HELPER_RECHECK:-false}"
STEP1_RAN=false
# Kept out of every child process except the keychain create below.
CERT_BASE64="${APPLE_CERTIFICATE_BASE64:-}"
CERT_PASSWORD="${APPLE_CERTIFICATE_PASSWORD:-}"
unset APPLE_CERTIFICATE_BASE64 APPLE_CERTIFICATE_PASSWORD
[ -f "$STATE_FILE" ] || { echo "Notarization state not found: $STATE_FILE" >&2; exit 1; }
[ -d "$APP_PATH/Contents" ] || { echo "Recovered signed app not found: $APP_PATH" >&2; exit 1; }

sha256_of() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}
state_value() {
  awk -F= -v key="$2" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$1"
}

# continue_stapled <state> <stapled-app DMG> <target DMG>: finish the DMG
# around the stapled app, or ship the accepted first DMG at the 6 h fallback.
# Either way the shipped DMG ends at <target DMG>. Exit 75: not Accepted yet,
# before the deadline (hand it off again).
continue_stapled() {
  local state="$1" dmg="$2" target="$3" status=0 submitted pending first first_id first_sha work left skip_recheck=false
  submitted="$(state_value "$state" stapled_submitted_at)"
  if [[ "$submitted" =~ ^[0-9]+$ ]] && [ "$DEADLINE_WAIT_SECONDS" -gt 0 ]; then
    left=$((submitted + FALLBACK_SECONDS - $(date +%s)))
    if [ "$left" -gt 0 ] && [ "$left" -le "$DEADLINE_WAIT_SECONDS" ]; then
      # A bounded wait to the recorded deadline (the poll decided it due).
      echo "Waiting ${left}s for the 6 h deadline of the stapled-app DMG"
      sleep "$left"
    fi
  fi
  "$RESUME_TOOL" "$state" "$APP_PATH" "$dmg" "$DMG_IMMUTABLE" || status=$?
  if [ "$status" -eq 0 ]; then
    [ "$dmg" = "$target" ] || /bin/mv -f "$dmg" "$target"
    rm -f "$DMG_IMMUTABLE.stapled-app-fallback"
    echo "The DMG around the stapled app is accepted and ships: $target"
    return 0
  fi
  # resume-nightly-notarization.sh exits 75 only when Apple did not answer
  # Accepted (queued or refused); any other failure publishes nothing.
  [ "$status" -eq 75 ] || return "$status"
  pending="$(state_value "$state" submission_id)"
  submitted="$(state_value "$state" stapled_submitted_at)"
  if ! [[ "$submitted" =~ ^[0-9]+$ ]]; then
    echo "The stapled-app state records no submit time; nothing is published" >&2
    return 1
  fi
  if [ "$(date +%s)" -lt $((submitted + FALLBACK_SECONDS)) ]; then
    echo "::warning::The DMG around the stapled app (submission $pending) is not Accepted yet; the accepted first DMG ships at the 6 h fallback unless Apple accepts it first"
    return 75
  fi
  first="$dmg.first.dmg"
  first_id="$(state_value "$state" first_submission_id)"
  first_sha="$(state_value "$state" first_dmg_sha256)"
  if ! [[ "$first_id" =~ ^[A-Za-z0-9._-]+$ ]] || [ ! -f "$first" ] || [ "$(sha256_of "$first")" != "$first_sha" ]; then
    echo "The stapled-app DMG (submission $pending) passed its 6 h deadline, but the first DMG ($first) or its record is missing or altered; nothing is published" >&2
    return 1
  fi
  # The first DMG under the release name with a state of its own: the
  # continuation checks its submission Accepted again, its bytes, staples it,
  # validates it and publishes it.
  work="$(dirname "$dmg")/first-dmg-fallback"
  rm -rf "$work"
  mkdir -p "$work"
  cp "$first" "$work/$(basename "$target")"
  {
    printf 'submission_id=%s\n' "$first_id"
    printf 'status=Accepted\n'
    printf 'dmg_path=%s\n' "$work/$(basename "$target")"
    printf 'dmg_sha256=%s\n' "$first_sha"
    printf 'submit_exit=0\n'
    printf 'immutable_path=%s\n' "$DMG_IMMUTABLE"
    printf 'channel=%s\n' "$(state_value "$state" channel)"
  } > "$work/first.state"
  # Skip the helper recheck only when this process or its caller checked it:
  # the continuation above exits 75 before its own helper check.
  if [ "$STEP1_RAN" = true ] || [ "$HELPER_CHECKED_BY_CALLER" = true ]; then skip_recheck=true; fi
  CMUX_SKIP_HELPER_RECHECK="$skip_recheck" \
  CMUX_NOTARY_WAIT_TIMEOUT=2m \
    "$RESUME_TOOL" "$work/first.state" "$APP_PATH" "$work/$(basename "$target")" "$DMG_IMMUTABLE"
  /bin/mv -f "$work/$(basename "$target")" "$target"
  printf '%s\n' "$pending" > "$DMG_IMMUTABLE.stapled-app-fallback"
  echo "::warning title=App shipped without its own ticket::Apple did not accept the DMG around the stapled app (submission $pending) within 6 h of its submission; the accepted, stapled first DMG (submission $first_id) ships, and the app inside it has no ticket of its own"
}

if grep -Fxq 'stapled_app=true' "$STATE_FILE"; then
  # Already the DMG around the stapled app: continue it, build nothing.
  "$SIGNING_KEYCHAIN_TOOL" delete
  continue_stapled "$STATE_FILE" "$DMG_RELEASE" "$DMG_RELEASE"
  exit $?
fi
[ -f "$APP_ENTITLEMENTS" ] || { echo "App entitlements not found: $APP_ENTITLEMENTS" >&2; exit 1; }
: "${APPLE_SIGNING_IDENTITY:?APPLE_SIGNING_IDENTITY signs the DMG around the stapled app}"
if [ -z "$CERT_BASE64" ] || [ -z "$CERT_PASSWORD" ]; then
  echo "Missing APPLE_CERTIFICATE_BASE64 or APPLE_CERTIFICATE_PASSWORD: the DMG around the stapled app is signed" >&2
  exit 1
fi
if [ "$STAPLED_DMG" = "$DMG_RELEASE" ] || [ "$(basename "$STAPLED_DMG")" != "$(basename "$DMG_RELEASE")" ]; then
  echo "The DMG around the stapled app must have the release name at another path: $STAPLED_DMG" >&2
  exit 1
fi
cleanup() {
  "$SIGNING_KEYCHAIN_TOOL" delete >/dev/null 2>&1 || true
}
trap cleanup EXIT

# 1. The first submission: staple and check the app. The first DMG keeps its
#    submitted bytes. No publication and no keychain here.
"$SIGNING_KEYCHAIN_TOOL" delete
CMUX_RESUME_APP_ONLY=true \
CMUX_DEFER_LAUNCH_SMOKES=true \
  "$RESUME_TOOL" "$STATE_FILE" "$APP_PATH" "$DMG_RELEASE" "$DMG_IMMUTABLE"

# 2. Build, sign and submit (no wait) the DMG around the stapled app at its own
#    path. The accepted first DMG travels beside it for the 6 h fallback.
mkdir -p "$(dirname "$STAPLED_DMG")"
FIRST_ID="$(state_value "$STATE_FILE" submission_id)"
cp "$DMG_RELEASE" "$STAPLED_DMG.first.dmg"
FIRST_SHA="$(sha256_of "$STAPLED_DMG.first.dmg")"
attempt=1
while :; do
  rm -f "$STAPLED_DMG" "$OUTER_STATE" "$OUTER_LOG"
  package_status=0
  APPLE_CERTIFICATE_BASE64="$CERT_BASE64" \
  APPLE_CERTIFICATE_PASSWORD="$CERT_PASSWORD" \
  CMUX_PACKAGE_CREATES_KEYCHAIN=true \
  CMUX_STAPLE_APP_IN_DMG=false \
  CMUX_COMPUTER_USE_HELPER_ALREADY_FINISHED=true \
  CMUX_COMPUTER_USE_NOTARY_SUBMISSION_FILE="" \
  CMUX_NOTARY_SUBMIT_ONLY=true \
  CMUX_SKIP_NOTARY_LOG=true \
  CMUX_NOTARY_STATE_STAPLED_APP=true \
  CMUX_NOTARY_STATE_FIRST_SUBMISSION_ID="$FIRST_ID" \
  CMUX_NOTARY_STATE_FIRST_DMG_SHA256="$FIRST_SHA" \
  CMUX_NOTARY_SUBMISSION_FILE="$OUTER_STATE" \
  CMUX_NOTARY_OUTPUT_FILE="$OUTER_LOG" \
  CMUX_APP_ENTITLEMENTS="$APP_ENTITLEMENTS" \
  CHANNEL_RELEASE_TAG="${CHANNEL_RELEASE_TAG:-${CMUX_CHANNEL:-nightly}}" \
  CHANNEL_DMG_PREFIX="${CHANNEL_DMG_PREFIX:-cmux-${CMUX_CHANNEL:-nightly}-macos}" \
  NIGHTLY_VARIANT="${NIGHTLY_VARIANT:-universal}" \
    "$PACKAGE_TOOL" "$APP_PATH" "$STAPLED_DMG" "$DMG_IMMUTABLE" || package_status=$?
  "$SIGNING_KEYCHAIN_TOOL" delete
  [ "$package_status" -ne 0 ] || break
  # The package tool writes its evidence only once it reached the upload. A
  # failure before that (build or signature) is not retried.
  if [ ! -s "$OUTER_LOG" ] || [ ! -f "$STAPLED_DMG" ]; then
    echo "Building or signing the DMG around the stapled app failed; nothing is published" >&2
    exit "$package_status"
  fi
  if [ "$attempt" -ge "$SUBMIT_ATTEMPTS" ]; then
    echo "::warning::The DMG around the stapled app could not be submitted ($attempt tries); the accepted first DMG ships at its 6 h fallback"
    {
      printf 'submission_id=unsubmitted\n'
      printf 'status=unsubmitted\n'
      printf 'dmg_path=%s\n' "$STAPLED_DMG"
      printf 'dmg_sha256=%s\n' "$(sha256_of "$STAPLED_DMG")"
      printf 'submit_exit=%s\n' "$package_status"
      printf 'immutable_path=%s\n' "$DMG_IMMUTABLE"
      printf 'release_tag=%s\n' "${CHANNEL_RELEASE_TAG:-${CMUX_CHANNEL:-nightly}}"
      printf 'dmg_prefix=%s\n' "${CHANNEL_DMG_PREFIX:-cmux-${CMUX_CHANNEL:-nightly}-macos}"
      printf 'variant=%s\n' "${NIGHTLY_VARIANT:-universal}"
      printf 'channel=%s\n' "${CMUX_CHANNEL:-nightly}"
      printf 'output_file=%s\n' "$OUTER_LOG"
      printf 'stapled_app=true\n'
      printf 'stapled_submitted_at=%s\n' "$(date +%s)"
      printf 'first_submission_id=%s\n' "$FIRST_ID"
      printf 'first_dmg_sha256=%s\n' "$FIRST_SHA"
    } > "$OUTER_STATE.tmp"
    /bin/mv "$OUTER_STATE.tmp" "$OUTER_STATE"
    break
  fi
  echo "Submitting the DMG around the stapled app failed (try $attempt of $SUBMIT_ATTEMPTS); trying again" >&2
  attempt=$((attempt + 1))
  sleep "$SUBMIT_RETRY_SECONDS"
done
CERT_BASE64=""
CERT_PASSWORD=""
if ! grep -Fxq 'stapled_app=true' "$OUTER_STATE" 2>/dev/null || [ ! -s "$OUTER_LOG" ] \
  || ! grep -Eq '^stapled_submitted_at=[0-9]+$' "$OUTER_STATE"; then
  echo "The stapled-app DMG state or its evidence was not created: $OUTER_STATE" >&2
  exit 1
fi

# 3. A bounded wait on the second submission. A wait that runs out fails, and
#    the caller hands <outer-state>, its log and the DMG it names to its outer
#    recovery path. The helper of this same app was checked in step 1.
#    Accepted, stapled and checked: only then does it replace the first DMG.
export CMUX_SKIP_HELPER_RECHECK=true
STEP1_RAN=true
export CMUX_NOTARY_WAIT_TIMEOUT="$STAPLED_WAIT_TIMEOUT"
export CMUX_NOTARY_EVIDENCE_FILE="$OUTER_LOG"
continue_stapled "$OUTER_STATE" "$STAPLED_DMG" "$DMG_RELEASE"
