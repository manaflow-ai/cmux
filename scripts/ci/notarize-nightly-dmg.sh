#!/usr/bin/env bash
set -euo pipefail

# Parse this whole file before anything runs. bash reads a script one command
# at a time, and macOS /bin/bash 3.2 exits 0 on a parse error once the EXIT
# trap below is set: nightly-next runs 39014131817 and 39014922771 left the
# notarize step "green" with no stapled app. A parse error here exits 2.
if ! "${BASH:-/bin/bash}" -n "${BASH_SOURCE[0]}"; then
  echo "$0 does not parse under ${BASH:-/bin/bash} ${BASH_VERSION:-}; nothing was signed, submitted or stapled" >&2
  exit 2
fi

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <signed-app> <release-dmg> <immutable-dmg>" >&2
  exit 2
fi

APP_PATH="$1"
DMG_RELEASE="$2"
DMG_IMMUTABLE="$3"
CREATE_DMG_TOOL="${CMUX_CREATE_DMG_TOOL:-create-dmg}"
CODESIGN_TOOL="${CMUX_CODESIGN_TOOL:-/usr/bin/codesign}"
XCRUN_TOOL="${CMUX_XCRUN_TOOL:-xcrun}"
HDIUTIL_TOOL="${CMUX_HDIUTIL_TOOL:-hdiutil}"
SPCTL_TOOL="${CMUX_SPCTL_TOOL:-spctl}"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SMOKE_TOOL="${CMUX_SMOKE_TOOL:-$ROOT_DIR/scripts/smoke-launch-macos-app.sh}"
VERIFY_METADATA_TOOL="${CMUX_VERIFY_METADATA_TOOL:-$ROOT_DIR/scripts/verify-app-bundle-channel-metadata.sh}"
# CMUX_DEFER_LAUNCH_SMOKES=true: skip the launch smokes here. The caller runs
# them in a separate job that holds no secrets (scripts/ci/smoke-dmg.sh on the
# final DMG), so no bundle code runs in a job that signs, notarizes or publishes.
DEFER_LAUNCH_SMOKES="${CMUX_DEFER_LAUNCH_SMOKES:-false}"
launch_smokes() {
  if [ "$DEFER_LAUNCH_SMOKES" = true ]; then
    echo "Launch smokes for $1 run in the secret-free verify job"
    return 0
  fi
  CMUX_SMOKE_ALLOW_UNSUPPORTED_GUI=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$1"
  CMUX_SMOKE_DIRECT_EXEC=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$1"
}
VERIFY_LICENSES_TOOL="${CMUX_VERIFY_LICENSES_TOOL:-$ROOT_DIR/scripts/verify-app-bundle-licenses.sh}"
NOTARIZE_COMPUTER_USE_HELPER_TOOL="${CMUX_NOTARIZE_COMPUTER_USE_HELPER_TOOL:-$ROOT_DIR/scripts/ci/notarize-computer-use-helper.sh}"
SIGNING_KEYCHAIN_TOOL="${CMUX_SIGNING_KEYCHAIN_TOOL:-$ROOT_DIR/scripts/ci/signing-keychain.sh}"
COMPUTER_USE_NOTARY_SUBMISSION_FILE="${CMUX_COMPUTER_USE_NOTARY_SUBMISSION_FILE:-}"
SKIP_NOTARIZATION="${CMUX_SKIP_NOTARIZATION:-false}"
# CMUX_STAPLE_APP_IN_DMG=true (default): the app inside the shipped DMG carries
# its own stapled ticket, so a copy taken out of the DMG (Sparkle installs one)
# passes Gatekeeper without an online ticket lookup. Apple keys every ticket by
# code-directory hash (stapler looks up the record "2/2/<cdhash>"). The first
# DMG submission's ticket covers the app's hash, so the app is stapled from it.
# A DMG rebuilt around the stapled app is new data with a new hash that no
# ticket covers yet, so that DMG is signed and submitted once more, and it
# replaces the first DMG only after Apple accepts it and it is stapled.
# false keeps one DMG submission (notary tests that publish nothing).
STAPLE_APP_IN_DMG="${CMUX_STAPLE_APP_IN_DMG:-true}"
# Fallback (chief 2026-10-16): when Apple has not accepted the stapled-app DMG
# within CMUX_STAPLED_APP_FALLBACK_SECONDS (6 h) of its first submission, a
# continuation publishes the FIRST DMG (notarized and stapled; the app inside
# has no ticket of its own) with a ::warning:: that names the pending
# submission. The clock is Apple's own record: the earliest submission named
# <immutable name>-stapled-app.dmg (or the submit time in the state), so the
# handed-off and the recovery paths count from the same time. An unstapled DMG
# is never published. The first DMG travels beside a handed-off stapled-app
# DMG as <release name>.first.dmg.
STAPLED_APP_FALLBACK_SECONDS="${CMUX_STAPLED_APP_FALLBACK_SECONDS:-21600}"
case "$STAPLED_APP_FALLBACK_SECONDS" in
  ''|*[!0-9]*) echo "CMUX_STAPLED_APP_FALLBACK_SECONDS must be a number of seconds" >&2; exit 2 ;;
esac
STAPLED_APP_FALLBACK=false
STAPLED_APP_FALLBACK_ID=""
# CMUX_STAPLED_DMG_HANDOFF_FILE: submit the DMG around the stapled app without
# a wait, keep it as <release-dmg>.stapled-app.dmg, write this record and stop
# after the app checks; scripts/ci/finish-stapled-app-dmgs.sh waits for several
# such submissions at once and finishes them (main's release.yml thin variants).
STAPLED_DMG_HANDOFF_FILE="${CMUX_STAPLED_DMG_HANDOFF_FILE:-}"
case "$STAPLE_APP_IN_DMG" in
  true|false) ;;
  *) echo "CMUX_STAPLE_APP_IN_DMG must be true or false, got: $STAPLE_APP_IN_DMG" >&2; exit 2 ;;
esac
# Release channel of the app being packaged: `nightly` (default), `next`
# (nightly-next's cmux NEXT), `rc`, or `stable`. It selects the entitlements
# file and the bundle-metadata check; the packaging, notarization, and stapling
# steps are identical for all of them.
# `stable` is used by release.yml (cx-b6r7) and by the nightly-next
# production-identity notary probe (nightly.yml input
# notary_probe_production_identity), which publishes nothing.
CHANNEL="${CMUX_CHANNEL:-nightly}"
case "$CHANNEL" in
  nightly|rc) ENTITLEMENTS_NAME="cmux.${CHANNEL}.entitlements" ;;
  # nightly-next's cmux NEXT (cx-x7hwx): signed without a provisioning profile.
  next) ENTITLEMENTS_NAME="cmux.next-dev.entitlements" ;;
  # cmux NEXT Stable (stable-next.yml): the nightly's entitlements under its own identity.
  next-stable) ENTITLEMENTS_NAME="cmux.next-dev.entitlements" ;;
  stable) ENTITLEMENTS_NAME="cmux.release.entitlements" ;;
  *)
    echo "Unsupported CMUX_CHANNEL: $CHANNEL (expected nightly, next, next-stable, rc or stable)" >&2
    exit 2
    ;;
esac
APP_ENTITLEMENTS="${CMUX_APP_ENTITLEMENTS:-$ROOT_DIR/$ENTITLEMENTS_NAME}"
FIRST_DMG="${DMG_RELEASE%.dmg}.first.dmg"
STAPLED_DMG_NAME="$(basename "${DMG_IMMUTABLE%.dmg}")-stapled-app.dmg"
# A later nightly-next run continues an earlier run's submission: the state file
# it saved names the Apple submission and the exact signed DMG. The DMG is not
# rebuilt or resubmitted; Apple is asked for the status, an Accepted one is
# stapled and validated as below, and one still in progress stays pending.
CONTINUE_STATE="${CMUX_NOTARY_CONTINUE_STATE:-}"
# shellcheck source=lib/notary-auth.sh
source "$ROOT_DIR/scripts/ci/lib/notary-auth.sh"
# shellcheck source=lib/notarization-ticket.sh
source "$ROOT_DIR/scripts/ci/lib/notarization-ticket.sh"

if [ ! -d "$APP_PATH/Contents" ]; then
  echo "Signed app not found: $APP_PATH" >&2
  exit 1
fi
if [ "$SKIP_NOTARIZATION" != true ] \
  && { [ -z "${ASC_API_KEY_ID:-}" ] || [ -z "${ASC_API_ISSUER_ID:-}" ] || [ -z "${ASC_API_KEY_P8_BASE64:-}" ]; }; then
  echo "Missing notarization secrets (ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_P8_BASE64)" >&2
  exit 1
fi
if [ -z "$CONTINUE_STATE" ] && [ -z "${APPLE_SIGNING_IDENTITY:-}" ]; then
  echo "Missing APPLE_SIGNING_IDENTITY" >&2
  exit 1
fi
# The DMG around the stapled app is signed after Apple's wait, also in a
# continuation, so its signing inputs must be present before any submission.
if [ "$SKIP_NOTARIZATION" != true ] && [ "$STAPLE_APP_IN_DMG" = true ] \
  && [ "${CMUX_NOTARY_SUBMIT_ONLY:-false}" != true ] \
  && { [ -z "${APPLE_SIGNING_IDENTITY:-}" ] || [ -z "${APPLE_CERTIFICATE_BASE64:-}" ] || [ -z "${APPLE_CERTIFICATE_PASSWORD:-}" ]; }; then
  echo "Missing APPLE_SIGNING_IDENTITY, APPLE_CERTIFICATE_BASE64 or APPLE_CERTIFICATE_PASSWORD: the DMG around the stapled app is signed again (CMUX_STAPLE_APP_IN_DMG=false ships the app unstapled)" >&2
  exit 1
fi
CONTINUE_SUBMISSION_ID=""
if [ -n "$CONTINUE_STATE" ]; then
  state_value() {
    awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$CONTINUE_STATE"
  }
  CONTINUE_SUBMISSION_ID="$(state_value submission_id)"
  # stapled_app=true: the saved DMG is already the one around the stapled app
  # (its submission was handed off below), so no further DMG is built.
  CONTINUE_STAPLED_APP="$(state_value stapled_app)"
  if ! [[ "$CONTINUE_SUBMISSION_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Notarization state $CONTINUE_STATE names no valid Apple submission id" >&2
    exit 1
  fi
  continue_sha256="$(shasum -a 256 "$DMG_RELEASE" | awk '{print $1}')"
  if [ "$continue_sha256" != "$(state_value dmg_sha256)" ]; then
    echo "SHA-256 of $DMG_RELEASE ($continue_sha256) is not the submitted DMG's in $CONTINUE_STATE" >&2
    exit 1
  fi
fi

DMG_TMP_DIR="$(mktemp -d)"
MOUNT_DIR=""
detach_mounted_dmg() {
  [ -n "$MOUNT_DIR" ] || return 0
  "$HDIUTIL_TOOL" detach "$MOUNT_DIR" || "$HDIUTIL_TOOL" detach -force "$MOUNT_DIR"
  rmdir "$MOUNT_DIR"
  MOUNT_DIR=""
}
RESTAPLE_KEYCHAIN_OPEN=false
cleanup() {
  # Keep the script's own exit status: the trap must never turn a failure into
  # a success.
  local status=$?
  if [ -n "$MOUNT_DIR" ]; then
    detach_mounted_dmg || true
  fi
  if [ "$RESTAPLE_KEYCHAIN_OPEN" = true ]; then
    "${SIGNING_KEYCHAIN_TOOL}" delete || true
  fi
  rm -rf "$DMG_TMP_DIR"
  exit "$status"
}
trap cleanup EXIT
NOTARY_DIR="$DMG_TMP_DIR/notary"
mkdir -m 700 "$NOTARY_DIR"
if [ "$SKIP_NOTARIZATION" != true ]; then
  notary_auth_init "$NOTARY_DIR"
fi

# A bundle that carries the nested Computer Use helper (the cmux-next nightly
# does, cx-urd.6) needs its separate notarization and host reseal. A helper
# Apple still holds after its bounded wait exits 75 (cx-urd.68): it stays
# unstapled and the run goes on to the DMG. Codesign kept the helper's
# submitted signature, so the DMG ticket covers its slices; that is checked
# below before anything is stapled, here or in a continuing run.
COMPUTER_USE_HELPER="$APP_PATH/Contents/Library/cmux Computer Use.app"
helper_exit=0
if [ -n "$CONTINUE_STATE" ]; then
  echo "Continuing Apple submission $CONTINUE_SUBMISSION_ID for $DMG_RELEASE"
elif [ "$SKIP_NOTARIZATION" = true ]; then
  echo "Skipping Computer Use and outer notarization for internal dogfood artifact"
elif [ "${CMUX_COMPUTER_USE_HELPER_ALREADY_FINISHED:-false}" = true ]; then
  echo "Computer Use helper was finished by the recovery continuation"
elif [ ! -d "$APP_PATH/Contents/Library/cmux Computer Use.app" ]; then
  echo "No nested cmux Computer Use app; skipping its notarization"
elif [ -n "$COMPUTER_USE_NOTARY_SUBMISSION_FILE" ]; then
  "$NOTARIZE_COMPUTER_USE_HELPER_TOOL" \
    --finish "$COMPUTER_USE_NOTARY_SUBMISSION_FILE" \
    "$APP_PATH" \
    "$APP_ENTITLEMENTS" \
    "$APPLE_SIGNING_IDENTITY" || helper_exit=$?
else
  # The synchronous run re-signs the helper after the host was sealed and
  # reseals only once stapled, so a pending exit there is a failure.
  "$NOTARIZE_COMPUTER_USE_HELPER_TOOL" \
    "$APP_PATH" \
    "$APP_ENTITLEMENTS" \
    "$APPLE_SIGNING_IDENTITY"
fi
if [ "$helper_exit" -eq 75 ]; then
  echo "::warning title=Computer Use helper not stapled::Apple still holds the helper's own submission; the DMG ticket must cover it."
elif [ "$helper_exit" -ne 0 ]; then
  exit "$helper_exit"
fi

# package_signed_dmg <app> <out-dmg> <empty work dir> [create-keychain]:
# create-dmg, LZMA, sign. create-keychain makes the signing keychain just
# before the signature (the DMG around the stapled app, after Apple's wait).
package_signed_dmg() {
  local app="$1" out="$2" work="$3" keychain="${4:-}" created format saved_umask
  # create-dmg copies the app with the process umask. The notary sidecar
  # writers set 077, and an app copied under it is readable only by its owner.
  saved_umask="$(umask)"
  umask 022
  "$CREATE_DMG_TOOL" --no-code-sign "$app" "$work"
  created="$(find "$work" -maxdepth 1 -name '*.dmg' -print -quit)"
  if [ -z "$created" ]; then
    echo "Failed to locate created DMG for $app" >&2
    exit 1
  fi
  # create-dmg emits an LZFSE (ULFO) image. Re-encode to LZMA (ULMO): same bundle,
  # about a quarter smaller download, and every supported macOS (14+) mounts it.
  "$HDIUTIL_TOOL" convert "$created" -quiet -format ULMO -ov -o "$out"
  rm -f "$created"
  format="$("$HDIUTIL_TOOL" imageinfo "$out" | awk -F': *' '/^Format:/ {print $2; exit}')"
  if [ "$format" != "ULMO" ]; then
    echo "Expected ULMO (LZMA) DMG after conversion, got: ${format:-unknown}" >&2
    exit 1
  fi

  if [ "$keychain" = create-keychain ]; then
    RESTAPLE_KEYCHAIN_OPEN=true
    "$SIGNING_KEYCHAIN_TOOL" create
    # No later child process needs the certificate.
    unset APPLE_CERTIFICATE_BASE64 APPLE_CERTIFICATE_PASSWORD
  fi
  # The helper wait can pass the CI keychain's short idle lock.
  "$SIGNING_KEYCHAIN_TOOL" unlock
  "$CODESIGN_TOOL" --force --timestamp --keychain build.keychain \
    --sign "$APPLE_SIGNING_IDENTITY" \
    "$out"
  "$CODESIGN_TOOL" --verify --verbose=2 "$out"
  umask "$saved_umask"
}

if [ -z "$CONTINUE_STATE" ]; then
  # CMUX_PACKAGE_CREATES_KEYCHAIN=true: make the signing keychain just before
  # this signature (resume-stapled-app-notarization.sh, which passes the
  # certificate only to this tool).
  if [ "${CMUX_PACKAGE_CREATES_KEYCHAIN:-false}" = true ]; then
    package_signed_dmg "$APP_PATH" "$DMG_RELEASE" "$DMG_TMP_DIR" create-keychain
  else
    package_signed_dmg "$APP_PATH" "$DMG_RELEASE" "$DMG_TMP_DIR"
  fi
fi
# This is the last signature. Delete the CI signing keychain before Apple's
# wait and before the launch smokes below run code from the bundle. A
# continuation signs nothing; delete is a no-op when no keychain exists.
"$SIGNING_KEYCHAIN_TOOL" delete

if [ "$SKIP_NOTARIZATION" = true ]; then
  # Fast dogfood DMGs retain Developer ID signing but never enter Apple's
  # ticketing or distribution policy paths.
  cp "$DMG_RELEASE" "$DMG_IMMUTABLE"
  exit 0
fi

# notarytool writes timeout diagnostics to stderr, so command substitution alone
# loses the submission id when --wait reaches its deadline. Keep both streams in
# a durable sidecar, and fail closed until a later run verifies Accepted.
NOTARY_WAIT_TIMEOUT="${CMUX_NOTARY_WAIT_TIMEOUT:-25m}"
SUBMIT_ONLY="${CMUX_NOTARY_SUBMIT_ONLY:-false}"
# Published nightly-next waits up to NOTARY_WAIT_TIMEOUT, then hands a submission
# still in Apple's queue to the next run (submission_pending) instead of failing.
PENDING_ON_TIMEOUT="${CMUX_NOTARY_PENDING_ON_TIMEOUT:-false}"
# The wait for the DMG around the stapled app (CMUX_STAPLE_APP_IN_DMG).
STAPLED_DMG_WAIT_TIMEOUT="${CMUX_STAPLED_DMG_WAIT_TIMEOUT:-$NOTARY_WAIT_TIMEOUT}"
NOTARY_WAIT_TIMED_OUT=false
NOTARY_SUBMISSION_FILE="${CMUX_NOTARY_SUBMISSION_FILE:-${DMG_RELEASE}.notarization.state}"
NOTARY_OUTPUT_FILE="${CMUX_NOTARY_OUTPUT_FILE:-${DMG_RELEASE}.notarization.log}"
NOTARY_SUBMIT_OUTPUT="$NOTARY_DIR/dmg-submit-output"
for notary_sidecar in "$NOTARY_SUBMISSION_FILE" "$NOTARY_OUTPUT_FILE"; do
  notary_sidecar_parent="$(dirname "$notary_sidecar")"
  if [ ! -d "$notary_sidecar_parent" ] || [ ! -w "$notary_sidecar_parent" ]; then
    echo "Notary sidecar parent must be an existing writable directory: $notary_sidecar_parent" >&2
    exit 1
  fi
done
set +e
if [ -n "$CONTINUE_STATE" ]; then
  "$XCRUN_TOOL" notarytool info "$CONTINUE_SUBMISSION_ID" "${NOTARY_AUTH_ARGS[@]}" \
    --output-format json
elif [ "$SUBMIT_ONLY" != true ]; then
  "$XCRUN_TOOL" notarytool submit "$DMG_RELEASE" "${NOTARY_AUTH_ARGS[@]}" \
    --output-format json --wait --timeout "$NOTARY_WAIT_TIMEOUT"
else
  "$XCRUN_TOOL" notarytool submit "$DMG_RELEASE" "${NOTARY_AUTH_ARGS[@]}" \
    --output-format json
fi >"$NOTARY_SUBMIT_OUTPUT" 2>&1
NOTARY_SUBMIT_EXIT=$?
set -e
# The 6 h stapled-app fallback counts from here, after the upload returned
# (write_notary_state).
DMG_SUBMITTED_AT="$(date +%s)"

extract_notary_value() {
  local file="$1" key="$2"
  python3 - "$file" "$key" <<'PY'
import json
import re
import sys

path, key = sys.argv[1:]
raw = open(path, encoding="utf-8").read()
decoder = json.JSONDecoder()
values = []
for match in re.finditer(r"\{", raw):
    try:
        value, _ = decoder.raw_decode(raw[match.start():])
    except json.JSONDecodeError:
        continue
    if isinstance(value, dict) and value.get(key) not in (None, ""):
        values.append(value[key])
if values:
    print(values[-1])
PY
}

# stapled_app_deadline_passed <mode> <recorded epoch> <time>: true when the
# stapled-app DMG of this build has waited CMUX_STAPLED_APP_FALLBACK_SECONDS.
#   handed-off  <time> is the continued stapled-app submission's createdDate;
#               the clock is the earlier of it and the recorded epoch.
#   recovery    <time> is the first DMG's createdDate; the clock is Apple's
#               earliest submission named $STAPLED_DMG_NAME made after it
#               (an earlier attempt of the same build number does not count).
# Sets STAPLED_APP_FALLBACK_ID to the newest such submission (recovery). An
# unknown clock (nothing recorded, history unreadable) is not passed.
# The clock of the DMG around the stapled app. Its own function, not a heredoc
# inside $(...): macOS /bin/bash 3.2 reads quotes in such a heredoc as shell
# quotes, and an apostrophe in the Python broke the whole script (nightly-next
# run 39011132580: "unexpected EOF while looking for matching `'").
stapled_app_clock() {
  python3 - "$@" <<'PY'
import datetime, json, re, sys, time
mode, path, name, recorded, when, limit = sys.argv[1:]
def epoch(text):
    # Apple's dates: 2026-10-16T12:34:56.789Z (fraction and zone optional).
    m = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.\d+)?(Z|[+-]\d\d:?\d\d)?", str(text or "").strip())
    if not m:
        return None
    base = datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
    zone = m.group(2) or "Z"
    if zone != "Z":
        sign = 1 if zone[0] == "+" else -1
        digits = zone[1:].replace(":", "")
        base -= sign * datetime.timedelta(hours=int(digits[:2]), minutes=int(digits[2:]))
    return base.timestamp()
times, newest = [], ("", 0.0)
if mode == "handed-off":
    if recorded.isdigit():
        times.append(float(recorded))
    if epoch(when) is not None:
        times.append(epoch(when))
else:
    not_before = epoch(when)
    try:
        entries = json.load(open(path, encoding="utf-8")).get("history") or []
    except (OSError, ValueError, AttributeError):
        entries = []
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("name") != name:
            continue
        created = epoch(entry.get("createdDate"))
        if created is None or (not_before is not None and created < not_before):
            continue
        times.append(created)
        if created >= newest[1]:
            newest = (str(entry.get("id") or ""), created)
if not times:
    print("unknown -")
else:
    age = time.time() - min(times)
    print(("passed" if age >= int(limit) else "waiting"), newest[0] or "-", int(age))
PY
}

stapled_app_deadline_passed() {
  local mode="$1" recorded="${2:-}" when="${3:-}" history="$NOTARY_DIR/history.json" verdict
  : >"$history"
  if [ "$mode" = recovery ]; then
    "$XCRUN_TOOL" notarytool history "${NOTARY_AUTH_ARGS[@]}" --output-format json >"$history" 2>/dev/null || : >"$history"
  fi
  verdict="$(stapled_app_clock "$mode" "$history" "$STAPLED_DMG_NAME" "$recorded" "$when" "$STAPLED_APP_FALLBACK_SECONDS")"
  echo "Stapled-app DMG clock ($mode) for $STAPLED_DMG_NAME: $verdict (limit ${STAPLED_APP_FALLBACK_SECONDS}s)"
  case "$verdict" in
    passed\ *)
      STAPLED_APP_FALLBACK_ID="$(awk '{print $2}' <<<"$verdict")"
      [ "$STAPLED_APP_FALLBACK_ID" != - ] || STAPLED_APP_FALLBACK_ID="unknown"
      return 0 ;;
  esac
  return 1
}

DMG_SUBMIT_ID="$(extract_notary_value "$NOTARY_SUBMIT_OUTPUT" id || true)"
DMG_STATUS="$(extract_notary_value "$NOTARY_SUBMIT_OUTPUT" status || true)"
if [ -z "$DMG_STATUS" ]; then
  DMG_STATUS="unknown"
fi

write_notary_state() {
  local state_tmp="$NOTARY_SUBMISSION_FILE.tmp.$$" dmg_sha256=""
  if command -v shasum >/dev/null 2>&1; then
    dmg_sha256="$(shasum -a 256 "$DMG_RELEASE" | awk '{print $1}')"
  fi
  (
  umask 077
  {
    printf 'submission_id=%s\n' "$DMG_SUBMIT_ID"
    printf 'status=%s\n' "$DMG_STATUS"
    printf 'dmg_path=%s\n' "$DMG_RELEASE"
    printf 'dmg_sha256=%s\n' "$dmg_sha256"
    printf 'submit_exit=%s\n' "$NOTARY_SUBMIT_EXIT"
    printf 'immutable_path=%s\n' "$DMG_IMMUTABLE"
    printf 'release_tag=%s\n' "${CHANNEL_RELEASE_TAG:-}"
    printf 'dmg_prefix=%s\n' "${CHANNEL_DMG_PREFIX:-}"
    printf 'variant=%s\n' "${NIGHTLY_VARIANT:-}"
    printf 'channel=%s\n' "$CHANNEL"
    printf 'output_file=%s\n' "$NOTARY_OUTPUT_FILE"
    # STATE_*: the in-run hand-off below. CMUX_NOTARY_STATE_*: the DMG around
    # the stapled app submitted by resume-stapled-app-notarization.sh.
    if [ "${STATE_STAPLED_APP:-false}" = true ]; then
      printf 'stapled_app=true\n'
      printf 'first_submission_id=%s\n' "${STATE_FIRST_SUBMISSION_ID:-}"
      printf 'first_dmg_sha256=%s\n' "${STATE_FIRST_DMG_SHA256:-}"
      printf 'stapled_submitted_at=%s\n' "${STATE_STAPLED_SUBMITTED_AT:-}"
    elif [ "${CMUX_NOTARY_STATE_STAPLED_APP:-false}" = true ]; then
      printf 'stapled_app=true\n'
      # The 6 h fallback clock and the accepted first DMG it ships.
      printf 'stapled_submitted_at=%s\n' "$DMG_SUBMITTED_AT"
      printf 'first_submission_id=%s\n' "${CMUX_NOTARY_STATE_FIRST_SUBMISSION_ID:-}"
      printf 'first_dmg_sha256=%s\n' "${CMUX_NOTARY_STATE_FIRST_DMG_SHA256:-}"
    fi
    if [ "$NOTARY_WAIT_TIMED_OUT" = true ]; then
      printf 'wait_timed_out=true\n'
    fi
  } > "$state_tmp"
  )
  /bin/mv "$state_tmp" "$NOTARY_SUBMISSION_FILE"
}

save_notary_output() {
  # The output file is intentionally retained after a failed run. It is the
  # evidence needed to resume the exact Apple submission in a follow-up job.
  # Only the sidecar is private; the app stapled later must not inherit 077.
  (
  umask 077
  /bin/cp "$NOTARY_SUBMIT_OUTPUT" "$NOTARY_OUTPUT_FILE"
  if [ -n "$DMG_SUBMIT_ID" ] && [ "${CMUX_SKIP_NOTARY_LOG:-false}" != true ]; then
    {
      printf '\n--- notarytool log for submission %s ---\n' "$DMG_SUBMIT_ID"
      "$XCRUN_TOOL" notarytool log "$DMG_SUBMIT_ID" "${NOTARY_AUTH_ARGS[@]}" || true
    } >> "$NOTARY_OUTPUT_FILE" 2>&1
  fi
  )
  cat "$NOTARY_OUTPUT_FILE" >&2
}

if [ -n "$CONTINUE_STATE" ]; then
  if [ "$NOTARY_SUBMIT_EXIT" -ne 0 ] || [ "$DMG_SUBMIT_ID" != "$CONTINUE_SUBMISSION_ID" ]; then
    save_notary_output
    echo "Could not read the status of Apple submission $CONTINUE_SUBMISSION_ID" >&2
    exit 1
  fi
  if [ "$DMG_STATUS" != Accepted ] && [ "$STAPLE_APP_IN_DMG" = true ] && [ "${CONTINUE_STAPLED_APP:-}" = true ] \
    && stapled_app_deadline_passed handed-off "$(state_value stapled_submitted_at)" "$(extract_notary_value "$NOTARY_SUBMIT_OUTPUT" createdDate || true)"; then
    # The stapled-app DMG is past its deadline: publish the accepted first DMG.
    STAPLED_APP_FALLBACK_ID="$CONTINUE_SUBMISSION_ID"
    first_id="$(state_value first_submission_id)"
    first_sha="$(state_value first_dmg_sha256)"
    if ! [[ "$first_id" =~ ^[A-Za-z0-9._-]+$ ]] || [ ! -f "$FIRST_DMG" ] \
      || [ "$(shasum -a 256 "$FIRST_DMG" | awk '{print $1}')" != "$first_sha" ]; then
      echo "The stapled-app DMG passed its deadline, but the first DMG ($FIRST_DMG) or its record is missing or altered; nothing is published" >&2
      exit 1
    fi
    first_info="$NOTARY_DIR/first-info"
    "$XCRUN_TOOL" notarytool info "$first_id" "${NOTARY_AUTH_ARGS[@]}" --output-format json >"$first_info" 2>&1 || true
    if [ "$(extract_notary_value "$first_info" status || true)" != Accepted ]; then
      cat "$first_info" >&2
      echo "The first DMG's submission $first_id is not Accepted; nothing is published" >&2
      exit 1
    fi
    STAPLED_APP_FALLBACK=true
    DMG_SUBMIT_ID="$first_id"
    DMG_STATUS=Accepted
  elif [ "$DMG_STATUS" != Accepted ] && [ "$STAPLE_APP_IN_DMG" = true ] && [ "${CONTINUE_STAPLED_APP:-}" = true ]; then
    # Not accepted (still queued, or refused) and not yet past 6 h: the
    # accepted first DMG waits for the fallback; nothing else is published.
    save_notary_output
    echo "::warning::stapled-app submission $CONTINUE_SUBMISSION_ID is $DMG_STATUS; the accepted first DMG ships at the 6 h fallback unless Apple accepts it first"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      echo "submission_pending=true" >> "$GITHUB_OUTPUT"
      echo "stapled_app_pending=true" >> "$GITHUB_OUTPUT"
    fi
    exit 0
  elif [ "$DMG_STATUS" = "In Progress" ]; then
    save_notary_output
    echo "Apple submission $CONTINUE_SUBMISSION_ID is still in progress; publication awaits Accepted" >&2
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      echo "submission_pending=true" >> "$GITHUB_OUTPUT"
      if [ "${CONTINUE_STAPLED_APP:-}" = true ]; then
        # The first DMG was accepted; its stapled-app DMG is still queued.
        echo "stapled_app_pending=true" >> "$GITHUB_OUTPUT"
      fi
    fi
    exit 0
  fi
  # Apple's verdict, so the recovery step can tell a rejected submission from
  # an accepted one that a later local check (staple, launch, notices) failed.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "notary_status=$DMG_STATUS" >> "$GITHUB_OUTPUT"
  fi
fi

if [ "$SUBMIT_ONLY" = true ]; then
  if [ -z "$DMG_SUBMIT_ID" ]; then
    save_notary_output
    echo "DMG submission returned no Apple submission id; refusing asynchronous handoff" >&2
    exit 1
  fi
  if [ "$NOTARY_SUBMIT_EXIT" -ne 0 ]; then
    write_notary_state
    save_notary_output
    echo "DMG submission failed before an asynchronous handoff (submission $DMG_SUBMIT_ID); refusing continuation" >&2
    exit 1
  fi
  write_notary_state
  save_notary_output
  echo "DMG uploaded for asynchronous processing (submission $DMG_SUBMIT_ID); publication awaits Accepted" >&2
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "submission_pending=true" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

if [ -z "$CONTINUE_STATE" ] && [ -n "$DMG_SUBMIT_ID" ] \
  && { [ "$NOTARY_SUBMIT_EXIT" -ne 0 ] || [ "$DMG_STATUS" != "Accepted" ]; }; then
  write_notary_state
fi
if [ "$NOTARY_SUBMIT_EXIT" -ne 0 ]; then
  save_notary_output
  if grep -Eiq 'timeout|timed out' "$NOTARY_OUTPUT_FILE"; then
    notary_failure="did not finish within $NOTARY_WAIT_TIMEOUT"
    if [ "$PENDING_ON_TIMEOUT" = true ] && [ -n "$DMG_SUBMIT_ID" ]; then
      NOTARY_WAIT_TIMED_OUT=true
      write_notary_state
      echo "DMG notarization $notary_failure (submission $DMG_SUBMIT_ID); the next run continues it and publication awaits Accepted" >&2
      if [ -n "${GITHUB_OUTPUT:-}" ]; then
        echo "submission_pending=true" >> "$GITHUB_OUTPUT"
      fi
      exit 0
    fi
  else
    notary_failure="submit exited $NOTARY_SUBMIT_EXIT"
  fi
  if [ -n "$DMG_SUBMIT_ID" ]; then
    echo "DMG notarization $notary_failure for $DMG_RELEASE (submission $DMG_SUBMIT_ID); details: $NOTARY_OUTPUT_FILE" >&2
  else
    echo "DMG notarization $notary_failure for $DMG_RELEASE; no submission id was returned; details: $NOTARY_OUTPUT_FILE" >&2
  fi
  exit 1
fi
if [ -z "$DMG_SUBMIT_ID" ]; then
  save_notary_output
  echo "DMG notarization returned no submission id for $DMG_RELEASE; details: $NOTARY_OUTPUT_FILE" >&2
  exit 1
fi
if [ "$DMG_STATUS" != "Accepted" ]; then
  save_notary_output
  echo "DMG notarization failed for $DMG_RELEASE with status: $DMG_STATUS (submission $DMG_SUBMIT_ID); details: $NOTARY_OUTPUT_FILE" >&2
  exit 1
fi
# An unstapled helper (still in Apple's queue above, here or in the run that
# submitted this DMG) is notarized only through the DMG ticket: every slice
# must be in it.
if [ -d "$COMPUTER_USE_HELPER" ] && ! "$XCRUN_TOOL" stapler validate "$COMPUTER_USE_HELPER" >/dev/null 2>&1; then
  helper_ticket_log="$NOTARY_DIR/dmg-ticket.json"
  "$XCRUN_TOOL" notarytool log "$DMG_SUBMIT_ID" "${NOTARY_AUTH_ARGS[@]}" > "$helper_ticket_log"
  if ! verify_ticket_contents_cover_slices "$helper_ticket_log" "$COMPUTER_USE_HELPER"; then
    echo "The DMG ticket does not cover the unstapled Computer Use helper; refusing to staple" >&2
    exit 1
  fi
fi
# A DMG submission scans nested code and issues a ticket for the exact signed
# app. Require that independently usable ticket before accepting the artifact.
"$XCRUN_TOOL" stapler staple "$APP_PATH"
# The ticket file ships inside the stapled-app DMG: readable by every user,
# whatever umask the notary sidecar writers left.
if [ -f "$APP_PATH/Contents/CodeResources" ]; then chmod 0644 "$APP_PATH/Contents/CodeResources"; fi
"$XCRUN_TOOL" stapler validate "$APP_PATH"
"$SPCTL_TOOL" -a -vv --type execute "$APP_PATH"

# The DMG that ships carries the stapled app (CMUX_STAPLE_APP_IN_DMG, above).
FINAL_DMG="$DMG_RELEASE"
WROTE_ACCEPTED_STATE=false
if [ "$STAPLE_APP_IN_DMG" = true ] && [ "$STAPLED_APP_FALLBACK" = true ]; then
  # Stage-2 fallback (above): the first DMG ships.
  FINAL_DMG="$FIRST_DMG"
elif [ "$STAPLE_APP_IN_DMG" = true ] && [ "${CONTINUE_STAPLED_APP:-}" = true ]; then
  echo "Continued submission $DMG_SUBMIT_ID is the DMG around the stapled app"
elif [ "$STAPLE_APP_IN_DMG" = true ] && [ -n "$CONTINUE_STATE" ] \
  && stapled_app_deadline_passed recovery "" "$(extract_notary_value "$NOTARY_SUBMIT_OUTPUT" createdDate || true)"; then
  # A continuation of the accepted first DMG whose stapled-app DMG has been
  # submitted for 6 h without an Accepted answer: the first DMG ships.
  STAPLED_APP_FALLBACK=true
elif [ "$STAPLE_APP_IN_DMG" = true ] && [ -n "$CONTINUE_STATE" ] && [ "${CMUX_STAPLED_APP_NO_NEW_SUBMISSION:-false}" = true ]; then
  # The recovery job already waits on a newer build's stapled-app DMG: this
  # older build ships only at its own fallback (above), no new submission.
  echo "No new stapled-app submission for this older build; it ships at its 6 h fallback"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "submission_pending=true" >> "$GITHUB_OUTPUT"
    echo "stapled_app_pending=true" >> "$GITHUB_OUTPUT"
  fi
  exit 0
elif [ "$STAPLE_APP_IN_DMG" = true ]; then
  if [ -z "$CONTINUE_STATE" ] && [ -z "$STAPLED_DMG_HANDOFF_FILE" ]; then
    # Record the accepted first submission: when the second one fails, a
    # later run continues this one (the first DMG stays at $DMG_RELEASE) and
    # builds and submits the stapled-app DMG again.
    write_notary_state
    # The recovery artifact needs the log beside the state, whatever fails next.
    save_notary_output
    WROTE_ACCEPTED_STATE=true
  fi
  # Keep the second submission's evidence with the first one's (the legacy
  # resolve step reads Apple's verdict from this log).
  restaple_handoff() {
    {
      printf '\n--- notarytool output for the DMG around the stapled app ---\n'
      cat "$restaple_output"
      if [ -n "$restaple_id" ]; then
        printf '\n--- notarytool log for submission %s ---\n' "$restaple_id"
        "$XCRUN_TOOL" notarytool log "$restaple_id" "${NOTARY_AUTH_ARGS[@]}" || true
      fi
    } >> "$NOTARY_OUTPUT_FILE" 2>&1
    cat "$restaple_output" >&2
  }
  restaple_dir="$DMG_TMP_DIR/stapled-app"
  mkdir -p "$restaple_dir/work"
  # Named for this build: Apple's history of this name is the fallback clock.
  FINAL_DMG="$restaple_dir/$STAPLED_DMG_NAME"
  package_signed_dmg "$APP_PATH" "$FINAL_DMG" "$restaple_dir/work" create-keychain
  "$SIGNING_KEYCHAIN_TOOL" delete
  RESTAPLE_KEYCHAIN_OPEN=false
  restaple_output="$NOTARY_DIR/stapled-app-dmg-submit-output"
  restaple_submitted_at="$(date +%s)"
  restaple_wait=(--wait --timeout "$STAPLED_DMG_WAIT_TIMEOUT")
  if [ -n "$STAPLED_DMG_HANDOFF_FILE" ]; then
    restaple_wait=()
  fi
  set +e
  "$XCRUN_TOOL" notarytool submit "$FINAL_DMG" "${NOTARY_AUTH_ARGS[@]}" \
    --output-format json ${restaple_wait[@]+"${restaple_wait[@]}"} >"$restaple_output" 2>&1
  restaple_exit=$?
  set -e
  restaple_id="$(extract_notary_value "$restaple_output" id || true)"
  restaple_status="$(extract_notary_value "$restaple_output" status || true)"
  if [ -n "$STAPLED_DMG_HANDOFF_FILE" ]; then
    if [ "$restaple_exit" -ne 0 ] || ! [[ "$restaple_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
      cat "$restaple_output" >&2
      echo "The DMG around the stapled app was not submitted (exit $restaple_exit); nothing is published" >&2
      exit 1
    fi
    /bin/mv -f "$FINAL_DMG" "$DMG_RELEASE.stapled-app.dmg"
    {
      printf 'submission_id=%s\n' "$restaple_id"
      printf 'stapled_dmg=%s\n' "$DMG_RELEASE.stapled-app.dmg"
      printf 'dmg_sha256=%s\n' "$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$DMG_RELEASE.stapled-app.dmg")"
      printf 'release_dmg=%s\n' "$DMG_RELEASE"
      printf 'immutable_dmg=%s\n' "$DMG_IMMUTABLE"
      printf 'channel=%s\n' "$CHANNEL"
    } > "$STAPLED_DMG_HANDOFF_FILE"
    echo "Submitted the DMG around the stapled app (submission $restaple_id); finish-stapled-app-dmgs.sh finishes it"
  elif [ "$restaple_exit" -ne 0 ] || [ "$restaple_status" != "Accepted" ]; then
    if [ "$restaple_exit" -ne 0 ] && [ "$PENDING_ON_TIMEOUT" = true ] \
      && { [ "$WROTE_ACCEPTED_STATE" = true ] || [ -n "$CONTINUE_STATE" ]; } \
      && grep -Eiq 'timeout|timed out' "$restaple_output"; then
      restaple_handoff
      if [ "$WROTE_ACCEPTED_STATE" = true ] && [ -n "$restaple_id" ]; then
        # Hand off the second submission itself: the DMG around the stapled
        # app takes the release path, and the state names its submission, so
        # a later run asks Apple about it instead of submitting a new one.
        # If Apple refuses this one, the build is not published; if it is not
        # accepted within 6 h, the first DMG is (see the fallback above).
        # The accepted first DMG travels beside it for the 6 h fallback.
        STATE_FIRST_SUBMISSION_ID="$DMG_SUBMIT_ID"
        STATE_FIRST_DMG_SHA256="$(shasum -a 256 "$DMG_RELEASE" | awk '{print $1}')"
        STATE_STAPLED_SUBMITTED_AT="$restaple_submitted_at"
        /bin/cp "$DMG_RELEASE" "$FIRST_DMG"
        /bin/mv -f "$FINAL_DMG" "$DMG_RELEASE"
        DMG_SUBMIT_ID="$restaple_id"
        DMG_STATUS="In Progress"
        NOTARY_SUBMIT_EXIT="$restaple_exit"
        NOTARY_WAIT_TIMED_OUT=true
        STATE_STAPLED_APP=true
        write_notary_state
        echo "The DMG around the stapled app (submission $restaple_id) did not finish within $STAPLED_DMG_WAIT_TIMEOUT; a later run continues that submission" >&2
      else
        # A continuation cannot hand off a new artifact: a later run continues
        # the accepted first submission and submits the stapled-app DMG again.
        echo "The DMG around the stapled app (submission ${restaple_id:-unknown}) did not finish within $STAPLED_DMG_WAIT_TIMEOUT; a later run continues accepted submission $DMG_SUBMIT_ID and submits that DMG again" >&2
      fi
      if [ -n "${GITHUB_OUTPUT:-}" ]; then
        echo "submission_pending=true" >> "$GITHUB_OUTPUT"
        echo "stapled_app_pending=true" >> "$GITHUB_OUTPUT"
      fi
      exit 0
    fi
    restaple_handoff
    echo "Notarization of the DMG around the stapled app failed (submission ${restaple_id:-none}, status ${restaple_status:-unknown}, exit $restaple_exit); the first DMG (submission $DMG_SUBMIT_ID) stays unpublished" >&2
    exit 1
  else
    echo "Apple accepted the DMG around the stapled app (submission $restaple_id)"
  fi
fi
# Apple is done with this artifact; the app below must not find the key.
notary_auth_forget "$NOTARY_DIR"
launch_smokes "$APP_PATH"
"$VERIFY_METADATA_TOOL" "$APP_PATH" "$CHANNEL"
"$VERIFY_LICENSES_TOOL" "$APP_PATH"
if [ "$STAPLE_APP_IN_DMG" = true ] && [ -n "$STAPLED_DMG_HANDOFF_FILE" ]; then
  # finish-stapled-app-dmgs.sh staples and checks the DMG and the app inside.
  exit 0
fi

"$XCRUN_TOOL" stapler staple "$FINAL_DMG"
"$XCRUN_TOOL" stapler validate "$FINAL_DMG"

# Validate the delivered app inside the final stapled DMG, not only the source
# bundle that create-dmg consumed.
if [ -n "${CMUX_NIGHTLY_MOUNT_DIR:-}" ]; then
  MOUNT_DIR="$CMUX_NIGHTLY_MOUNT_DIR"
  mkdir -p "$MOUNT_DIR"
else
  MOUNT_DIR="$(mktemp -d)"
fi
"$HDIUTIL_TOOL" attach "$FINAL_DMG" -nobrowse -readonly -mountpoint "$MOUNT_DIR"
MOUNTED_APP="$(find "$MOUNT_DIR" -maxdepth 1 -name '*.app' -type d -print -quit)"
if [ -z "$MOUNTED_APP" ]; then
  echo "No app found in mounted $CHANNEL DMG" >&2
  exit 1
fi
if [ "$STAPLE_APP_IN_DMG" = true ] && [ "$STAPLED_APP_FALLBACK" != true ]; then
  # The shipped app has its own ticket, not only the DMG's.
  "$XCRUN_TOOL" stapler validate "$MOUNTED_APP"
fi
"$SPCTL_TOOL" -a -vv --type execute "$MOUNTED_APP"
launch_smokes "$MOUNTED_APP"
"$VERIFY_METADATA_TOOL" "$MOUNTED_APP" "$CHANNEL"
"$VERIFY_LICENSES_TOOL" "$MOUNTED_APP"
detach_mounted_dmg

if [ "$FINAL_DMG" != "$DMG_RELEASE" ]; then
  /bin/mv -f "$FINAL_DMG" "$DMG_RELEASE"
fi
if [ "$WROTE_ACCEPTED_STATE" = true ]; then
  # Nothing is pending: drop the handoff record of the first submission.
  rm -f "$NOTARY_SUBMISSION_FILE" "$NOTARY_OUTPUT_FILE"
fi
rm -f "$FIRST_DMG"
cp "$DMG_RELEASE" "$DMG_IMMUTABLE"
if [ "$STAPLED_APP_FALLBACK" = true ]; then
  echo "::warning title=App shipped without its own ticket::Apple did not accept the stapled-app DMG (submission $STAPLED_APP_FALLBACK_ID) within ${STAPLED_APP_FALLBACK_SECONDS}s of its first submission; the first DMG (notarized and stapled) ships, and the app inside it needs Apple's online ticket lookup."
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "stapled_app_fallback=true" >> "$GITHUB_OUTPUT"
    echo "stapled_app_pending_id=$STAPLED_APP_FALLBACK_ID" >> "$GITHUB_OUTPUT"
  fi
fi
