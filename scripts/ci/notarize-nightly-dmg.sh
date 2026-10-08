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
VERIFY_LICENSES_TOOL="${CMUX_VERIFY_LICENSES_TOOL:-$ROOT_DIR/scripts/verify-app-bundle-licenses.sh}"
NOTARIZE_COMPUTER_USE_HELPER_TOOL="${CMUX_NOTARIZE_COMPUTER_USE_HELPER_TOOL:-$ROOT_DIR/scripts/ci/notarize-computer-use-helper.sh}"
COMPUTER_USE_NOTARY_SUBMISSION_FILE="${CMUX_COMPUTER_USE_NOTARY_SUBMISSION_FILE:-}"
SKIP_NOTARIZATION="${CMUX_SKIP_NOTARIZATION:-false}"
# Release channel of the app being packaged: `nightly` (default) or `rc`. It
# selects the entitlements file and the bundle-metadata check; the packaging,
# notarization, and stapling steps are identical for both.
CHANNEL="${CMUX_CHANNEL:-nightly}"
case "$CHANNEL" in
  nightly|rc) ;;
  *)
    echo "Unsupported CMUX_CHANNEL: $CHANNEL (expected nightly or rc)" >&2
    exit 2
    ;;
esac
APP_ENTITLEMENTS="${CMUX_APP_ENTITLEMENTS:-$ROOT_DIR/cmux.${CHANNEL}.entitlements}"
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

DMG_TMP_DIR="$(mktemp -d)"
MOUNT_DIR=""
detach_mounted_dmg() {
  [ -n "$MOUNT_DIR" ] || return 0
  "$HDIUTIL_TOOL" detach "$MOUNT_DIR" || "$HDIUTIL_TOOL" detach -force "$MOUNT_DIR"
  rmdir "$MOUNT_DIR"
  MOUNT_DIR=""
}
cleanup() {
  if [ -n "$MOUNT_DIR" ]; then
    detach_mounted_dmg || true
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

"$CREATE_DMG_TOOL" --no-code-sign "$APP_PATH" "$DMG_TMP_DIR"
CREATED_DMG="$(find "$DMG_TMP_DIR" -maxdepth 1 -name '*.dmg' -print -quit)"
if [ -z "$CREATED_DMG" ]; then
  echo "Failed to locate created DMG for $APP_PATH" >&2
  exit 1
fi
# create-dmg emits an LZFSE (ULFO) image. Re-encode to LZMA (ULMO): same bundle,
# about a quarter smaller download, and every supported macOS (14+) mounts it.
"$HDIUTIL_TOOL" convert "$CREATED_DMG" -quiet -format ULMO -ov -o "$DMG_RELEASE"
rm -f "$CREATED_DMG"
DMG_FORMAT="$("$HDIUTIL_TOOL" imageinfo "$DMG_RELEASE" | awk -F': *' '/^Format:/ {print $2; exit}')"
if [ "$DMG_FORMAT" != "ULMO" ]; then
  echo "Expected ULMO (LZMA) DMG after conversion, got: ${DMG_FORMAT:-unknown}" >&2
  exit 1
fi

"$CODESIGN_TOOL" --force --timestamp --keychain build.keychain \
  --sign "$APPLE_SIGNING_IDENTITY" \
  "$DMG_RELEASE"
"$CODESIGN_TOOL" --verify --verbose=2 "$DMG_RELEASE"

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
notary_submit_args=(notarytool submit "$DMG_RELEASE" "${NOTARY_AUTH_ARGS[@]}" --output-format json)
if [ "$SUBMIT_ONLY" != true ]; then
  notary_submit_args+=(--wait --timeout "$NOTARY_WAIT_TIMEOUT")
fi
set +e
"$XCRUN_TOOL" "${notary_submit_args[@]}" >"$NOTARY_SUBMIT_OUTPUT" 2>&1
NOTARY_SUBMIT_EXIT=$?
set -e

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
  } > "$state_tmp"
  /bin/mv "$state_tmp" "$NOTARY_SUBMISSION_FILE"
}

save_notary_output() {
  # The output file is intentionally retained after a failed run. It is the
  # evidence needed to resume the exact Apple submission in a follow-up job.
  umask 077
  /bin/cp "$NOTARY_SUBMIT_OUTPUT" "$NOTARY_OUTPUT_FILE"
  if [ -n "$DMG_SUBMIT_ID" ]; then
    {
      printf '\n--- notarytool log for submission %s ---\n' "$DMG_SUBMIT_ID"
      "$XCRUN_TOOL" notarytool log "$DMG_SUBMIT_ID" "${NOTARY_AUTH_ARGS[@]}" || true
    } >> "$NOTARY_OUTPUT_FILE" 2>&1
  fi
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
"$XCRUN_TOOL" stapler validate "$APP_PATH"
"$SPCTL_TOOL" -a -vv --type execute "$APP_PATH"
CMUX_SMOKE_ALLOW_UNSUPPORTED_GUI=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$APP_PATH"
CMUX_SMOKE_DIRECT_EXEC=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$APP_PATH"
"$VERIFY_METADATA_TOOL" "$APP_PATH" "$CHANNEL"
"$VERIFY_LICENSES_TOOL" "$APP_PATH"

"$XCRUN_TOOL" stapler staple "$DMG_RELEASE"
"$XCRUN_TOOL" stapler validate "$DMG_RELEASE"

# Validate the delivered app inside the final stapled DMG, not only the source
# bundle that create-dmg consumed.
if [ -n "${CMUX_NIGHTLY_MOUNT_DIR:-}" ]; then
  MOUNT_DIR="$CMUX_NIGHTLY_MOUNT_DIR"
  mkdir -p "$MOUNT_DIR"
else
  MOUNT_DIR="$(mktemp -d)"
fi
"$HDIUTIL_TOOL" attach "$DMG_RELEASE" -nobrowse -readonly -mountpoint "$MOUNT_DIR"
MOUNTED_APP="$(find "$MOUNT_DIR" -maxdepth 1 -name '*.app' -type d -print -quit)"
if [ -z "$MOUNTED_APP" ]; then
  echo "No app found in mounted $CHANNEL DMG" >&2
  exit 1
fi
"$SPCTL_TOOL" -a -vv --type execute "$MOUNTED_APP"
CMUX_SMOKE_ALLOW_UNSUPPORTED_GUI=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$MOUNTED_APP"
CMUX_SMOKE_DIRECT_EXEC=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$MOUNTED_APP"
"$VERIFY_METADATA_TOOL" "$MOUNTED_APP" "$CHANNEL"
"$VERIFY_LICENSES_TOOL" "$MOUNTED_APP"
detach_mounted_dmg

cp "$DMG_RELEASE" "$DMG_IMMUTABLE"
