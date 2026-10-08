#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ci/notarize-nightly-dmg.sh"
RESUME_SCRIPT="$ROOT_DIR/scripts/ci/resume-nightly-notarization.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: executable nightly notarization helper is required" >&2
  exit 1
fi
if [ ! -x "$RESUME_SCRIPT" ]; then
  echo "FAIL: executable nightly notarization resume helper is required" >&2
  exit 1
fi

APP="$TMP_DIR/input/cmux NIGHTLY.app"
DMG="$TMP_DIR/cmux-nightly-macos.dmg"
IMMUTABLE="$TMP_DIR/cmux-nightly-immutable.dmg"
FAKE_BIN="$TMP_DIR/bin"
LOG="$TMP_DIR/calls.log"
HELPER_STATE="$TMP_DIR/helper-notarization.state"
mkdir -p "$APP/Contents/MacOS" "$FAKE_BIN"
printf 'signed-app-fixture\n' > "$APP/Contents/MacOS/cmux"
printf 'submission_id=fixture-id\ncdhash=fixture-cdhash\n' > "$HELPER_STATE"

cat > "$FAKE_BIN/create-dmg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'create-dmg %s\n' "$*" >> "$CMUX_TEST_CALL_LOG"
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
if [ "${1:-}" = "notarytool" ] && [ "${2:-}" = "submit" ]; then
  if [ "${CMUX_TEST_NOTARY_TIMEOUT:-0}" = 1 ]; then
    # notarytool writes a timeout response to stderr. The submission remains
    # In Progress and must never reach the stapling or publication path.
    printf '{"message":"Timeout of 25m reached before processing completed.","id":"fixture-id"}\n' >&2
    exit 1
  fi
  printf '{"id":"fixture-id","status":"%s"}\n' "${CMUX_TEST_NOTARY_STATUS:-Accepted}"
fi
if [ "${1:-}" = "notarytool" ] && [ "${2:-}" = "wait" ]; then
  printf '{"id":"fixture-id","status":"Accepted"}\n'
fi
if [ "${1:-}" = "notarytool" ] && [ "${2:-}" = "log" ]; then
  log_status="${CMUX_TEST_NOTARY_LOG_STATUS:-In Progress}"
  log_message="still processing"
  [ "$log_status" = Accepted ] && log_message="fixture log"
  printf '{"id":"fixture-id","status":"%s","message":"%s"}\n' "$log_status" "$log_message" >&2
  exit "${CMUX_TEST_NOTARY_LOG_EXIT:-0}"
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

for tool in spctl smoke metadata licenses syspolicy; do
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
  CMUX_SYSPOLICY_TOOL="$FAKE_BIN/syspolicy" \
  CMUX_SMOKE_TOOL="$FAKE_BIN/smoke" \
  CMUX_VERIFY_METADATA_TOOL="$FAKE_BIN/metadata" \
  CMUX_VERIFY_LICENSES_TOOL="$FAKE_BIN/licenses" \
  CMUX_NOTARIZE_COMPUTER_USE_HELPER_TOOL="$FAKE_BIN/notarize-computer-use-helper" \
  CMUX_COMPUTER_USE_NOTARY_SUBMISSION_FILE="$HELPER_STATE" \
  CMUX_APP_ENTITLEMENTS="$TMP_DIR/cmux.nightly.entitlements" \
  ASC_API_KEY_ID="${TEST_ASC_API_KEY_ID-FIXTUREKEY}" \
  ASC_API_ISSUER_ID="${TEST_ASC_API_ISSUER_ID-fixture-issuer}" \
  ASC_API_KEY_P8_BASE64="${TEST_ASC_API_KEY_P8_BASE64-$FIXTURE_P8_BASE64}" \
  APPLE_SIGNING_IDENTITY='Developer ID Application: Fixture' \
  "$SCRIPT" "$app" "$dmg" "$immutable"
}

run_resume() {
  CMUX_TEST_CALL_LOG="$LOG" \
  CMUX_TEST_SOURCE_APP="$APP" \
  CMUX_TEST_DETACH_STATE="$TMP_DIR/resume-detach-retried" \
  CMUX_NIGHTLY_MOUNT_DIR="$TMP_DIR/resume-mount" \
  CMUX_CODESIGN_TOOL="$FAKE_BIN/codesign" \
  CMUX_XCRUN_TOOL="$FAKE_BIN/xcrun" \
  CMUX_HDIUTIL_TOOL="$FAKE_BIN/hdiutil" \
  CMUX_SPCTL_TOOL="$FAKE_BIN/spctl" \
  CMUX_SYSPOLICY_TOOL="$FAKE_BIN/syspolicy" \
  CMUX_SMOKE_TOOL="$FAKE_BIN/smoke" \
  CMUX_VERIFY_METADATA_TOOL="$FAKE_BIN/metadata" \
  CMUX_VERIFY_LICENSES_TOOL="$FAKE_BIN/licenses" \
  CMUX_TEST_NOTARY_LOG_STATUS="${RESUME_LOG_STATUS:-Accepted}" \
  CMUX_TEST_NOTARY_LOG_EXIT="${RESUME_LOG_EXIT:-0}" \
  ASC_API_KEY_ID=FIXTUREKEY \
  ASC_API_ISSUER_ID=fixture-issuer \
  ASC_API_KEY_P8_BASE64="$FIXTURE_P8_BASE64" \
  "$RESUME_SCRIPT" "$@"
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

# The exact recovery artifact can be resumed without rebuilding or submitting
# a second Apple request. The saved SHA and submission id gate all stapling and
# publication work.
: > "$LOG"
rm -f "$IMMUTABLE"
if ! run_resume "$TIMEOUT_STATE" "$APP" "$DMG" "$IMMUTABLE" >/dev/null 2>"$TMP_DIR/resume.err"; then
  echo "FAIL: accepted recovery submission did not resume" >&2
  cat "$TMP_DIR/resume.err" >&2
  exit 1
fi
if grep -q '^xcrun notarytool submit ' "$LOG" \
  || ! grep -q '^xcrun notarytool wait fixture-id ' "$LOG" \
  || ! grep -q '^xcrun notarytool log fixture-id ' "$LOG"; then
  echo "FAIL: recovery path must wait on the saved id without re-submitting" >&2
  exit 1
fi
if ! grep -q '^xcrun stapler staple ' "$LOG" || [ ! -f "$IMMUTABLE" ]; then
  echo "FAIL: recovery path did not staple and preserve the verified immutable DMG" >&2
  exit 1
fi
if ! grep -Fxq "syspolicy distribution $APP" "$LOG"; then
  echo "FAIL: recovery path did not run the published-artifact policy gate" >&2
  exit 1
fi

: > "$LOG"
rm -f "$IMMUTABLE"
if RESUME_LOG_STATUS=In\ Progress run_resume "$TIMEOUT_STATE" "$APP" "$DMG" "$IMMUTABLE" >/dev/null 2>"$TMP_DIR/resume-rejected.err"; then
  echo "FAIL: recovery path accepted a non-Accepted Apple log" >&2
  exit 1
fi
if grep -Fq 'xcrun stapler staple' "$LOG" || [ -e "$IMMUTABLE" ]; then
  echo "FAIL: non-Accepted Apple log must block stapling and publication" >&2
  exit 1
fi

: > "$LOG"
rm -f "$IMMUTABLE"
if RESUME_LOG_EXIT=1 run_resume "$TIMEOUT_STATE" "$APP" "$DMG" "$IMMUTABLE" >/dev/null 2>"$TMP_DIR/resume-log-failed.err"; then
  echo "FAIL: recovery path accepted a failed Apple log request" >&2
  exit 1
fi
if grep -Fq 'xcrun stapler staple' "$LOG" || [ -e "$IMMUTABLE" ]; then
  echo "FAIL: failed Apple log request must block stapling and publication" >&2
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
