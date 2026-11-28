#!/usr/bin/env bash
set -euo pipefail

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
# false keeps one DMG submission. CMUX_NOTARY_SUBMIT_ONLY never reaches it:
# resume-nightly-notarization.sh continues that path.
STAPLE_APP_IN_DMG="${CMUX_STAPLE_APP_IN_DMG:-true}"
# CMUX_STAPLED_DMG_HANDOFF_FILE: submit the DMG around the stapled app without
# a wait, keep it as <release-dmg>.stapled-app.dmg, write this record and stop
# after the app checks; scripts/ci/finish-stapled-app-dmgs.sh waits for several
# such submissions at once and finishes them (release.yml's thin variants).
STAPLED_DMG_HANDOFF_FILE="${CMUX_STAPLED_DMG_HANDOFF_FILE:-}"
case "$STAPLE_APP_IN_DMG" in
  true|false) ;;
  *) echo "CMUX_STAPLE_APP_IN_DMG must be true or false, got: $STAPLE_APP_IN_DMG" >&2; exit 2 ;;
esac
# Release channel of the app being packaged: `nightly` (default), `rc` or
# `stable`. It selects the entitlements file and the bundle-metadata check; the
# packaging, notarization, and stapling steps are identical for every channel.
CHANNEL="${CMUX_CHANNEL:-nightly}"
case "$CHANNEL" in
  nightly|rc) DEFAULT_ENTITLEMENTS="$ROOT_DIR/cmux.${CHANNEL}.entitlements" ;;
  stable) DEFAULT_ENTITLEMENTS="$ROOT_DIR/cmux.release.entitlements" ;;
  *)
    echo "Unsupported CMUX_CHANNEL: $CHANNEL (expected nightly, rc or stable)" >&2
    exit 2
    ;;
esac
APP_ENTITLEMENTS="${CMUX_APP_ENTITLEMENTS:-$DEFAULT_ENTITLEMENTS}"
# shellcheck source=lib/notary-auth.sh
source "$ROOT_DIR/scripts/ci/lib/notary-auth.sh"

if [ ! -d "$APP_PATH/Contents" ]; then
  echo "Signed app not found: $APP_PATH" >&2
  exit 1
fi
if [ "$SKIP_NOTARIZATION" != true ] \
  && { [ -z "${ASC_API_KEY_ID:-}" ] || [ -z "${ASC_API_ISSUER_ID:-}" ] || [ -z "${ASC_API_KEY_P8_BASE64:-}" ]; }; then
  echo "Missing notarization secrets (ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_P8_BASE64)" >&2
  exit 1
fi
if [ -z "${APPLE_SIGNING_IDENTITY:-}" ]; then
  echo "Missing APPLE_SIGNING_IDENTITY" >&2
  exit 1
fi
# The DMG around the stapled app is signed after Apple's wait, so its signing
# inputs must be present before any submission.
if [ "$SKIP_NOTARIZATION" != true ] && [ "$STAPLE_APP_IN_DMG" = true ] \
  && [ "${CMUX_NOTARY_SUBMIT_ONLY:-false}" != true ] \
  && { [ -z "${APPLE_CERTIFICATE_BASE64:-}" ] || [ -z "${APPLE_CERTIFICATE_PASSWORD:-}" ]; }; then
  echo "Missing APPLE_CERTIFICATE_BASE64 or APPLE_CERTIFICATE_PASSWORD: the DMG around the stapled app is signed again (CMUX_STAPLE_APP_IN_DMG=false ships the app unstapled)" >&2
  exit 1
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
  if [ -n "$MOUNT_DIR" ]; then
    detach_mounted_dmg || true
  fi
  if [ "$RESTAPLE_KEYCHAIN_OPEN" = true ]; then
    "${SIGNING_KEYCHAIN_TOOL}" delete || true
  fi
  rm -rf "$DMG_TMP_DIR"
}
trap cleanup EXIT
NOTARY_DIR="$DMG_TMP_DIR/notary"
mkdir -m 700 "$NOTARY_DIR"
if [ "$SKIP_NOTARIZATION" != true ]; then
  notary_auth_init "$NOTARY_DIR"
fi

if [ "$SKIP_NOTARIZATION" = true ]; then
  echo "Skipping Computer Use and outer notarization for internal dogfood artifact"
elif [ "${CMUX_COMPUTER_USE_HELPER_ALREADY_FINISHED:-false}" = true ]; then
  echo "Computer Use helper was finished by the recovery continuation"
elif [ -n "$COMPUTER_USE_NOTARY_SUBMISSION_FILE" ]; then
  "$NOTARIZE_COMPUTER_USE_HELPER_TOOL" \
    --finish "$COMPUTER_USE_NOTARY_SUBMISSION_FILE" \
    "$APP_PATH" \
    "$APP_ENTITLEMENTS" \
    "$APPLE_SIGNING_IDENTITY"
else
  "$NOTARIZE_COMPUTER_USE_HELPER_TOOL" \
    "$APP_PATH" \
    "$APP_ENTITLEMENTS" \
    "$APPLE_SIGNING_IDENTITY"
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

# CMUX_PACKAGE_CREATES_KEYCHAIN=true: make the signing keychain just before
# this signature (resume-stapled-app-notarization.sh, which passes the
# certificate only to this tool).
if [ "${CMUX_PACKAGE_CREATES_KEYCHAIN:-false}" = true ]; then
  package_signed_dmg "$APP_PATH" "$DMG_RELEASE" "$DMG_TMP_DIR" create-keychain
else
  package_signed_dmg "$APP_PATH" "$DMG_RELEASE" "$DMG_TMP_DIR"
fi
# This is the last signature. Delete the CI signing keychain before Apple's
# wait and before the launch smokes below run code from the bundle.
"$SIGNING_KEYCHAIN_TOOL" delete

if [ "$SKIP_NOTARIZATION" = true ]; then
  # Fast dogfood DMGs are signed and smoke-tested by the workflow, but are not
  # eligible for distribution or Apple ticketing. Keep the exact signed image
  # for the internal artifact upload and stop before any stapling work.
  cp "$DMG_RELEASE" "$DMG_IMMUTABLE"
  exit 0
fi

# notarytool writes timeout diagnostics to stderr, so command substitution alone
# loses the submission id when --wait reaches its deadline. Keep both streams in
# a durable sidecar, and always fail closed until a later run verifies Accepted.
# The sidecar is evidence for a separate follow-up workflow: this helper does
# not consume a stale submission or staple an unaccepted DMG in the same job.
# A follow-up must retain this exact DMG, verify its recorded SHA-256, wait on
# the recorded submission id, and only then run the stapling and publication
# checks below.
NOTARY_WAIT_TIMEOUT="${CMUX_NOTARY_WAIT_TIMEOUT:-25m}"
SUBMIT_ONLY="${CMUX_NOTARY_SUBMIT_ONLY:-false}"
# The wait for the DMG around the stapled app (CMUX_STAPLE_APP_IN_DMG).
STAPLED_DMG_WAIT_TIMEOUT="${CMUX_STAPLED_DMG_WAIT_TIMEOUT:-$NOTARY_WAIT_TIMEOUT}"
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
if [ "$SUBMIT_ONLY" != true ]; then
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
    # The DMG around the stapled app (resume-stapled-app-notarization.sh).
    if [ "${CMUX_NOTARY_STATE_STAPLED_APP:-false}" = true ]; then
      printf 'stapled_app=true\n'
      # The 6 h fallback clock and the accepted first DMG it ships.
      printf 'stapled_submitted_at=%s\n' "$DMG_SUBMITTED_AT"
      printf 'first_submission_id=%s\n' "${CMUX_NOTARY_STATE_FIRST_SUBMISSION_ID:-}"
      printf 'first_dmg_sha256=%s\n' "${CMUX_NOTARY_STATE_FIRST_DMG_SHA256:-}"
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

if [ -n "$DMG_SUBMIT_ID" ] \
  && { [ "$NOTARY_SUBMIT_EXIT" -ne 0 ] || [ "$DMG_STATUS" != "Accepted" ]; }; then
  write_notary_state
fi
if [ "$NOTARY_SUBMIT_EXIT" -ne 0 ]; then
  save_notary_output
  if grep -Eiq 'timeout|timed out' "$NOTARY_OUTPUT_FILE"; then
    notary_failure="did not finish within $NOTARY_WAIT_TIMEOUT"
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

# A DMG submission scans nested code and issues a ticket for the exact signed
# app. Require that independently usable ticket before accepting the artifact.
"$XCRUN_TOOL" stapler staple "$APP_PATH"
# The ticket in Contents/CodeResources must be readable by every user.
[ ! -e "$APP_PATH/Contents/CodeResources" ] || chmod 0644 "$APP_PATH/Contents/CodeResources"
"$XCRUN_TOOL" stapler validate "$APP_PATH"
"$SPCTL_TOOL" -a -vv --type execute "$APP_PATH"

# The DMG that ships carries the stapled app (CMUX_STAPLE_APP_IN_DMG, above).
FINAL_DMG="$DMG_RELEASE"
if [ "$STAPLE_APP_IN_DMG" = true ]; then
  restaple_dir="$DMG_TMP_DIR/stapled-app"
  mkdir -p "$restaple_dir/work"
  FINAL_DMG="$restaple_dir/$(basename "$DMG_RELEASE")"
  package_signed_dmg "$APP_PATH" "$FINAL_DMG" "$restaple_dir/work" create-keychain
  "$SIGNING_KEYCHAIN_TOOL" delete
  RESTAPLE_KEYCHAIN_OPEN=false
  restaple_output="$NOTARY_DIR/stapled-app-dmg-submit-output"
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
    cat "$restaple_output" >&2
    if [ -n "$restaple_id" ]; then
      "$XCRUN_TOOL" notarytool log "$restaple_id" "${NOTARY_AUTH_ARGS[@]}" >&2 || true
    fi
    echo "Notarization of the DMG around the stapled app failed (submission ${restaple_id:-none}, status ${restaple_status:-unknown}, exit $restaple_exit); nothing is published" >&2
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
if [ "$STAPLE_APP_IN_DMG" = true ]; then
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
cp "$DMG_RELEASE" "$DMG_IMMUTABLE"
