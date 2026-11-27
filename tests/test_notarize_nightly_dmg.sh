#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ci/notarize-nightly-dmg.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: executable nightly notarization helper is required" >&2
  exit 1
fi

APP="$TMP_DIR/input/cmux NIGHTLY.app"
DMG="$TMP_DIR/cmux-nightly-macos.dmg"
IMMUTABLE="$TMP_DIR/cmux-nightly-immutable.dmg"
FAKE_BIN="$TMP_DIR/bin"
# The stapled-app DMG (CMUX_STAPLE_APP_IN_DMG) has its own cases below; every
# other case keeps one DMG submission.
export CMUX_STAPLE_APP_IN_DMG=false
LOG="$TMP_DIR/calls.log"
HELPER_STATE="$TMP_DIR/helper-notarization.state"
mkdir -p "$APP/Contents/MacOS" "$FAKE_BIN"
printf 'signed-app-fixture\n' > "$APP/Contents/MacOS/cmux"
printf 'submission_id=fixture-id\ncdhash=fixture-cdhash\n' > "$HELPER_STATE"

cat > "$FAKE_BIN/create-dmg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'create-dmg %s\n' "$*" >> "$CMUX_TEST_CALL_LOG"
printf 'create-dmg-umask %s\n' "$(umask)" >> "$CMUX_TEST_CALL_LOG"
output_dir="${@: -1}"
mkdir -p "$output_dir"
printf 'dmg-fixture\n' > "$output_dir/created.dmg"
EOF

cat > "$FAKE_BIN/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'codesign %s\n' "$*" >> "$CMUX_TEST_CALL_LOG"
EOF

cat > "$FAKE_BIN/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcrun %s\n' "$*" >> "$CMUX_TEST_CALL_LOG"
if [ "${1:-}" = "notarytool" ]; then
  key="" key_id="" issuer="" prev=""
  for arg in "$@"; do
    case "$prev" in
      --key) key="$arg" ;;
      --key-id) key_id="$arg" ;;
      --issuer) issuer="$arg" ;;
      --apple-id|--password|--team-id) echo "fake xcrun: Apple ID credentials must not be used" >&2; exit 90 ;;
    esac
    prev="$arg"
  done
  [ -f "$key" ] || { echo "fake xcrun: --key file missing" >&2; exit 91; }
  [ "$(stat -c %a "$key" 2>/dev/null || stat -f %Lp "$key")" = 600 ] || { echo "fake xcrun: --key file must be mode 600" >&2; exit 92; }
  [ "$(cat "$key")" = fixture-p8 ] || { echo "fake xcrun: --key file content" >&2; exit 93; }
  [ "$key_id" = FIXTUREKEY ] && [ "$issuer" = fixture-issuer ] || { echo "fake xcrun: key id or issuer" >&2; exit 94; }
  printf 'notary-key %s\n' "$key" >> "$CMUX_TEST_CALL_LOG"
fi
if [ "${1:-}" = "notarytool" ] && [ "${2:-}" = "wait" ]; then
  printf '{"id":"%s","status":"%s"}\n' "${3:-}" "${CMUX_TEST_WAIT_STATUS:-Accepted}"
  exit 0
fi
if [ "${1:-}" = "notarytool" ] && [ "${2:-}" = "submit" ] && [[ "${3:-}" == */stapled-app/* ]]; then
  # The second submission: the DMG rebuilt around the stapled app.
  printf '{"id":"fixture-stapled-id","status":"%s"}\n' "${CMUX_TEST_STAPLED_STATUS:-Accepted}"
  exit 0
fi
if [ "${1:-}" = "notarytool" ] && [ "${2:-}" = "submit" ]; then
  if [ "${CMUX_TEST_NOTARY_TIMEOUT:-0}" = 1 ]; then
    # notarytool writes a timeout response to stderr. The submission remains
    # In Progress and must never reach the stapling or publication path.
    printf '{"message":"Timeout of 25m reached before processing completed.","id":"fixture-id"}\n' >&2
    exit 1
  fi
  if [ "${CMUX_TEST_NOTARY_FAILURE:-0}" = 1 ]; then
    printf 'network failure while uploading submission\n' >&2
    exit 7
  fi
  printf '{"id":"fixture-id","status":"%s"}\n' "${CMUX_TEST_NOTARY_STATUS:-Accepted}"
fi
if [ "${1:-}" = "notarytool" ] && [ "${2:-}" = "log" ] && [ "${3:-}" = fixture-stapled-id ]; then
  printf '{"id":"fixture-stapled-id","status":"%s"}\n' "${CMUX_TEST_WAIT_STATUS:-Accepted}"
  exit 0
fi
if [ "${1:-}" = "notarytool" ] && [ "${2:-}" = "log" ]; then
  printf '{"id":"fixture-id","status":"In Progress","message":"still processing"}\n' >&2
fi
EOF

cat > "$FAKE_BIN/hdiutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'hdiutil %s\n' "$*" >> "$CMUX_TEST_CALL_LOG"
case "${1:-}" in
  convert)
    # hdiutil convert <in> -quiet -format ULMO -ov -o <out>
    printf 'dmg-fixture-ulmo\n' > "${@: -1}"
    ;;
  imageinfo)
    printf 'Format: %s\n' "${CMUX_TEST_DMG_FORMAT:-ULMO}"
    ;;
  attach)
    mount_dir="${@: -1}"
    cp -R "$CMUX_TEST_SOURCE_APP" "$mount_dir/cmux NIGHTLY.app"
    ;;
  detach)
    if [ "${2:-}" != "-force" ] && [ ! -f "$CMUX_TEST_DETACH_STATE" ]; then
      : > "$CMUX_TEST_DETACH_STATE"
      exit 16
    fi
    mount_dir="${@: -1}"
    find "$mount_dir" -mindepth 1 -delete
    ;;
esac
EOF

for tool in spctl smoke metadata licenses; do
  cat > "$FAKE_BIN/$tool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$(basename "$0")" "$*" >> "$CMUX_TEST_CALL_LOG"
EOF
done

cat > "$FAKE_BIN/notarize-computer-use-helper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'notarize-helper %s\n' "$*" >> "$CMUX_TEST_CALL_LOG"
EOF
chmod +x "$FAKE_BIN"/*

FIXTURE_P8_BASE64="$(printf 'fixture-p8' | base64)"

run_helper() {
  local app="${1:-$APP}" dmg="${2:-$DMG}" immutable="${3:-$IMMUTABLE}"
  CMUX_TEST_CALL_LOG="$LOG" \
  CMUX_TEST_SOURCE_APP="$app" \
  CMUX_TEST_DETACH_STATE="$TMP_DIR/detach-retried" \
  CMUX_NIGHTLY_MOUNT_DIR="$TMP_DIR/cmux-nightly-mount" \
  CMUX_CREATE_DMG_TOOL="$FAKE_BIN/create-dmg" \
  CMUX_CODESIGN_TOOL="$FAKE_BIN/codesign" \
  CMUX_XCRUN_TOOL="$FAKE_BIN/xcrun" \
  CMUX_HDIUTIL_TOOL="$FAKE_BIN/hdiutil" \
  CMUX_SPCTL_TOOL="$FAKE_BIN/spctl" \
  CMUX_SMOKE_TOOL="$FAKE_BIN/smoke" \
  CMUX_VERIFY_METADATA_TOOL="$FAKE_BIN/metadata" \
  CMUX_VERIFY_LICENSES_TOOL="$FAKE_BIN/licenses" \
  CMUX_NOTARIZE_COMPUTER_USE_HELPER_TOOL="$FAKE_BIN/notarize-computer-use-helper" \
  CMUX_COMPUTER_USE_NOTARY_SUBMISSION_FILE="$HELPER_STATE" \
  CMUX_NOTARY_SUBMIT_ONLY="${TEST_NOTARY_SUBMIT_ONLY:-false}" \
  CMUX_STAPLE_APP_IN_DMG="${TEST_STAPLE_APP_IN_DMG:-false}" \
  GITHUB_OUTPUT="${GITHUB_OUTPUT:-}" \
  CMUX_APP_ENTITLEMENTS="$TMP_DIR/cmux.nightly.entitlements" \
  ASC_API_KEY_ID="${TEST_ASC_API_KEY_ID-FIXTUREKEY}" \
  ASC_API_ISSUER_ID="${TEST_ASC_API_ISSUER_ID-fixture-issuer}" \
  ASC_API_KEY_P8_BASE64="${TEST_ASC_API_KEY_P8_BASE64-$FIXTURE_P8_BASE64}" \
  APPLE_SIGNING_IDENTITY='Developer ID Application: Fixture' \
  "$SCRIPT" "$app" "$dmg" "$immutable"
}

run_helper

if [ -e "$DMG.notarization.state" ] || [ -e "$DMG.notarization.log" ]; then
  echo "FAIL: accepted notarization must not leave resumable sidecars" >&2
  exit 1
fi

if ! grep -Fxq \
  "notarize-helper --finish $HELPER_STATE $APP $TMP_DIR/cmux.nightly.entitlements Developer ID Application: Fixture" \
  "$LOG"; then
  echo "FAIL: nightly packaging did not finish the early Computer Use notarization" >&2
  exit 1
fi
if ! grep -q '^notary-key ' "$LOG"; then
  echo "FAIL: notarytool did not authenticate with the team API key" >&2
  exit 1
fi
while read -r _ key_path; do
  if [ -e "$key_path" ]; then
    echo "FAIL: decoded API key was left on disk: $key_path" >&2
    exit 1
  fi
done < <(grep '^notary-key ' "$LOG")
for missing in TEST_ASC_API_KEY_ID TEST_ASC_API_ISSUER_ID TEST_ASC_API_KEY_P8_BASE64; do
  before="$(grep -c '^xcrun notarytool ' "$LOG" || true)"
  rm -rf "$TMP_DIR/cmux-nightly-mount"
  if (export "$missing="; run_helper) >/dev/null 2>&1; then
    echo "FAIL: notarization must fail when ${missing#TEST_} is empty" >&2
    exit 1
  fi
  if [ "$(grep -c '^xcrun notarytool ' "$LOG" || true)" != "$before" ]; then
    echo "FAIL: notarytool ran without ${missing#TEST_}" >&2
    exit 1
  fi
done
before_custom_sidecar_submit="$(grep -c '^xcrun notarytool submit ' "$LOG" || true)"
if CMUX_NOTARY_SUBMISSION_FILE="$TMP_DIR/missing-notary/state" \
  CMUX_NOTARY_OUTPUT_FILE="$TMP_DIR/missing-notary/output" \
  run_helper >/dev/null 2>&1; then
  echo "FAIL: missing custom notary sidecar directory unexpectedly succeeded" >&2
  exit 1
fi
after_custom_sidecar_submit="$(grep -c '^xcrun notarytool submit ' "$LOG" || true)"
if [ "$after_custom_sidecar_submit" != "$before_custom_sidecar_submit" ]; then
  echo "FAIL: custom sidecar path must be validated before submission" >&2
  exit 1
fi
echo "PASS: nightly notarization uses the team API key and deletes it"
if [ "$(grep -c '^xcrun notarytool submit ' "$LOG")" -ne 1 ]; then
  echo "FAIL: expected exactly one notarization submission" >&2
  exit 1
fi
if ! grep -Fq "xcrun notarytool submit $DMG" "$LOG"; then
  echo "FAIL: final DMG was not the notarization submission" >&2
  exit 1
fi

line_of() {
  grep -nF "$1" "$LOG" | head -n 1 | cut -d: -f1
}
submit_line="$(line_of "xcrun notarytool submit $DMG")"
helper_notary_line="$(line_of "notarize-helper --finish $HELPER_STATE $APP")"
create_dmg_line="$(line_of "create-dmg --no-code-sign $APP")"
convert_line="$(line_of "hdiutil convert ")"
dmg_sign_line="$(line_of "codesign --force --timestamp --keychain build.keychain --sign Developer ID Application: Fixture $DMG")"
if [ -z "$convert_line" ] || [ -z "$dmg_sign_line" ] || ! [ "$create_dmg_line" -lt "$convert_line" ] || ! [ "$convert_line" -lt "$dmg_sign_line" ]; then
  echo "FAIL: DMG must be re-encoded to LZMA between create-dmg and DMG signing" >&2
  exit 1
fi
if ! grep -Fq "hdiutil convert" "$LOG" || ! grep -Eq "hdiutil convert .* -format ULMO .* -o $DMG\$" "$LOG"; then
  echo "FAIL: DMG was not converted to ULMO at $DMG" >&2
  exit 1
fi
app_staple_line="$(line_of "xcrun stapler staple $APP")"
dmg_staple_line="$(line_of "xcrun stapler staple $DMG")"
attach_line="$(line_of "hdiutil attach $DMG")"
mounted_spctl_line="$(line_of "spctl -a -vv --type execute $TMP_DIR/cmux-nightly-mount")"
if ! [ "$helper_notary_line" -lt "$create_dmg_line" ] \
  || ! [ "$submit_line" -lt "$app_staple_line" ] \
  || ! [ "$app_staple_line" -lt "$dmg_staple_line" ] \
  || ! [ "$dmg_staple_line" -lt "$attach_line" ] \
  || ! [ "$attach_line" -lt "$mounted_spctl_line" ]; then
  echo "FAIL: notarization, ticket, and delivered-DMG checks ran out of order" >&2
  exit 1
fi

if [ "$(grep -c '^smoke ' "$LOG")" -ne 4 ]; then
  echo "FAIL: source and mounted apps must each run GUI and direct launch smokes" >&2
  exit 1
fi
for expected in \
  "metadata $APP nightly" \
  "licenses $APP" \
  "metadata $TMP_DIR/cmux-nightly-mount/cmux NIGHTLY.app nightly" \
  "licenses $TMP_DIR/cmux-nightly-mount/cmux NIGHTLY.app"; do
  if ! grep -Fxq "$expected" "$LOG"; then
    echo "FAIL: missing source or delivered-app validation: $expected" >&2
    exit 1
  fi
done
if [ "$(grep -c '^hdiutil detach ' "$LOG")" -ne 2 ] \
  || ! grep -Fq "hdiutil detach -force $TMP_DIR/cmux-nightly-mount" "$LOG"; then
  echo "FAIL: busy DMG detach must fall back to forced cleanup" >&2
  exit 1
fi
if [ ! -f "$IMMUTABLE" ] || ! cmp -s "$DMG" "$IMMUTABLE"; then
  echo "FAIL: verified final DMG was not copied to the immutable artifact" >&2
  exit 1
fi

: > "$LOG"
if CMUX_TEST_NOTARY_STATUS=Rejected run_helper; then
  echo "FAIL: rejected notarization unexpectedly succeeded" >&2
  exit 1
fi
if grep -Fq 'xcrun stapler staple' "$LOG"; then
  echo "FAIL: rejected DMG must not be stapled" >&2
  exit 1
fi

# A timeout response is emitted on stderr by notarytool. Preserve that output,
# extract its submission id, and retain a state file for a follow-up wait. The
# current job must still fail closed because no Accepted ticket exists yet.
: > "$LOG"
TIMEOUT_STATE="$TMP_DIR/cmux-nightly-timeout.state"
TIMEOUT_OUTPUT="$TMP_DIR/cmux-nightly-timeout.log"
rm -f "$TIMEOUT_STATE" "$TIMEOUT_OUTPUT"
rm -rf "$TMP_DIR/cmux-nightly-mount"
if CMUX_TEST_NOTARY_TIMEOUT=1 \
  CMUX_NOTARY_SUBMISSION_FILE="$TIMEOUT_STATE" \
  CMUX_NOTARY_OUTPUT_FILE="$TIMEOUT_OUTPUT" \
  run_helper >/dev/null 2>"$TMP_DIR/timeout.err"; then
  echo "FAIL: a timed-out notarization unexpectedly succeeded" >&2
  exit 1
fi
if ! grep -q "submission fixture-id" "$TMP_DIR/timeout.err" \
  || ! grep -q "Timeout of 25m reached" "$TIMEOUT_OUTPUT" \
  || ! grep -q "still processing" "$TIMEOUT_OUTPUT"; then
  echo "FAIL: timed-out notarization did not preserve its id and diagnostics" >&2
  cat "$TMP_DIR/timeout.err" "$TIMEOUT_OUTPUT" >&2
  exit 1
fi
if ! grep -Fxq "submission_id=fixture-id" "$TIMEOUT_STATE" \
  || ! grep -Fxq "status=unknown" "$TIMEOUT_STATE" \
  || ! grep -Fxq "dmg_path=$DMG" "$TIMEOUT_STATE"; then
  echo "FAIL: timed-out notarization state was not persisted" >&2
  cat "$TIMEOUT_STATE" >&2
  exit 1
fi
if ! grep -q '^xcrun notarytool log fixture-id ' "$LOG"; then
  echo "FAIL: timeout path did not request the Apple notarization log" >&2
  exit 1
fi
if grep -Fq 'xcrun stapler staple' "$LOG"; then
  echo "FAIL: a timed-out DMG must not be stapled" >&2
  exit 1
fi

# Published variants submit once and leave Apple's asynchronous processing to
# the continuation workflow. The build lane must retain the exact state while
# refusing to staple or publish before a later Accepted result.
: > "$LOG"
ASYNC_STATE="$TMP_DIR/cmux-nightly-async.state"
ASYNC_OUTPUT="$TMP_DIR/cmux-nightly-async.log"
ASYNC_GITHUB_OUTPUT="$TMP_DIR/async.github-output"
rm -f "$ASYNC_STATE" "$ASYNC_OUTPUT" "$ASYNC_GITHUB_OUTPUT" "$IMMUTABLE"
if ! TEST_NOTARY_SUBMIT_ONLY=true \
  CMUX_NOTARY_SUBMISSION_FILE="$ASYNC_STATE" \
  CMUX_NOTARY_OUTPUT_FILE="$ASYNC_OUTPUT" \
  GITHUB_OUTPUT="$ASYNC_GITHUB_OUTPUT" \
  run_helper >/dev/null 2>"$TMP_DIR/async.err"; then
  echo "FAIL: submit-only notarization failed before handing off the published path" >&2
  exit 1
fi
if ! grep -Fxq "submission_id=fixture-id" "$ASYNC_STATE" \
  || ! grep -Fxq "submission_pending=true" "$ASYNC_GITHUB_OUTPUT" \
  || ! grep -q '^xcrun notarytool submit .*--output-format json$' "$LOG" \
  || grep -q '^xcrun notarytool submit .*--wait' "$LOG" \
  || grep -Fq 'xcrun stapler staple' "$LOG" \
  || [ -e "$IMMUTABLE" ]; then
  echo "FAIL: submit-only notarization did not preserve a pending ticket without stapling" >&2
  cat "$LOG" "$ASYNC_STATE" >&2
  exit 1
fi

FAILED_ASYNC_STATE="$TMP_DIR/cmux-nightly-submit-failed.state"
FAILED_ASYNC_OUTPUT="$TMP_DIR/cmux-nightly-submit-failed.log"
rm -f "$FAILED_ASYNC_STATE" "$FAILED_ASYNC_OUTPUT"
if TEST_NOTARY_SUBMIT_ONLY=true CMUX_TEST_NOTARY_TIMEOUT=1 \
  CMUX_NOTARY_SUBMISSION_FILE="$FAILED_ASYNC_STATE" \
  CMUX_NOTARY_OUTPUT_FILE="$FAILED_ASYNC_OUTPUT" \
  run_helper >/dev/null 2>"$TMP_DIR/async-failed.err"; then
  echo "FAIL: failed submit was reported as an asynchronous handoff" >&2
  exit 1
fi
if ! grep -q "refusing continuation" "$TMP_DIR/async-failed.err" \
  || ! grep -Fxq "submission_id=fixture-id" "$FAILED_ASYNC_STATE"; then
  echo "FAIL: nonzero submit did not preserve evidence without claiming handoff" >&2
  cat "$TMP_DIR/async-failed.err" "$FAILED_ASYNC_STATE" >&2
  exit 1
fi

# The exact recovery artifact can be resumed without rebuilding or submitting
# a second Apple request. The saved SHA and submission id gate all stapling and
# publication work.
: > "$LOG"
GENERIC_STATE="$TMP_DIR/cmux-nightly-generic.state"
GENERIC_OUTPUT="$TMP_DIR/cmux-nightly-generic.log"
rm -f "$GENERIC_STATE" "$GENERIC_OUTPUT"
rm -rf "$TMP_DIR/cmux-nightly-mount"
if CMUX_TEST_NOTARY_FAILURE=1 \
  CMUX_NOTARY_SUBMISSION_FILE="$GENERIC_STATE" \
  CMUX_NOTARY_OUTPUT_FILE="$GENERIC_OUTPUT" \
  run_helper >/dev/null 2>"$TMP_DIR/generic.err"; then
  echo "FAIL: a generic notarization submit failure unexpectedly succeeded" >&2
  exit 1
fi
if ! grep -q "submit exited 7" "$TMP_DIR/generic.err" \
  || grep -q "did not finish within" "$TMP_DIR/generic.err" \
  || ! grep -q "network failure while uploading submission" "$GENERIC_OUTPUT"; then
  echo "FAIL: generic submit failure was mislabeled as a timeout" >&2
  cat "$TMP_DIR/generic.err" "$GENERIC_OUTPUT" >&2
  exit 1
fi

echo "PASS: single DMG submission validates app ticket and delivered artifact"

# The RC channel reuses the same packaging path and only switches the
# entitlements default and the bundle-metadata channel argument.
: > "$LOG"
RC_APP="$TMP_DIR/input/cmux RC.app"
mkdir -p "$RC_APP/Contents/MacOS"
printf 'signed-rc-fixture\n' > "$RC_APP/Contents/MacOS/cmux"
CMUX_TEST_CALL_LOG="$LOG" \
CMUX_TEST_SOURCE_APP="$RC_APP" \
CMUX_TEST_DETACH_STATE="$TMP_DIR/detach-retried-rc" \
CMUX_CHANNEL=rc \
CMUX_NIGHTLY_MOUNT_DIR="$TMP_DIR/cmux-rc-mount" \
CMUX_CREATE_DMG_TOOL="$FAKE_BIN/create-dmg" \
CMUX_CODESIGN_TOOL="$FAKE_BIN/codesign" \
CMUX_XCRUN_TOOL="$FAKE_BIN/xcrun" \
CMUX_HDIUTIL_TOOL="$FAKE_BIN/hdiutil" \
CMUX_SPCTL_TOOL="$FAKE_BIN/spctl" \
CMUX_SMOKE_TOOL="$FAKE_BIN/smoke" \
CMUX_VERIFY_METADATA_TOOL="$FAKE_BIN/metadata" \
CMUX_VERIFY_LICENSES_TOOL="$FAKE_BIN/licenses" \
CMUX_NOTARIZE_COMPUTER_USE_HELPER_TOOL="$FAKE_BIN/notarize-computer-use-helper" \
ASC_API_KEY_ID=FIXTUREKEY \
ASC_API_ISSUER_ID=fixture-issuer \
ASC_API_KEY_P8_BASE64="$FIXTURE_P8_BASE64" \
APPLE_SIGNING_IDENTITY='Developer ID Application: Fixture' \
"$SCRIPT" "$RC_APP" "$TMP_DIR/cmux-rc-macos.dmg" "$TMP_DIR/cmux-rc-immutable.dmg"
for expected in \
  "notarize-helper $RC_APP $ROOT_DIR/cmux.rc.entitlements Developer ID Application: Fixture" \
  "metadata $RC_APP rc" \
  "metadata $TMP_DIR/cmux-rc-mount/cmux NIGHTLY.app rc"; do
  if ! grep -Fxq "$expected" "$LOG"; then
    echo "FAIL: rc channel packaging missed: $expected" >&2
    exit 1
  fi
done
if CMUX_CHANNEL=beta run_helper 2>/dev/null; then
  echo "FAIL: unknown channel must be rejected" >&2
  exit 1
fi
echo "PASS: rc channel packaging selects rc entitlements and metadata checks"

# Stable packages through the same path with the release entitlements, so the
# stable release can ship per-architecture DMGs the way nightly does.
: > "$LOG"
STABLE_APP="$TMP_DIR/input/cmux.app"
mkdir -p "$STABLE_APP/Contents/MacOS"
printf 'signed-stable-fixture\n' > "$STABLE_APP/Contents/MacOS/cmux"
CMUX_TEST_CALL_LOG="$LOG" \
CMUX_TEST_SOURCE_APP="$STABLE_APP" \
CMUX_TEST_DETACH_STATE="$TMP_DIR/detach-retried-stable" \
CMUX_CHANNEL=stable \
CMUX_NIGHTLY_MOUNT_DIR="$TMP_DIR/cmux-stable-mount" \
CMUX_CREATE_DMG_TOOL="$FAKE_BIN/create-dmg" \
CMUX_CODESIGN_TOOL="$FAKE_BIN/codesign" \
CMUX_XCRUN_TOOL="$FAKE_BIN/xcrun" \
CMUX_HDIUTIL_TOOL="$FAKE_BIN/hdiutil" \
CMUX_SPCTL_TOOL="$FAKE_BIN/spctl" \
CMUX_SMOKE_TOOL="$FAKE_BIN/smoke" \
CMUX_VERIFY_METADATA_TOOL="$FAKE_BIN/metadata" \
CMUX_VERIFY_LICENSES_TOOL="$FAKE_BIN/licenses" \
CMUX_NOTARIZE_COMPUTER_USE_HELPER_TOOL="$FAKE_BIN/notarize-computer-use-helper" \
ASC_API_KEY_ID=FIXTUREKEY \
ASC_API_ISSUER_ID=fixture-issuer \
ASC_API_KEY_P8_BASE64="$FIXTURE_P8_BASE64" \
APPLE_SIGNING_IDENTITY='Developer ID Application: Fixture' \
"$SCRIPT" "$STABLE_APP" "$TMP_DIR/cmux-macos-arm64.dmg" "$TMP_DIR/cmux-stable-immutable.dmg"
for expected in \
  "notarize-helper $STABLE_APP $ROOT_DIR/cmux.release.entitlements Developer ID Application: Fixture" \
  "metadata $STABLE_APP stable"; do
  if ! grep -Fxq "$expected" "$LOG"; then
    echo "FAIL: stable channel packaging missed: $expected" >&2
    exit 1
  fi
done
echo "PASS: stable channel packaging selects release entitlements and metadata checks"

# Resuming a stable submission passes the channel gate and stops at the next
# check (here a deliberate SHA-256 mismatch), never at "Unsupported channel".
RESUME_SCRIPT="$ROOT_DIR/scripts/ci/resume-nightly-notarization.sh"
RESUME_DIR="$TMP_DIR/resume-stable"
mkdir -p "$RESUME_DIR/cmux.app/Contents"
printf 'stable-dmg\n' > "$RESUME_DIR/cmux-macos-arm64.dmg"
printf '%s\n' \
  "submission_id=fixture-submission" \
  "status=In Progress" \
  "dmg_path=$RESUME_DIR/cmux-macos-arm64.dmg" \
  "dmg_sha256=$(printf '0%.0s' $(seq 64))" \
  "immutable_path=$RESUME_DIR/cmux-macos-arm64-immutable.dmg" \
  "channel=stable" > "$RESUME_DIR/state"
printf 'original submission evidence\n' > "$RESUME_DIR/cmux-macos-arm64.dmg.notarization.log"
if resume_output="$(ASC_API_KEY_ID=FIXTUREKEY ASC_API_ISSUER_ID=fixture-issuer \
    ASC_API_KEY_P8_BASE64="$FIXTURE_P8_BASE64" "$RESUME_SCRIPT" "$RESUME_DIR/state" "$RESUME_DIR/cmux.app" \
    "$RESUME_DIR/cmux-macos-arm64.dmg" "$RESUME_DIR/cmux-macos-arm64-immutable.dmg" 2>&1)"; then
  echo "FAIL: resume with a mismatched DMG hash must fail" >&2
  exit 1
fi
if grep -Fq 'Unsupported recovery channel' <<<"$resume_output" \
   || ! grep -Fq 'SHA-256 does not match' <<<"$resume_output"; then
  echo "FAIL: resume must accept the stable channel; got: $resume_output" >&2
  exit 1
fi
echo "PASS: stable notarization state resumes past the channel gate"

# Fast dogfood keeps Developer ID signing and DMG creation but bypasses both
# Computer Use and outer notarization. It must work without Apple API secrets,
# and the signed image still becomes the internal immutable artifact.
: > "$LOG"
FAST_DMG="$TMP_DIR/cmux-fast-dogfood.dmg"
FAST_IMMUTABLE="$TMP_DIR/cmux-fast-dogfood-immutable.dmg"
if ! (
  CMUX_SKIP_NOTARIZATION=true \
  TEST_ASC_API_KEY_ID= \
  TEST_ASC_API_ISSUER_ID= \
  TEST_ASC_API_KEY_P8_BASE64= \
  run_helper "$APP" "$FAST_DMG" "$FAST_IMMUTABLE"
); then
  echo "FAIL: fast dogfood packaging should sign without notarization secrets" >&2
  exit 1
fi
if grep -q '^xcrun notarytool ' "$LOG" || grep -q '^notarize-helper ' "$LOG"; then
  echo "FAIL: fast dogfood packaging must skip helper and outer notarization" >&2
  exit 1
fi
if ! grep -q "codesign --force --timestamp --keychain build.keychain --sign Developer ID Application: Fixture $FAST_DMG" "$LOG"; then
  echo "FAIL: fast dogfood packaging must still codesign the DMG" >&2
  exit 1
fi
if [ ! -f "$FAST_IMMUTABLE" ] || ! cmp -s "$FAST_DMG" "$FAST_IMMUTABLE"; then
  echo "FAIL: fast dogfood packaging did not preserve the immutable DMG" >&2
  exit 1
fi
echo "PASS: fast dogfood packaging skips notarization but retains signing"

# The shipped DMG carries the stapled app (CMUX_STAPLE_APP_IN_DMG=true, the
# default). After Apple accepts the first DMG, the app is stapled from that
# ticket, a new DMG is built around it, signed with a fresh keychain that is
# deleted before the second submission, notarized, stapled and only then put
# at the release path. A second submission Apple does not accept publishes nothing.
cat > "$FAKE_BIN/keychain" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'keychain %s cert=%s\n' "$*" "${APPLE_CERTIFICATE_BASE64:+set}" >> "$CMUX_TEST_CALL_LOG"
EOF
chmod +x "$FAKE_BIN/keychain"
run_stapled() {
  TEST_STAPLE_APP_IN_DMG=true \
  CMUX_SIGNING_KEYCHAIN_TOOL="$FAKE_BIN/keychain" \
  APPLE_CERTIFICATE_BASE64="$(printf 'fixture-p12' | base64)" \
  APPLE_CERTIFICATE_PASSWORD=fixture-password \
  run_helper "$@"
}
: > "$LOG"
rm -rf "$TMP_DIR/cmux-nightly-mount" "$TMP_DIR/detach-retried" "$IMMUTABLE"
if ! run_stapled >/dev/null 2>"$TMP_DIR/stapled.err"; then
  echo "FAIL: packaging the stapled app into the DMG failed" >&2
  cat "$TMP_DIR/stapled.err" >&2
  exit 1
fi
if [ "$(grep -c '^xcrun notarytool submit ' "$LOG")" -ne 2 ] \
  || [ "$(grep -c '^xcrun notarytool submit .*/stapled-app/cmux-nightly-macos.dmg ' "$LOG")" -ne 1 ]; then
  echo "FAIL: expected the first DMG and the stapled-app DMG as the only two submissions" >&2
  cat "$LOG" >&2
  exit 1
fi
first_submit="$(grep -nF "xcrun notarytool submit $DMG " "$LOG" | head -n 1 | cut -d: -f1)"
app_staple="$(grep -nF "xcrun stapler staple $APP" "$LOG" | head -n 1 | cut -d: -f1)"
create2="$(grep -n '^keychain create cert=set$' "$LOG" | head -n 1 | cut -d: -f1)"
dmg2="$(grep -n "^create-dmg --no-code-sign $APP .*/stapled-app/work\$" "$LOG" | head -n 1 | cut -d: -f1)"
sign2="$(grep -n '^codesign --force --timestamp --keychain build.keychain .*/stapled-app/cmux-nightly-macos.dmg$' "$LOG" | head -n 1 | cut -d: -f1)"
delete2="$(grep -n '^keychain delete' "$LOG" | awk -F: -v after="${sign2:-0}" '$1 > after {print $1; exit}')"
submit2="$(grep -n '^xcrun notarytool submit .*/stapled-app/' "$LOG" | head -n 1 | cut -d: -f1)"
staple2="$(grep -n '^xcrun stapler staple .*/stapled-app/cmux-nightly-macos.dmg$' "$LOG" | head -n 1 | cut -d: -f1)"
attach2="$(grep -n '^hdiutil attach .*/stapled-app/cmux-nightly-macos.dmg ' "$LOG" | head -n 1 | cut -d: -f1)"
mounted_staple="$(grep -nF "xcrun stapler validate $TMP_DIR/cmux-nightly-mount/cmux NIGHTLY.app" "$LOG" | head -n 1 | cut -d: -f1)"
for n in first_submit app_staple create2 dmg2 sign2 delete2 submit2 staple2 attach2 mounted_staple; do
  if [ -z "${!n}" ]; then
    echo "FAIL: stapled-app packaging step missing: $n" >&2
    cat "$LOG" >&2
    exit 1
  fi
done
if ! [ "$first_submit" -lt "$app_staple" ] || ! [ "$app_staple" -lt "$dmg2" ] || ! [ "$dmg2" -lt "$create2" ] \
  || ! [ "$create2" -lt "$sign2" ] || ! [ "$sign2" -lt "$delete2" ] || ! [ "$delete2" -lt "$submit2" ] \
  || ! [ "$submit2" -lt "$staple2" ] || ! [ "$staple2" -lt "$attach2" ] || ! [ "$attach2" -lt "$mounted_staple" ]; then
  echo "FAIL: stapled-app DMG steps ran out of order" >&2
  cat "$LOG" >&2
  exit 1
fi
if grep -v '^create-dmg-umask 0022$' "$LOG" | grep -q '^create-dmg-umask '; then
  echo "FAIL: create-dmg must copy the app with umask 022" >&2
  exit 1
fi
if grep -q '^xcrun stapler staple '"$DMG"'$' "$LOG" || [ ! -f "$IMMUTABLE" ] || ! cmp -s "$DMG" "$IMMUTABLE"; then
  echo "FAIL: only the stapled-app DMG is stapled, put at the release path and copied to the immutable path" >&2
  exit 1
fi
: > "$LOG"
rm -rf "$TMP_DIR/cmux-nightly-mount" "$TMP_DIR/detach-retried" "$IMMUTABLE"
if CMUX_TEST_STAPLED_STATUS=Invalid run_stapled >/dev/null 2>&1 \
  || grep -q '^xcrun stapler staple .*\.dmg$' "$LOG" || [ -e "$IMMUTABLE" ]; then
  echo "FAIL: a rejected stapled-app DMG must fail and publish nothing" >&2
  exit 1
fi
: > "$LOG"
for missing in APPLE_CERTIFICATE_BASE64 APPLE_CERTIFICATE_PASSWORD; do
  : > "$LOG"
  if (export APPLE_CERTIFICATE_BASE64=fixture APPLE_CERTIFICATE_PASSWORD=fixture; unset "$missing"
      TEST_STAPLE_APP_IN_DMG=true CMUX_SIGNING_KEYCHAIN_TOOL="$FAKE_BIN/keychain" run_helper) >/dev/null 2>&1 \
    || grep -q '^xcrun notarytool submit ' "$LOG"; then
    echo "FAIL: without $missing the stapled-app DMG cannot be signed; fail before any submission" >&2
    exit 1
  fi
done
echo "PASS: the shipped DMG carries the stapled app and its own ticket"

# release.yml's thin variants submit the DMG around the stapled app without a
# wait (CMUX_STAPLED_DMG_HANDOFF_FILE); finish-stapled-app-dmgs.sh then waits
# for every handed-off submission at once and finishes them.
HANDOFF="$TMP_DIR/stapled.handoff"
run_finish() {
  CMUX_TEST_CALL_LOG="$LOG" \
  CMUX_TEST_SOURCE_APP="$APP" \
  CMUX_TEST_DETACH_STATE="$TMP_DIR/detach-retried" \
  CMUX_XCRUN_TOOL="$FAKE_BIN/xcrun" \
  CMUX_HDIUTIL_TOOL="$FAKE_BIN/hdiutil" \
  CMUX_SPCTL_TOOL="$FAKE_BIN/spctl" \
  CMUX_SMOKE_TOOL="$FAKE_BIN/smoke" \
  CMUX_VERIFY_METADATA_TOOL="$FAKE_BIN/metadata" \
  CMUX_VERIFY_LICENSES_TOOL="$FAKE_BIN/licenses" \
  ASC_API_KEY_ID=FIXTUREKEY \
  ASC_API_ISSUER_ID=fixture-issuer \
  ASC_API_KEY_P8_BASE64="$FIXTURE_P8_BASE64" \
  "$ROOT_DIR/scripts/ci/finish-stapled-app-dmgs.sh" "$HANDOFF"
}
for case in accepted rejected; do
  : > "$LOG"
  rm -rf "$TMP_DIR/cmux-nightly-mount" "$TMP_DIR/detach-retried"
  rm -f "$IMMUTABLE" "$DMG.stapled-app.dmg" "$HANDOFF"
  if ! CMUX_STAPLED_DMG_HANDOFF_FILE="$HANDOFF" run_stapled >/dev/null 2>"$TMP_DIR/handoff.err"; then
    echo "FAIL: handing off the stapled-app DMG failed" >&2
    cat "$TMP_DIR/handoff.err" >&2
    exit 1
  fi
  if ! grep -q '^xcrun notarytool submit .*/stapled-app/cmux-nightly-macos.dmg .*--output-format json$' "$LOG" \
    || grep -q '^xcrun notarytool submit .*/stapled-app/.*--wait' "$LOG" \
    || ! grep -Fxq 'submission_id=fixture-stapled-id' "$HANDOFF" \
    || [ ! -f "$DMG.stapled-app.dmg" ] || [ -e "$IMMUTABLE" ] \
    || grep -q '^xcrun stapler staple .*\.dmg$' "$LOG"; then
    echo "FAIL: a handed-off stapled-app DMG is submitted without a wait and left unstapled for the finish step" >&2
    cat "$LOG" >&2
    exit 1
  fi
  : > "$LOG"
  if [ "$case" = accepted ]; then
    if ! run_finish >/dev/null 2>"$TMP_DIR/finish.err"; then
      echo "FAIL: finishing an accepted stapled-app DMG failed" >&2
      cat "$TMP_DIR/finish.err" >&2
      exit 1
    fi
    if ! grep -q '^xcrun notarytool wait fixture-stapled-id ' "$LOG" \
      || ! grep -Fxq "xcrun stapler staple $DMG.stapled-app.dmg" "$LOG" \
      || ! grep -q '^xcrun stapler validate .*/cmux NIGHTLY.app$' "$LOG" \
      || [ -e "$DMG.stapled-app.dmg" ] || [ ! -f "$IMMUTABLE" ] || ! cmp -s "$DMG" "$IMMUTABLE"; then
      echo "FAIL: the finish step must staple the stapled-app DMG, check the app inside, and put it at the release and immutable paths" >&2
      cat "$LOG" >&2
      exit 1
    fi
  else
    if CMUX_TEST_WAIT_STATUS=Invalid run_finish >/dev/null 2>&1 \
      || grep -q '^xcrun stapler staple' "$LOG" || [ -e "$IMMUTABLE" ]; then
      echo "FAIL: a rejected stapled-app DMG must fail the finish step and publish nothing" >&2
      exit 1
    fi
  fi
done
echo "PASS: handed-off stapled-app DMGs are finished together"

# resume-stapled-app-notarization.sh, with stub package, resume and keychain
# tools: the order of its steps, the stapled_app=true state it hands off, a
# second submission that Apple rejects or that is still pending, and the 6 h
# fallback that ships the accepted first DMG (never an unstapled one).
W="$TMP_DIR/wrapper"
mkdir -p "$W/bin" "$W/recovery"
cat > "$W/bin/keychain" <<'EOF'
#!/usr/bin/env bash
printf 'keychain %s cert=%s\n' "$1" "${APPLE_CERTIFICATE_BASE64:+set}" >> "$CMUX_TEST_CALL_LOG"
EOF
cat > "$W/bin/package" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'package %s cert=%s creates_keychain=%s submit_only=%s marker=%s\n' "$2" "${APPLE_CERTIFICATE_BASE64:+set}" "${CMUX_PACKAGE_CREATES_KEYCHAIN:-}" "$CMUX_NOTARY_SUBMIT_ONLY" "${CMUX_NOTARY_STATE_STAPLED_APP:-}" >> "$CMUX_TEST_CALL_LOG"
printf 'second-dmg\n' > "$2"
# CMUX_TEST_UPLOAD_FAILURES: the first N uploads fail after the DMG is signed.
failures="${CMUX_TEST_UPLOAD_FAILURES:-0}"
count_file="$CMUX_TEST_CALL_LOG.uploads"
count="$(cat "$count_file" 2>/dev/null || echo 0)"
printf '%s\n' "$((count + 1))" > "$count_file"
if [ "$count" -lt "$failures" ]; then
  printf 'upload failed\n' > "$CMUX_NOTARY_OUTPUT_FILE"
  exit 1
fi
{
  printf 'submission_id=fixture-second-id\n'
  printf 'dmg_path=%s\n' "$2"
  printf 'channel=nightly\n'
  if [ "${CMUX_NOTARY_STATE_STAPLED_APP:-}" = true ]; then
    printf 'stapled_app=true\n'
    printf 'stapled_submitted_at=%s\n' "$(date +%s)"
    printf 'first_submission_id=%s\n' "$CMUX_NOTARY_STATE_FIRST_SUBMISSION_ID"
    printf 'first_dmg_sha256=%s\n' "$CMUX_NOTARY_STATE_FIRST_DMG_SHA256"
  fi
} > "$CMUX_NOTARY_SUBMISSION_FILE"
printf 'submit evidence\n' > "$CMUX_NOTARY_OUTPUT_FILE"
EOF
# The stub continuation: a stapled_app=true state answers CMUX_TEST_SECOND
# (exit 75 when not Accepted, as resume-nightly-notarization.sh does); the
# first DMG's own state (the fallback) is Accepted and is published.
cat > "$W/bin/resume" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'resume %s %s app_only=%s helper_recheck_skipped=%s wait=%s cert=%s\n' "$(basename "$1")" "$3" "${CMUX_RESUME_APP_ONLY:-false}" "${CMUX_SKIP_HELPER_RECHECK:-false}" "${CMUX_NOTARY_WAIT_TIMEOUT:-}" "${APPLE_CERTIFICATE_BASE64:+set}" >> "$CMUX_TEST_CALL_LOG"
if grep -Fxq 'stapled_app=true' "$1"; then
  case "${CMUX_TEST_SECOND:-Accepted}" in
    Accepted) cp "$3" "$4" ;;
    *) echo "submission fixture-second-id: ${CMUX_TEST_SECOND}" >&2; exit 75 ;;
  esac
elif [[ "$1" == */first-dmg-fallback/first.state ]]; then
  grep -Fxq 'submission_id=fixture-first-id' "$1"
  cp "$3" "$4"
fi
EOF
chmod +x "$W/bin"/*
run_wrapper() {
  CMUX_TEST_CALL_LOG="$LOG" \
  CMUX_NOTARIZE_NIGHTLY_DMG_TOOL="$W/bin/package" \
  CMUX_RESUME_NIGHTLY_NOTARIZATION_TOOL="$W/bin/resume" \
  CMUX_SIGNING_KEYCHAIN_TOOL="$W/bin/keychain" \
  APPLE_SIGNING_IDENTITY="Developer ID Application: Fixture" \
  APPLE_CERTIFICATE_BASE64=fixture-p12 \
  APPLE_CERTIFICATE_PASSWORD=fixture-password \
  CMUX_NOTARY_WAIT_TIMEOUT=2m \
  CMUX_STAPLED_APP_NOTARY_WAIT_TIMEOUT=40m \
  CMUX_STAPLED_APP_SUBMIT_RETRY_SECONDS=0 \
  "$ROOT_DIR/scripts/ci/resume-stapled-app-notarization.sh" \
    "$1" "$APP" "$W/recovery/cmux-nightly-macos.dmg" "$W/immutable.dmg" \
    "$ROOT_DIR/cmux.nightly.entitlements" "$W/outer.state"
}
reset_wrapper() {
  : > "$LOG"
  rm -f "$LOG.uploads"
  rm -rf "$W/recovery/stapled-app" "$W/recovery/first-dmg-fallback" "$W/outer.state" "$W/outer.state.log" "$W/immutable.dmg" "$W/immutable.dmg.stapled-app-fallback"
  printf 'first-dmg\n' > "$W/recovery/cmux-nightly-macos.dmg"
  printf 'submission_id=fixture-first-id\n' > "$W/first.state"
}
expected="$(cat <<EOF
keychain delete cert=
resume first.state $W/recovery/cmux-nightly-macos.dmg app_only=true helper_recheck_skipped=false wait=2m cert=
package $W/recovery/stapled-app/cmux-nightly-macos.dmg cert=set creates_keychain=true submit_only=true marker=true
keychain delete cert=
resume outer.state $W/recovery/stapled-app/cmux-nightly-macos.dmg app_only=false helper_recheck_skipped=true wait=40m cert=
EOF
)"
# Before 6 h (the default limit): Accepted ships the stapled-app DMG; queued
# or refused hands it off (exit 75) and publishes nothing.
for case in Accepted Invalid "In Progress"; do
  reset_wrapper
  set +e
  CMUX_TEST_SECOND="$case" run_wrapper "$W/first.state" >/dev/null 2>"$W/err"
  status=$?
  set -e
  if [ "$(head -n 5 "$LOG")" != "$expected" ] \
    || ! grep -Fxq 'stapled_app=true' "$W/outer.state" || [ ! -s "$W/outer.state.log" ] \
    || ! grep -Eq '^stapled_submitted_at=[0-9]+$' "$W/outer.state" \
    || ! grep -Fxq 'first_submission_id=fixture-first-id' "$W/outer.state" \
    || [ "$(cat "$W/recovery/stapled-app/cmux-nightly-macos.dmg.first.dmg" 2>/dev/null)" != first-dmg ]; then
    echo "FAIL ($case): the wrapper must staple the first DMG's app without a keychain, make the keychain just before the second signature, record the submit time and the first DMG, and hand the stapled_app=true state to a bounded wait" >&2
    cat "$LOG" "$W/err" >&2
    exit 1
  fi
  if [ "$case" = Accepted ]; then
    if [ "$status" -ne 0 ] || [ "$(cat "$W/recovery/cmux-nightly-macos.dmg")" != second-dmg ] \
      || [ -e "$W/recovery/stapled-app/cmux-nightly-macos.dmg" ] || [ "$(cat "$W/immutable.dmg")" != second-dmg ] \
      || [ -e "$W/immutable.dmg.stapled-app-fallback" ]; then
      echo "FAIL: an accepted stapled-app DMG must replace the first DMG and be published" >&2
      cat "$W/err" >&2
      exit 1
    fi
  elif [ "$status" -ne 75 ] || [ "$(cat "$W/recovery/cmux-nightly-macos.dmg")" != first-dmg ] \
    || [ "$(cat "$W/recovery/stapled-app/cmux-nightly-macos.dmg")" != second-dmg ] || [ -e "$W/immutable.dmg" ] \
    || grep -q 'first-dmg-fallback' "$LOG"; then
    echo "FAIL ($case): before 6 h a stapled-app DMG that is not accepted must hand off (exit 75), publish nothing, and keep both DMGs" >&2
    cat "$LOG" "$W/err" >&2
    exit 1
  fi
done
# A stapled_app=true state (an outer recovery artifact) is only continued,
# and its first DMG travels as <DMG>.first.dmg.
make_marked() {
  printf 'second-dmg\n' > "$W/recovery/cmux-nightly-macos.dmg"
  printf 'first-dmg\n' > "$W/recovery/cmux-nightly-macos.dmg.first.dmg"
  first_sha="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$W/recovery/cmux-nightly-macos.dmg.first.dmg")"
  printf 'submission_id=fixture-second-id\nchannel=nightly\nstapled_app=true\nstapled_submitted_at=%s\nfirst_submission_id=fixture-first-id\nfirst_dmg_sha256=%s\n' \
    "$1" "$first_sha" > "$W/marked.state"
}
reset_wrapper
make_marked "$(date +%s)"
if ! run_wrapper "$W/marked.state" >/dev/null 2>"$W/err" \
  || grep -q '^package \|^keychain create' "$LOG" \
  || ! grep -q "^resume marked.state $W/recovery/cmux-nightly-macos.dmg app_only=false " "$LOG" \
  || [ "$(cat "$W/immutable.dmg")" != second-dmg ]; then
  echo "FAIL: a stapled_app=true state must be continued without a new DMG or keychain" >&2
  cat "$LOG" "$W/err" >&2
  exit 1
fi
# Past 6 h after the recorded submit time, queued or refused: the accepted
# first DMG ships, with the pending id for the smoke and a warning.
for case in "In Progress" Invalid; do
  reset_wrapper
  make_marked "$(( $(date +%s) - 21601 ))"
  if ! CMUX_TEST_SECOND="$case" run_wrapper "$W/marked.state" >"$W/out" 2>"$W/err" \
    || ! grep -q "^resume first.state $W/recovery/first-dmg-fallback/cmux-nightly-macos.dmg " "$LOG" \
    || [ "$(cat "$W/recovery/cmux-nightly-macos.dmg")" != first-dmg ] || [ "$(cat "$W/immutable.dmg")" != first-dmg ] \
    || [ "$(cat "$W/immutable.dmg.stapled-app-fallback")" != fixture-second-id ] \
    || ! grep -q '^::warning title=App shipped without its own ticket::.*fixture-second-id' "$W/out"; then
    echo "FAIL ($case): 6 h after its submission a stapled-app DMG that is not accepted must ship the accepted first DMG with a warning" >&2
    cat "$LOG" "$W/out" "$W/err" >&2
    exit 1
  fi
done
# Before 6 h a continued state still hands off, and a tampered first DMG
# never ships at the fallback.
reset_wrapper
make_marked "$(( $(date +%s) - 3600 ))"
set +e
CMUX_TEST_SECOND="In Progress" run_wrapper "$W/marked.state" >/dev/null 2>"$W/err"
status=$?
set -e
if [ "$status" -ne 75 ] || [ -e "$W/immutable.dmg" ] || grep -q 'first-dmg-fallback' "$LOG"; then
  echo "FAIL: 1 h after its submission a pending stapled-app DMG must hand off and publish nothing" >&2
  cat "$LOG" "$W/err" >&2
  exit 1
fi
reset_wrapper
make_marked "$(( $(date +%s) - 21601 ))"
printf 'tampered\n' > "$W/recovery/cmux-nightly-macos.dmg.first.dmg"
if CMUX_TEST_SECOND="In Progress" run_wrapper "$W/marked.state" >/dev/null 2>"$W/err" \
  || [ -e "$W/immutable.dmg" ] || grep -q 'first-dmg-fallback' "$LOG" \
  || ! grep -q 'missing or altered; nothing is published' "$W/err"; then
  echo "FAIL: a tampered first DMG must never ship at the 6 h fallback" >&2
  cat "$LOG" "$W/err" >&2
  exit 1
fi
# An upload that fails is tried again; when every try fails the state is
# unsubmitted (never accepted), so it waits for the 6 h fallback.
reset_wrapper
if ! CMUX_TEST_UPLOAD_FAILURES=1 run_wrapper "$W/first.state" >/dev/null 2>"$W/err" \
  || [ "$(grep -c '^package ' "$LOG")" -ne 2 ] || [ "$(cat "$W/immutable.dmg")" != second-dmg ]; then
  echo "FAIL: one failed upload of the stapled-app DMG must be tried again" >&2
  cat "$LOG" "$W/err" >&2
  exit 1
fi
reset_wrapper
set +e
CMUX_TEST_UPLOAD_FAILURES=9 CMUX_TEST_SECOND=unsubmitted run_wrapper "$W/first.state" >/dev/null 2>"$W/err"
status=$?
set -e
if [ "$status" -ne 75 ] || [ "$(grep -c '^package ' "$LOG")" -ne 3 ] \
  || ! grep -Fxq 'submission_id=unsubmitted' "$W/outer.state" || ! grep -Fxq 'stapled_app=true' "$W/outer.state" \
  || ! grep -Eq '^stapled_submitted_at=[0-9]+$' "$W/outer.state" || [ -e "$W/immutable.dmg" ]; then
  echo "FAIL: a stapled-app DMG that cannot be uploaded must be handed off as unsubmitted, toward its 6 h fallback" >&2
  cat "$LOG" "$W/err" >&2
  exit 1
fi
echo "PASS: the stapled-app wrapper hands off its second submission and ships the first DMG only at the 6 h fallback"

# stage-outer-notarization-recovery.py and poll-outer-notarizations.sh: an
# exact hand-off artifact, and polling until Accepted or the 6 h deadline.
P="$TMP_DIR/poll"
mkdir -p "$P/bin" "$P/run/stapled-app" "$P/run/cmux-nightly-notarization-recovery-app/cmux NIGHTLY.app/Contents"
HEAD_SHA=0123456789abcdef0123456789abcdef01234567
cat > "$P/source.json" <<'EOF'
{"build": "4242", "app_path": "cmux-nightly-notarization-recovery-app/cmux NIGHTLY.app", "app_archive_path": "cmux-nightly-notarization-recovery-app.tar.gz"}
EOF
sha_of() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
make_state() { # make_state <marked:true|false> <submitted_at>
  local dmg="$P/run/stapled-app/cmux-nightly-macos-arm64.dmg"
  printf 'second\n' > "$dmg"
  printf 'first\n' > "$dmg.first.dmg"
  {
    printf 'submission_id=fixture-poll-id\n'
    printf 'dmg_path=%s\n' "$dmg"
    printf 'dmg_sha256=%s\n' "$(sha_of "$dmg")"
    printf 'submit_exit=0\n'
    printf 'immutable_path=%s\n' "$P/run/cmux-nightly-macos-arm64-4242.dmg"
    printf 'channel=nightly\n'
    if [ "$1" = true ]; then
      printf 'stapled_app=true\nstapled_submitted_at=%s\nfirst_submission_id=fixture-first-id\nfirst_dmg_sha256=%s\n' "$2" "$(sha_of "$dmg.first.dmg")"
    fi
  } > "$P/run/outer.state"
  printf 'evidence\n' > "$P/run/outer.state.log"
}
stage() { # stage <out> [args...]
  local out="$1"; shift
  rm -rf "$P/$out" "$P/meta/arm64"
  python3 "$ROOT_DIR/scripts/ci/stage-outer-notarization-recovery.py" \
    "$P/source.json" "$P/run/outer.state" "$P/run/cmux-nightly-macos-arm64.dmg" \
    "$P/run/cmux-nightly-notarization-recovery-app/cmux NIGHTLY.app" "$P/$out" \
    --metadata-dir "$P/meta/arm64" "$@" \
    --source-run-id 123 --head-sha "$HEAD_SHA" --run-attempt 1 --channel nightly --variant arm64 \
    --release-tag nightly --dmg-prefix cmux-nightly-macos --short-sha 0123456
}
make_state true "$(date +%s)"
if ! stage staged --require-stapled-app >/dev/null 2>"$P/err" \
  || [ "$(cat "$P/staged/cmux-nightly-macos-arm64.dmg")" != second ] \
  || [ "$(cat "$P/staged/cmux-nightly-macos-arm64.dmg.first.dmg")" != first ] \
  || ! grep -Fxq 'stapled_app=true' "$P/staged/cmux-nightly-macos-arm64.dmg.notarization.state" \
  || ! tar -tzf "$P/staged/cmux-nightly-notarization-recovery-app.tar.gz" | grep -q '^cmux NIGHTLY.app/' \
  || ! python3 "$ROOT_DIR/scripts/ci/resolve-notarization-recovery.py" "$P/staged/cmux-nightly-notarization-recovery.json" \
    123 "$HEAD_SHA" nightly arm64 --run-attempt 1 --strict --extract-app >/dev/null; then
  echo "FAIL: a stapled-app hand-off must carry the state, the DMG, the first DMG and the current app, and resolve strictly" >&2
  cat "$P/err" >&2
  exit 1
fi
printf 'tampered\n' > "$P/run/stapled-app/cmux-nightly-macos-arm64.dmg.first.dmg"
if stage tampered --require-stapled-app >/dev/null 2>&1; then
  echo "FAIL: a hand-off must refuse a first DMG that does not match its record" >&2
  exit 1
fi
make_state false 0
if stage unmarked --require-stapled-app >/dev/null 2>&1; then
  echo "FAIL: --require-stapled-app must refuse a state without stapled_app=true" >&2
  exit 1
fi
# The stub poll tool answers the codes in $CMUX_TEST_POLL_CODES in turn, then
# repeats the last one (0 Accepted, 1 refused, 2 In Progress, 3 failed query).
cat > "$P/bin/poll" <<'EOF'
#!/usr/bin/env bash
n="$(cat "$CMUX_TEST_POLL_COUNT" 2>/dev/null || echo 0)"
printf '%s\n' "$((n + 1))" > "$CMUX_TEST_POLL_COUNT"
read -r -a codes <<<"$CMUX_TEST_POLL_CODES"
i=$(( n < ${#codes[@]} ? n : ${#codes[@]} - 1 ))
exit "${codes[$i]}"
EOF
chmod +x "$P/bin/poll"
printf 'arm64\n' > "$P/variants"
run_poll() { # run_poll <codes> [env...]
  rm -f "$P/count" "$P/output"
  env SOURCE_RUN_ID=123 SOURCE_HEAD_SHA="$HEAD_SHA" SOURCE_RUN_ATTEMPT=1 CHANNEL=nightly \
    GITHUB_OUTPUT="$P/output" CMUX_POLL_NOTARY_SUBMISSION_TOOL="$P/bin/poll" \
    CMUX_TEST_POLL_CODES="$1" CMUX_TEST_POLL_COUNT="$P/count" "${@:2}" \
    timeout 60 "$ROOT_DIR/scripts/ci/poll-outer-notarizations.sh" "$P/meta" "$P/variants" "$P/reports" >"$P/poll.out" 2>&1
}
check_poll() { # check_poll <label> <expected exit> <expected outer_variants> [expect fallback]
  local status="$1"
  if [ "$status" -ne "$3" ] || { [ "$3" -eq 0 ] && ! grep -Fxq "outer_variants=$4" "$P/output"; } \
    || { [ "${5:-}" = fallback ] && ! grep -q 'arm64: fallback' "$P/poll.out"; }; then
    echo "FAIL: poll-outer-notarizations.sh: $2" >&2
    cat "$P/poll.out" "$P/output" >&2 2>/dev/null
    exit 1
  fi
}
# Refused, 2 s before the deadline, 300 s interval: the poll sleeps to the
# deadline and decides the fallback.
make_state true "$(( $(date +%s) - 21600 + 2 ))"; stage s >/dev/null
set +e; run_poll "1"; status=$?; set -e
check_poll "$status" "a refused stapled-app DMG must reach its deadline" 0 '["arm64"]' fallback
# Accepted on the second poll after a failed query.
make_state true "$(date +%s)"; stage s >/dev/null
set +e; run_poll "3 0" CMUX_OUTER_POLL_INTERVAL_SECONDS=1; status=$?; set -e
check_poll "$status" "a failed query is polled again and Accepted decides" 0 '["arm64"]'
# Refused within minutes of its submission: the deadline lies 62 s after a
# 2 s budget, inside the 300 s slack, so it is decided due for the fallback
# (the continuation waits for the deadline itself).
make_state true "$(( $(date +%s) - 21600 + 62 ))"; stage s >/dev/null
set +e; run_poll "1" CMUX_OUTER_POLL_INTERVAL_SECONDS=1 CMUX_OUTER_POLL_BUDGET_SECONDS=2; status=$?; set -e
check_poll "$status" "a quick refusal whose deadline is inside the slack after the budget is due for the fallback" 0 '["arm64"]' fallback
make_state true "$(date +%s)"; stage s >/dev/null
# Pending with the deadline far away and a 2 s budget: not decided.
set +e; run_poll "2" CMUX_OUTER_POLL_INTERVAL_SECONDS=1 CMUX_OUTER_POLL_BUDGET_SECONDS=2; status=$?; set -e
check_poll "$status" "a budget that ends before the deadline decides nothing" 0 '[]'
# An outer DMG without the marker: a failed query is polled again, a refusal fails.
make_state false 0; stage s >/dev/null
set +e; run_poll "3 2 0" CMUX_OUTER_POLL_INTERVAL_SECONDS=1; status=$?; set -e
check_poll "$status" "an outer DMG is accepted after a failed query and In Progress" 0 '["arm64"]'
set +e; run_poll "1" CMUX_OUTER_POLL_INTERVAL_SECONDS=1; status=$?; set -e
check_poll "$status" "a refused outer DMG without the marker must fail" 1 ""
if ! grep -Fxq 'outer_variants=[]' "$P/output" || ! grep -q 'arm64: failed' "$P/poll.out"; then
  echo "FAIL: poll-outer-notarizations.sh: a failed variant is recorded and the outputs are still written" >&2
  cat "$P/poll.out" "$P/output" >&2
  exit 1
fi
echo "PASS: outer hand-offs are exact and the poll reaches each stapled-app deadline"

# The CI signing keychain must be gone before any launch smoke runs code from
# the bundle. Give the helper a managed keychain (scripts/ci/signing-keychain.sh
# state with a fake `security`), and record at each smoke whether it still
# exists. The DMG signature must come first, then the keychain delete, then
# the smokes.
: > "$LOG"
KEYCHAIN_STATE="$TMP_DIR/signing-keychain-state"
mkdir -p "$KEYCHAIN_STATE"
printf 'fixture-keychain-password' > "$KEYCHAIN_STATE/build.keychain.password"
cat > "$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'security %s\n' "$*" >> "$CMUX_TEST_CALL_LOG"
EOF
cat > "$FAKE_BIN/smoke" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -e "$CMUX_SIGNING_KEYCHAIN_STATE_DIR/build.keychain.password" ]; then
  printf 'smoke-with-keychain %s\n' "$*" >> "$CMUX_TEST_CALL_LOG"
else
  printf 'smoke %s\n' "$*" >> "$CMUX_TEST_CALL_LOG"
fi
EOF
chmod +x "$FAKE_BIN/security" "$FAKE_BIN/smoke"
KEYCHAIN_DMG="$TMP_DIR/cmux-keychain-order.dmg"
KEYCHAIN_IMMUTABLE="$TMP_DIR/cmux-keychain-order-immutable.dmg"
rm -f "$TMP_DIR/detach-retried"
CMUX_SIGNING_KEYCHAIN_STATE_DIR="$KEYCHAIN_STATE" \
CMUX_SECURITY_TOOL="$FAKE_BIN/security" \
CMUX_KEYCHAIN_DIR="$TMP_DIR/keychains" \
  run_helper "$APP" "$KEYCHAIN_DMG" "$KEYCHAIN_IMMUTABLE"
if grep -q '^smoke-with-keychain ' "$LOG"; then
  echo "FAIL: a launch smoke ran while the CI signing keychain still existed" >&2
  exit 1
fi
if [ -e "$KEYCHAIN_STATE/build.keychain.password" ]; then
  echo "FAIL: the helper did not delete the CI signing keychain" >&2
  exit 1
fi
sign_line="$(grep -n "^codesign --force --timestamp --keychain build.keychain --sign Developer ID Application: Fixture $KEYCHAIN_DMG" "$LOG" | head -1 | cut -d: -f1)"
unlock_line="$(grep -n '^security unlock-keychain .* build.keychain$' "$LOG" | head -1 | cut -d: -f1)"
delete_line="$(grep -n '^security delete-keychain build.keychain$' "$LOG" | head -1 | cut -d: -f1)"
smoke_line="$(grep -n '^smoke ' "$LOG" | head -1 | cut -d: -f1)"
if [ -z "$sign_line" ] || [ -z "$unlock_line" ] || [ -z "$delete_line" ] || [ -z "$smoke_line" ] \
  || [ "$unlock_line" -ge "$sign_line" ] || [ "$sign_line" -ge "$delete_line" ] || [ "$delete_line" -ge "$smoke_line" ]; then
  echo "FAIL: expected unlock, DMG signature, keychain delete, then smoke (unlock=$unlock_line sign=$sign_line delete=$delete_line smoke=$smoke_line)" >&2
  cat "$LOG" >&2
  exit 1
fi
echo "PASS: the CI signing keychain is deleted after the DMG signature and before any smoke"

# signing-keychain.sh create must finish with exit 0, delete the decoded
# certificate, and leave state that delete removes again.
: > "$LOG"
CREATE_STATE="$TMP_DIR/create-keychain-state"
CREATE_BIN="$TMP_DIR/create-bin"
mkdir -p "$CREATE_BIN"
cat > "$CREATE_BIN/security" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'security %s\n' "$*" >> "$CMUX_TEST_CALL_LOG"
if [ "${1:-}" = find-certificate ]; then
  printf -- '-----END CERTIFICATE-----\n-----END CERTIFICATE-----\n'
fi
EOF
printf '#!/usr/bin/env bash\necho 00000000-0000-4000-8000-000000000000\n' > "$CREATE_BIN/uuidgen"
chmod +x "$CREATE_BIN/security" "$CREATE_BIN/uuidgen"
if ! PATH="$CREATE_BIN:$PATH" \
  CMUX_TEST_CALL_LOG="$LOG" \
  CMUX_SIGNING_KEYCHAIN_STATE_DIR="$CREATE_STATE" \
  CMUX_SECURITY_TOOL="$CREATE_BIN/security" \
  CMUX_KEYCHAIN_DIR="$TMP_DIR/keychains" \
  APPLE_CERTIFICATE_BASE64="$(printf 'fixture-p12' | base64)" \
  APPLE_CERTIFICATE_PASSWORD=fixture-password \
  "$ROOT_DIR/scripts/ci/signing-keychain.sh" create; then
  echo "FAIL: signing-keychain.sh create must exit 0" >&2
  exit 1
fi
# `security import` picks the format from the file name; a name without .p12
# fails on a real keychain with "Unknown format in import". Name the format.
if ! grep -q '^security import [^ ]*\.p12 -k build\.keychain -f pkcs12 ' "$LOG" || ! grep -q '^security set-keychain-settings -lut 600 build.keychain$' "$LOG"; then
  echo "FAIL: create must import a .p12 file as pkcs12 into build.keychain with a 600 s idle lock" >&2
  cat "$LOG" >&2
  exit 1
fi
if compgen -G "$CREATE_STATE/certificate.*" >/dev/null || [ ! -s "$CREATE_STATE/build.keychain.password" ]; then
  echo "FAIL: create must delete the decoded certificate and keep only the keychain state" >&2
  exit 1
fi
if CMUX_SIGNING_KEYCHAIN_STATE_DIR="$CREATE_STATE" "$ROOT_DIR/scripts/ci/signing-keychain.sh" assert-deleted 2>/dev/null; then
  echo "FAIL: assert-deleted must fail while the keychain exists" >&2
  exit 1
fi
PATH="$CREATE_BIN:$PATH" CMUX_TEST_CALL_LOG="$LOG" CMUX_SIGNING_KEYCHAIN_STATE_DIR="$CREATE_STATE" \
  CMUX_SECURITY_TOOL="$CREATE_BIN/security" CMUX_KEYCHAIN_DIR="$TMP_DIR/keychains" \
  "$ROOT_DIR/scripts/ci/signing-keychain.sh" delete
CMUX_SIGNING_KEYCHAIN_STATE_DIR="$CREATE_STATE" "$ROOT_DIR/scripts/ci/signing-keychain.sh" assert-deleted
echo "PASS: signing-keychain.sh create, assert-deleted and delete"
