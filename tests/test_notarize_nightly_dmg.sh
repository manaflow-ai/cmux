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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/cmux Computer Use.app/Contents" "$FAKE_BIN"
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
if [ "${1:-}" = "-d" ]; then
  # codesign -d -a <arch> --verbose=4 <bundle>: one CDHash per slice.
  printf 'CDHash=%s\n' "$(printf '%s' "$3" | shasum | cut -c1-40)" >&2
fi
EOF

cat > "$FAKE_BIN/lipo" <<'EOF'
#!/usr/bin/env bash
printf 'arm64\n'
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
  if [ "${CMUX_TEST_STAPLED_TIMEOUT:-0}" = 1 ]; then
    printf '{"message":"Timeout of 25m reached before processing completed.","id":"fixture-stapled-id"}\n' >&2
    exit 1
  fi
  printf '{"id":"fixture-stapled-id","status":"%s"}\n' "${CMUX_TEST_STAPLED_STATUS:-Accepted}"
  exit 0
fi
if [ "${1:-}" = "notarytool" ] && [ "${2:-}" = "submit" ]; then
  if [ "${CMUX_TEST_NOTARY_TIMEOUT:-0}" = 1 ]; then
    # notarytool writes timeout diagnostics, including the id, on stderr.
    printf '{"message":"Timeout of 25m reached before processing completed.","id":"fixture-id"}\n' >&2
    exit 1
  fi
  printf '{"id":"fixture-id","status":"%s"}\n' "${CMUX_TEST_NOTARY_STATUS:-Accepted}"
fi
if [ "${1:-}" = "notarytool" ] && [ "${2:-}" = "info" ]; then
  if [ "${3:-}" = fixture-first-id ]; then
    # The accepted first DMG of a handed-off stapled-app DMG.
    printf '{"id":"%s","status":"Accepted"}\n' "${3:-}"
  else
    printf '{"id":"%s","status":"%s"}\n' "${3:-}" "${CMUX_TEST_NOTARY_STATUS:-Accepted}"
  fi
fi
if [ "${1:-}" = "notarytool" ] && [ "${2:-}" = "history" ]; then
  if [ -n "${CMUX_TEST_HISTORY_JSON:-}" ]; then printf '%s\n' "$CMUX_TEST_HISTORY_JSON"; else printf '{"history":[]}\n'; fi
fi
if [ "${1:-}" = "notarytool" ] && [ "${2:-}" = "log" ] && [ "${3:-}" = fixture-stapled-id ]; then
  printf '{"id":"fixture-stapled-id","status":"%s"}\n' "${CMUX_TEST_WAIT_STATUS:-Accepted}"
  exit 0
fi
if [ "${1:-}" = "notarytool" ] && [ "${2:-}" = "log" ]; then
  printf '{"status":"Accepted","ticketContents":%s}\n' "${CMUX_TEST_DMG_TICKET:-[]}"
fi
if [ "${1:-}" = "stapler" ] && [ "${2:-}" = "validate" ] && [ "${CMUX_TEST_HELPER_UNSTAPLED:-0}" = 1 ] \
  && [[ "${3:-}" == *"/cmux Computer Use.app" ]]; then
  exit 65
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
[ "${CMUX_TEST_FAIL_TOOL:-}" != "$(basename "$0")" ]
EOF
done

cat > "$FAKE_BIN/notarize-computer-use-helper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'notarize-helper %s\n' "$*" >> "$CMUX_TEST_CALL_LOG"
exit "${CMUX_TEST_HELPER_EXIT:-0}"
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
  CMUX_LIPO_TOOL="$FAKE_BIN/lipo" \
  CMUX_XCRUN_TOOL="$FAKE_BIN/xcrun" \
  CMUX_HDIUTIL_TOOL="$FAKE_BIN/hdiutil" \
  CMUX_SPCTL_TOOL="$FAKE_BIN/spctl" \
  CMUX_SMOKE_TOOL="$FAKE_BIN/smoke" \
  CMUX_VERIFY_METADATA_TOOL="$FAKE_BIN/metadata" \
  CMUX_VERIFY_LICENSES_TOOL="$FAKE_BIN/licenses" \
  CMUX_NOTARIZE_COMPUTER_USE_HELPER_TOOL="$FAKE_BIN/notarize-computer-use-helper" \
  CMUX_COMPUTER_USE_NOTARY_SUBMISSION_FILE="$HELPER_STATE" \
  CMUX_NOTARY_SUBMIT_ONLY="${TEST_NOTARY_SUBMIT_ONLY:-false}" \
  CMUX_NOTARY_PENDING_ON_TIMEOUT="${TEST_NOTARY_PENDING_ON_TIMEOUT:-false}" \
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
if CMUX_TEST_NOTARY_STATUS=Rejected run_helper 2>"$TMP_DIR/rejected.err"; then
  echo "FAIL: rejected notarization unexpectedly succeeded" >&2
  exit 1
fi
if ! grep -q "fixture-id" "$TMP_DIR/rejected.err"; then
  echo "FAIL: a rejected notarization must name its submission id" >&2
  cat "$TMP_DIR/rejected.err" >&2
  exit 1
fi
if grep -Fq 'xcrun stapler staple' "$LOG"; then
  echo "FAIL: rejected DMG must not be stapled" >&2
  exit 1
fi

# Run 37620073632 waited 78 minutes on a notary submission that never
# finished, until the job was cancelled. The wait is bounded, and a timed-out
# submission fails at once with its id, before anything is stapled.
: > "$LOG"
if ! grep -Eq "^xcrun notarytool submit $DMG .*--wait --timeout [0-9]+m" <(CMUX_TEST_NOTARY_STATUS=Accepted run_helper >/dev/null 2>&1; cat "$LOG"); then
  echo "FAIL: the DMG notarization wait must have a --timeout" >&2
  exit 1
fi
: > "$LOG"
rm -rf "$TMP_DIR/cmux-nightly-mount"
if CMUX_TEST_NOTARY_TIMEOUT=1 run_helper >/dev/null 2>"$TMP_DIR/timeout.err"; then
  echo "FAIL: a notarization that timed out unexpectedly succeeded" >&2
  exit 1
fi
if ! grep -q "did not finish" "$TMP_DIR/timeout.err" || ! grep -q "fixture-id" "$TMP_DIR/timeout.err"; then
  echo "FAIL: a timed-out notarization must say so and name its submission" >&2
  cat "$TMP_DIR/timeout.err" >&2
  exit 1
fi
if grep -Fq 'xcrun stapler staple' "$LOG"; then
  echo "FAIL: a timed-out DMG must not be stapled" >&2
  exit 1
fi

# The shipped DMG carries the stapled app (CMUX_STAPLE_APP_IN_DMG=true, the
# default). After Apple accepts the first DMG, the app is stapled from that
# ticket, a new DMG is built around it, signed with a fresh keychain that is
# deleted before the second submission, notarized, stapled and only then put
# at the release path. A second submission that fails or times out leaves the
# first DMG and its accepted state for a later run.
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
rm -rf "$TMP_DIR/cmux-nightly-mount" "$TMP_DIR/detach-retried" "$IMMUTABLE" "$DMG.notarization.state"
if ! run_stapled >/dev/null 2>"$TMP_DIR/stapled.err"; then
  echo "FAIL: packaging the stapled app into the DMG failed" >&2
  cat "$TMP_DIR/stapled.err" >&2
  exit 1
fi
if [ "$(grep -c '^xcrun notarytool submit ' "$LOG")" -ne 2 ] \
  || [ "$(grep -c '^xcrun notarytool submit .*/stapled-app/cmux-nightly-immutable-stapled-app.dmg ' "$LOG")" -ne 1 ]; then
  echo "FAIL: expected the first DMG and the stapled-app DMG as the only two submissions" >&2
  cat "$LOG" >&2
  exit 1
fi
first_submit="$(line_of "xcrun notarytool submit $DMG ")"
app_staple="$(line_of "xcrun stapler staple $APP")"
create2="$(grep -n "^keychain create" "$LOG" | head -n 1 | cut -d: -f1)"
dmg2="$(grep -n "^create-dmg --no-code-sign $APP .*/stapled-app/work\$" "$LOG" | head -n 1 | cut -d: -f1)"
sign2="$(grep -n "^codesign --force --timestamp --keychain build.keychain .*/stapled-app/cmux-nightly-immutable-stapled-app.dmg\$" "$LOG" | head -n 1 | cut -d: -f1)"
delete2="$(grep -n '^keychain delete' "$LOG" | awk -F: -v after="${sign2:-0}" '$1 > after {print $1; exit}')"
submit2="$(grep -n '^xcrun notarytool submit .*/stapled-app/' "$LOG" | head -n 1 | cut -d: -f1)"
staple2="$(grep -n '^xcrun stapler staple .*/stapled-app/cmux-nightly-immutable-stapled-app.dmg$' "$LOG" | head -n 1 | cut -d: -f1)"
attach2="$(grep -n '^hdiutil attach .*/stapled-app/cmux-nightly-immutable-stapled-app.dmg ' "$LOG" | head -n 1 | cut -d: -f1)"
mounted_staple="$(line_of "xcrun stapler validate $TMP_DIR/cmux-nightly-mount/cmux NIGHTLY.app")"
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
if grep -q '^xcrun stapler staple '"$DMG"'$' "$LOG"; then
  echo "FAIL: the first DMG (without the stapled app) must not be stapled" >&2
  exit 1
fi
if ! grep -Fxq 'keychain create cert=set' "$LOG" || grep -v '^create-dmg-umask 0022$' "$LOG" | grep -q '^create-dmg-umask '; then
  echo "FAIL: the stapled-app DMG keychain needs the certificate, and create-dmg must copy the app with umask 022 (the notary sidecars set 077)" >&2
  grep -E '^(keychain|create-dmg-umask) ' "$LOG" >&2
  exit 1
fi
if [ ! -f "$DMG" ] || [ ! -f "$IMMUTABLE" ] || ! cmp -s "$DMG" "$IMMUTABLE" || [ -e "$DMG.notarization.state" ]; then
  echo "FAIL: the stapled-app DMG must replace the release DMG, be copied to the immutable path, and leave no pending state" >&2
  exit 1
fi
echo "PASS: the shipped DMG carries the stapled app and its own ticket"

: > "$LOG"
rm -rf "$TMP_DIR/cmux-nightly-mount" "$TMP_DIR/detach-retried" "$IMMUTABLE" "$DMG.notarization.state" "$DMG.notarization.log"
STAPLED_GITHUB_OUTPUT="$TMP_DIR/stapled.github-output"
: > "$STAPLED_GITHUB_OUTPUT"
first_dmg_sha=""
if ! CMUX_TEST_STAPLED_TIMEOUT=1 TEST_NOTARY_PENDING_ON_TIMEOUT=true GITHUB_OUTPUT="$STAPLED_GITHUB_OUTPUT" \
  run_stapled >/dev/null 2>"$TMP_DIR/stapled-timeout.err"; then
  echo "FAIL: a stapled-app DMG still in Apple's queue must hand off, not fail" >&2
  cat "$TMP_DIR/stapled-timeout.err" >&2
  exit 1
fi
handed_dmg_sha="$(shasum -a 256 "$DMG" | awk '{print $1}')"
# The second submission itself is handed off: its DMG takes the release path
# and the state names it, so a later run continues it without a new one.
if ! grep -Fxq "submission_pending=true" "$STAPLED_GITHUB_OUTPUT" \
  || ! grep -Fxq "stapled_app_pending=true" "$STAPLED_GITHUB_OUTPUT" \
  || ! grep -Fxq "submission_id=fixture-stapled-id" "$DMG.notarization.state" \
  || ! grep -Fxq "status=In Progress" "$DMG.notarization.state" \
  || ! grep -Fxq "stapled_app=true" "$DMG.notarization.state" \
  || ! grep -Fxq "wait_timed_out=true" "$DMG.notarization.state" \
  || ! grep -Fxq "dmg_sha256=$handed_dmg_sha" "$DMG.notarization.state" \
  || ! grep -Fxq "first_submission_id=fixture-id" "$DMG.notarization.state" \
  || ! grep -Eq '^stapled_submitted_at=[0-9]+$' "$DMG.notarization.state" \
  || [ ! -f "${DMG%.dmg}.first.dmg" ] \
  || ! grep -Fxq "first_dmg_sha256=$(shasum -a 256 "${DMG%.dmg}.first.dmg" | awk '{print $1}')" "$DMG.notarization.state" \
  || ! grep -q '^xcrun notarytool submit .*/stapled-app/cmux-nightly-immutable-stapled-app.dmg ' "$LOG" \
  || [ ! -s "$DMG.notarization.log" ] \
  || ! grep -q 'fixture-stapled-id' "$DMG.notarization.log" \
  || grep -q '^xcrun stapler staple .*\.dmg$' "$LOG" \
  || [ -e "$IMMUTABLE" ]; then
  echo "FAIL: a pending stapled-app DMG must hand off its own submission and DMG for a later run" >&2
  cat "$LOG" "$DMG.notarization.state" >&2
  exit 1
fi
: > "$LOG"
rm -rf "$TMP_DIR/cmux-nightly-mount" "$TMP_DIR/detach-retried" "$IMMUTABLE" "$DMG.notarization.state"
if CMUX_TEST_STAPLED_STATUS=Invalid run_stapled >/dev/null 2>"$TMP_DIR/stapled-rejected.err"; then
  echo "FAIL: a rejected stapled-app DMG unexpectedly succeeded" >&2
  exit 1
fi
if ! grep -Fxq "submission_id=fixture-id" "$DMG.notarization.state" || grep -Fxq "stapled_app=true" "$DMG.notarization.state"; then
  echo "FAIL: a rejected stapled-app DMG must leave the accepted first submission as the state" >&2
  exit 1
fi
if grep -q '^xcrun stapler staple .*\.dmg$' "$LOG" || [ -e "$IMMUTABLE" ] || ! grep -Fxq "status=Accepted" "$DMG.notarization.state"; then
  echo "FAIL: a rejected stapled-app DMG must publish nothing and keep the first submission continuable" >&2
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
echo "PASS: a stapled-app DMG that Apple has not accepted publishes nothing and keeps the first submission"

# Published nightly-next submits without waiting on Apple's queue. The exact
# state and output sidecars are the handoff; no ticket, staple, or immutable
# publication artifact is allowed before a later Accepted result.
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

# Published nightly-next waits a bounded time in the job. A wait that runs out
# hands the exact submission to the next nightly-next run instead of failing;
# it never staples or produces the immutable publication artifact.
: > "$LOG"
PENDING_STATE="$TMP_DIR/cmux-nightly-pending.state"
PENDING_OUTPUT="$TMP_DIR/cmux-nightly-pending.log"
PENDING_GITHUB_OUTPUT="$TMP_DIR/pending.github-output"
rm -f "$PENDING_STATE" "$PENDING_OUTPUT" "$PENDING_GITHUB_OUTPUT" "$IMMUTABLE"
if ! TEST_NOTARY_PENDING_ON_TIMEOUT=true CMUX_TEST_NOTARY_TIMEOUT=1 \
  CMUX_NOTARY_SUBMISSION_FILE="$PENDING_STATE" \
  CMUX_NOTARY_OUTPUT_FILE="$PENDING_OUTPUT" \
  GITHUB_OUTPUT="$PENDING_GITHUB_OUTPUT" \
  run_helper >/dev/null 2>"$TMP_DIR/pending.err"; then
  echo "FAIL: a bounded nightly-next wait that ran out must hand off the submission, not fail" >&2
  cat "$TMP_DIR/pending.err" >&2
  exit 1
fi
if ! grep -Fxq "submission_id=fixture-id" "$PENDING_STATE" \
  || ! grep -Fxq "wait_timed_out=true" "$PENDING_STATE" \
  || ! grep -Fxq "submission_pending=true" "$PENDING_GITHUB_OUTPUT" \
  || ! grep -q '^xcrun notarytool submit .*--wait --timeout ' "$LOG" \
  || grep -Fq 'xcrun stapler staple' "$LOG" \
  || [ -e "$IMMUTABLE" ]; then
  echo "FAIL: a timed-out bounded wait did not hand off a pending ticket without stapling" >&2
  cat "$LOG" "$PENDING_STATE" "$PENDING_GITHUB_OUTPUT" >&2
  exit 1
fi

# The same mode still fails a rejected submission, and still staples and
# validates an accepted one in the job.
: > "$LOG"
rm -f "$PENDING_GITHUB_OUTPUT" "$IMMUTABLE"
if TEST_NOTARY_PENDING_ON_TIMEOUT=true CMUX_TEST_NOTARY_STATUS=Invalid \
  GITHUB_OUTPUT="$PENDING_GITHUB_OUTPUT" run_helper >/dev/null 2>"$TMP_DIR/pending-invalid.err"; then
  echo "FAIL: an Invalid submission must fail even when timeouts hand off" >&2
  exit 1
fi
if [ -s "$PENDING_GITHUB_OUTPUT" ] && grep -Fq "submission_pending=true" "$PENDING_GITHUB_OUTPUT"; then
  echo "FAIL: an Invalid submission must not be handed off as pending" >&2
  exit 1
fi
: > "$LOG"
rm -f "$PENDING_GITHUB_OUTPUT" "$IMMUTABLE"
rm -rf "$TMP_DIR/cmux-nightly-mount"
if ! TEST_NOTARY_PENDING_ON_TIMEOUT=true GITHUB_OUTPUT="$PENDING_GITHUB_OUTPUT" \
  run_helper >/dev/null 2>"$TMP_DIR/pending-accepted.err"; then
  echo "FAIL: an Accepted submission failed when timeouts hand off" >&2
  cat "$TMP_DIR/pending-accepted.err" >&2
  exit 1
fi
if ! grep -Fq 'xcrun stapler staple' "$LOG" || [ ! -e "$IMMUTABLE" ] \
  || { [ -e "$PENDING_GITHUB_OUTPUT" ] && grep -Fq "submission_pending=true" "$PENDING_GITHUB_OUTPUT"; }; then
  echo "FAIL: an Accepted submission must be stapled and published in the job" >&2
  cat "$LOG" >&2
  exit 1
fi

# The next nightly-next run continues a saved submission: it checks the exact
# DMG against the state, asks Apple for the status instead of submitting, and
# staples and validates only an Accepted one.
continue_state() {
  local state="$1" dmg="$2"
  {
    printf 'submission_id=fixture-saved-id\n'
    printf 'status=In Progress\n'
    printf 'dmg_path=%s\n' "$dmg"
    printf 'dmg_sha256=%s\n' "$(shasum -a 256 "$dmg" | awk '{print $1}')"
    printf 'submit_exit=1\n'
    printf 'wait_timed_out=true\n'
  } > "$state"
}
CONTINUE_DMG="$TMP_DIR/cmux-nightly-continue.dmg"
CONTINUE_STATE="$TMP_DIR/cmux-nightly-continue.state"
CONTINUE_IMMUTABLE="$TMP_DIR/cmux-nightly-continue-1.dmg"
CONTINUE_GITHUB_OUTPUT="$TMP_DIR/continue.github-output"
run_continue() {
  CMUX_TEST_CALL_LOG="$LOG" \
  CMUX_TEST_SOURCE_APP="$APP" \
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
  CMUX_NOTARIZE_COMPUTER_USE_HELPER_TOOL="$FAKE_BIN/notarize-helper" \
  CMUX_NOTARY_CONTINUE_STATE="$CONTINUE_STATE" \
  GITHUB_OUTPUT="$CONTINUE_GITHUB_OUTPUT" \
  ASC_API_KEY_ID=FIXTUREKEY \
  ASC_API_ISSUER_ID=fixture-issuer \
  ASC_API_KEY_P8_BASE64="$FIXTURE_P8_BASE64" \
  "$ROOT_DIR/scripts/ci/notarize-nightly-dmg.sh" "$APP" "$CONTINUE_DMG" "$CONTINUE_IMMUTABLE"
}
reset_continue() {
  : > "$LOG"
  rm -f "$CONTINUE_GITHUB_OUTPUT" "$CONTINUE_IMMUTABLE"
  rm -rf "$TMP_DIR/cmux-nightly-mount"
  printf 'signed dmg from an earlier run\n' > "$CONTINUE_DMG"
  continue_state "$CONTINUE_STATE" "$CONTINUE_DMG"
}

reset_continue
if ! run_continue >/dev/null 2>"$TMP_DIR/continue.err"; then
  echo "FAIL: continuing an Accepted saved submission failed" >&2
  cat "$TMP_DIR/continue.err" >&2
  exit 1
fi
if ! grep -q '^xcrun notarytool info fixture-saved-id ' "$LOG" \
  || grep -q '^xcrun notarytool submit' "$LOG" \
  || grep -q '^create-dmg' "$LOG" \
  || grep -q '^codesign' "$LOG" \
  || grep -q '^notarize-helper' "$LOG" \
  || ! grep -Fq "xcrun stapler staple $APP" "$LOG" \
  || ! grep -Fq "xcrun stapler staple $CONTINUE_DMG" "$LOG" \
  || ! grep -Fq "spctl -a -vv --type execute $TMP_DIR/cmux-nightly-mount" "$LOG" \
  || [ ! -e "$CONTINUE_IMMUTABLE" ] \
  || { [ -e "$CONTINUE_GITHUB_OUTPUT" ] && grep -Fq "submission_pending=true" "$CONTINUE_GITHUB_OUTPUT"; }; then
  echo "FAIL: an Accepted saved submission must be stapled and validated without resubmitting or rebuilding" >&2
  cat "$LOG" >&2
  exit 1
fi

# The recovery job continues an accepted first DMG and builds, signs and
# notarizes the DMG around the stapled app; that DMG replaces the saved one.
reset_continue
saved_state="$(cat "$CONTINUE_STATE")"
if ! CMUX_STAPLE_APP_IN_DMG=true CMUX_SIGNING_KEYCHAIN_TOOL="$FAKE_BIN/keychain" \
  APPLE_SIGNING_IDENTITY='Developer ID Application: Fixture' \
  APPLE_CERTIFICATE_BASE64=fixture APPLE_CERTIFICATE_PASSWORD=fixture \
  run_continue >/dev/null 2>"$TMP_DIR/continue-stapled.err"; then
  echo "FAIL: continuing an Accepted saved submission with the stapled-app DMG failed" >&2
  cat "$TMP_DIR/continue-stapled.err" >&2
  exit 1
fi
if ! grep -q '^xcrun notarytool info fixture-saved-id ' "$LOG" \
  || grep -q "^xcrun notarytool submit $CONTINUE_DMG " "$LOG" \
  || [ "$(grep -c '^xcrun notarytool submit .*/stapled-app/cmux-nightly-continue-1-stapled-app.dmg ' "$LOG")" -ne 1 ] \
  || ! grep -q '^xcrun stapler staple .*/stapled-app/cmux-nightly-continue-1-stapled-app.dmg$' "$LOG" \
  || ! grep -Fq "xcrun stapler validate $TMP_DIR/cmux-nightly-mount/cmux NIGHTLY.app" "$LOG" \
  || ! grep -Fxq 'notary_status=Accepted' "$CONTINUE_GITHUB_OUTPUT" \
  || grep -Fxq 'submission_pending=true' "$CONTINUE_GITHUB_OUTPUT" \
  || [ "$(cat "$CONTINUE_STATE")" != "$saved_state" ] \
  || [ ! -e "$CONTINUE_IMMUTABLE" ] || ! cmp -s "$CONTINUE_DMG" "$CONTINUE_IMMUTABLE"; then
  echo "FAIL: a continuation must ship the stapled-app DMG without resubmitting the saved DMG" >&2
  cat "$LOG" >&2
  exit 1
fi

# A handed-off stapled-app submission (stapled_app=true) is stapled and shipped
# as it is: no further DMG is built or submitted.
reset_continue
printf 'stapled_app=true\n' >> "$CONTINUE_STATE"
if ! CMUX_STAPLE_APP_IN_DMG=true CMUX_SIGNING_KEYCHAIN_TOOL="$FAKE_BIN/keychain" \
  APPLE_SIGNING_IDENTITY='Developer ID Application: Fixture' \
  APPLE_CERTIFICATE_BASE64=fixture APPLE_CERTIFICATE_PASSWORD=fixture \
  run_continue >/dev/null 2>"$TMP_DIR/continue-stapled-handoff.err"; then
  echo "FAIL: continuing a handed-off stapled-app submission failed" >&2
  cat "$TMP_DIR/continue-stapled-handoff.err" >&2
  exit 1
fi
if grep -q '^xcrun notarytool submit' "$LOG" || grep -q '^create-dmg ' "$LOG" || grep -q '^keychain create' "$LOG" \
  || ! grep -Fxq "xcrun stapler staple $CONTINUE_DMG" "$LOG" \
  || ! grep -Fq "xcrun stapler validate $TMP_DIR/cmux-nightly-mount/cmux NIGHTLY.app" "$LOG" \
  || [ ! -e "$CONTINUE_IMMUTABLE" ]; then
  echo "FAIL: a handed-off stapled-app submission must be stapled and shipped without a new DMG" >&2
  cat "$LOG" >&2
  exit 1
fi

# A handed-off stapled-app submission still in Apple's queue says so, so the
# recovery job does not move on to an older build.
reset_continue
printf 'stapled_app=true\n' >> "$CONTINUE_STATE"
if ! CMUX_TEST_NOTARY_STATUS="In Progress" CMUX_STAPLE_APP_IN_DMG=true CMUX_SIGNING_KEYCHAIN_TOOL="$FAKE_BIN/keychain" \
  APPLE_SIGNING_IDENTITY='Developer ID Application: Fixture' \
  APPLE_CERTIFICATE_BASE64=fixture APPLE_CERTIFICATE_PASSWORD=fixture \
  run_continue >/dev/null 2>"$TMP_DIR/continue-stapled-pending.err" \
  || ! grep -Fxq "submission_pending=true" "$CONTINUE_GITHUB_OUTPUT" \
  || ! grep -Fxq "stapled_app_pending=true" "$CONTINUE_GITHUB_OUTPUT" \
  || grep -q '^xcrun stapler staple' "$LOG"; then
  echo "FAIL: a queued handed-off stapled-app submission must stay pending and say stapled_app_pending" >&2
  cat "$TMP_DIR/continue-stapled-pending.err" "$LOG" >&2
  exit 1
fi

# The 6 h fallback (chief 2026-10-16). A handed-off stapled-app DMG that
# Apple has not accepted 6 h after its recorded submit time: the accepted
# first DMG beside it is stapled and ships, with a warning that names the
# pending submission. Before 6 h it stays pending.
run_fallback_continue() {
  CMUX_STAPLE_APP_IN_DMG=true CMUX_SIGNING_KEYCHAIN_TOOL="$FAKE_BIN/keychain" \
  APPLE_SIGNING_IDENTITY='Developer ID Application: Fixture' \
  APPLE_CERTIFICATE_BASE64=fixture APPLE_CERTIFICATE_PASSWORD=fixture \
  run_continue
}
first_continue_dmg="${CONTINUE_DMG%.dmg}.first.dmg"
stage2_state() {
  printf 'accepted first dmg\n' > "$first_continue_dmg"
  {
    printf 'stapled_app=true\n'
    printf 'first_submission_id=fixture-first-id\n'
    printf 'first_dmg_sha256=%s\n' "$(shasum -a 256 "$first_continue_dmg" | awk '{print $1}')"
    printf 'stapled_submitted_at=%s\n' "$1"
  } >> "$CONTINUE_STATE"
}
reset_continue
stage2_state "$(( $(date +%s) - 7 * 3600 ))"
if ! CMUX_TEST_NOTARY_STATUS="In Progress" run_fallback_continue >"$TMP_DIR/fallback.out" 2>"$TMP_DIR/fallback.err"; then
  echo "FAIL: the 6 h fallback must ship the accepted first DMG" >&2
  cat "$TMP_DIR/fallback.err" >&2
  exit 1
fi
if ! grep -Fxq "stapled_app_fallback=true" "$CONTINUE_GITHUB_OUTPUT" \
  || ! grep -Fxq "stapled_app_pending_id=fixture-saved-id" "$CONTINUE_GITHUB_OUTPUT" \
  || grep -Fxq "submission_pending=true" "$CONTINUE_GITHUB_OUTPUT" \
  || grep -q '^xcrun notarytool submit' "$LOG" \
  || ! grep -Fxq "xcrun stapler staple $first_continue_dmg" "$LOG" \
  || grep -Fq "xcrun stapler validate $TMP_DIR/cmux-nightly-mount/cmux NIGHTLY.app" "$LOG" \
  || [ "$(cat "$CONTINUE_DMG")" != "accepted first dmg" ] \
  || ! cmp -s "$CONTINUE_DMG" "$CONTINUE_IMMUTABLE" \
  || [ -e "$first_continue_dmg" ] \
  || ! grep -q '::warning title=App shipped without its own ticket::.*fixture-saved-id' "$TMP_DIR/fallback.out"; then
  echo "FAIL: the 6 h fallback must staple and ship the first DMG, name the pending submission, and submit nothing" >&2
  cat "$LOG" "$CONTINUE_GITHUB_OUTPUT" >&2
  exit 1
fi
reset_continue
stage2_state "$(( $(date +%s) - 3600 ))"
if ! CMUX_TEST_NOTARY_STATUS="In Progress" run_fallback_continue >/dev/null 2>&1 \
  || ! grep -Fxq "stapled_app_pending=true" "$CONTINUE_GITHUB_OUTPUT" \
  || grep -Fxq "stapled_app_fallback=true" "$CONTINUE_GITHUB_OUTPUT" \
  || grep -q '^xcrun stapler staple' "$LOG"; then
  echo "FAIL: before 6 h a handed-off stapled-app DMG stays pending" >&2
  exit 1
fi
# The tampered first DMG is never published.
reset_continue
stage2_state "$(( $(date +%s) - 7 * 3600 ))"
printf 'tampered\n' > "$first_continue_dmg"
if CMUX_TEST_NOTARY_STATUS="In Progress" run_fallback_continue >/dev/null 2>&1 || [ -e "$CONTINUE_IMMUTABLE" ]; then
  echo "FAIL: a first DMG whose SHA-256 differs from its record must not ship" >&2
  exit 1
fi
rm -f "$first_continue_dmg"
# A continuation of the accepted first DMG (the recovery path, which cannot
# hand off) counts from Apple's earliest submission of this build's
# stapled-app DMG name: past 6 h the first DMG ships without a new submission.
reset_continue
old_created="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=7)).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')"
if ! CMUX_TEST_HISTORY_JSON="{\"history\":[{\"id\":\"fixture-old-stapled-id\",\"name\":\"cmux-nightly-continue-1-stapled-app.dmg\",\"createdDate\":\"$old_created\",\"status\":\"In Progress\"},{\"id\":\"other\",\"name\":\"other.dmg\",\"createdDate\":\"$old_created\",\"status\":\"Accepted\"}]}" \
  run_fallback_continue >/dev/null 2>"$TMP_DIR/fallback-stage1.err" \
  || ! grep -Fxq "stapled_app_fallback=true" "$CONTINUE_GITHUB_OUTPUT" \
  || ! grep -Fxq "stapled_app_pending_id=fixture-old-stapled-id" "$CONTINUE_GITHUB_OUTPUT" \
  || grep -q '^xcrun notarytool submit' "$LOG" \
  || ! grep -Fxq "xcrun stapler staple $CONTINUE_DMG" "$LOG" \
  || [ ! -e "$CONTINUE_IMMUTABLE" ]; then
  echo "FAIL: a recovery continuation past 6 h of Apple's first stapled-app submission must ship the first DMG" >&2
  cat "$TMP_DIR/fallback-stage1.err" "$LOG" >&2
  exit 1
fi
# A refused stapled-app DMG (Invalid) also ships the first DMG once 6 h passed,
# and waits before that.
reset_continue
stage2_state "$(( $(date +%s) - 7 * 3600 ))"
if ! CMUX_TEST_NOTARY_STATUS=Invalid run_fallback_continue >/dev/null 2>&1 \
  || ! grep -Fxq "stapled_app_fallback=true" "$CONTINUE_GITHUB_OUTPUT" \
  || [ "$(cat "$CONTINUE_DMG")" != "accepted first dmg" ]; then
  echo "FAIL: a refused stapled-app DMG past 6 h must ship the accepted first DMG" >&2
  exit 1
fi
reset_continue
stage2_state "$(( $(date +%s) - 3600 ))"
if ! CMUX_TEST_NOTARY_STATUS=Invalid run_fallback_continue >/dev/null 2>&1 \
  || ! grep -Fxq "stapled_app_pending=true" "$CONTINUE_GITHUB_OUTPUT" \
  || grep -q '^xcrun stapler staple' "$LOG"; then
  echo "FAIL: a refused stapled-app DMG before 6 h waits for the fallback" >&2
  exit 1
fi
rm -f "$first_continue_dmg"
# While a newer build's stapled-app DMG waits, an older accepted build makes
# no new submission; a date without a fraction still counts.
reset_continue
if ! CMUX_STAPLED_APP_NO_NEW_SUBMISSION=true run_fallback_continue >/dev/null 2>&1 \
  || grep -q '^xcrun notarytool submit' "$LOG" \
  || ! grep -Fxq "stapled_app_pending=true" "$CONTINUE_GITHUB_OUTPUT"; then
  echo "FAIL: an older build behind a pending stapled-app DMG must not submit a new one" >&2
  exit 1
fi
reset_continue
old_plain="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=7)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
if ! CMUX_STAPLED_APP_NO_NEW_SUBMISSION=true CMUX_TEST_HISTORY_JSON="{\"history\":[{\"id\":\"fixture-plain-id\",\"name\":\"cmux-nightly-continue-1-stapled-app.dmg\",\"createdDate\":\"$old_plain\"}]}" \
  run_fallback_continue >/dev/null 2>&1 \
  || ! grep -Fxq "stapled_app_pending_id=fixture-plain-id" "$CONTINUE_GITHUB_OUTPUT"; then
  echo "FAIL: an older build past its own 6 h ships its first DMG even behind a pending newer build" >&2
  exit 1
fi
echo "PASS: the 6 h stapled-app fallback ships only the accepted first DMG and names the pending submission"

reset_continue
if ! CMUX_TEST_NOTARY_STATUS="In Progress" run_continue >/dev/null 2>"$TMP_DIR/continue-pending.err"; then
  echo "FAIL: a saved submission still in progress must stay pending, not fail" >&2
  cat "$TMP_DIR/continue-pending.err" >&2
  exit 1
fi
if ! grep -Fxq "submission_pending=true" "$CONTINUE_GITHUB_OUTPUT" \
  || grep -Fq 'xcrun stapler staple' "$LOG" || [ -e "$CONTINUE_IMMUTABLE" ] \
  || ! grep -Fxq "submission_id=fixture-saved-id" "$CONTINUE_STATE"; then
  echo "FAIL: a saved submission in progress must stay pending, unstapled and unchanged" >&2
  cat "$LOG" "$CONTINUE_STATE" >&2
  exit 1
fi

reset_continue
if CMUX_TEST_NOTARY_STATUS=Invalid run_continue >/dev/null 2>"$TMP_DIR/continue-invalid.err"; then
  echo "FAIL: an Invalid saved submission must fail" >&2
  exit 1
fi
if grep -Fq 'xcrun stapler staple' "$LOG" || [ -e "$CONTINUE_IMMUTABLE" ]; then
  echo "FAIL: an Invalid saved submission must not be stapled" >&2
  exit 1
fi
if ! grep -Fxq "notary_status=Invalid" "$CONTINUE_GITHUB_OUTPUT"; then
  echo "FAIL: a continued submission must report Apple's verdict (Invalid) to the recovery step" >&2
  exit 1
fi

# Run 38677509707: Apple accepted five continued submissions, but the bundle
# notice check failed afterwards. The recovery step must be told Apple accepted
# so it does not report a local failure as Apple's.
reset_continue
if CMUX_TEST_FAIL_TOOL=licenses run_continue >/dev/null 2>"$TMP_DIR/continue-licenses.err"; then
  echo "FAIL: a failed check after acceptance must fail the continuation" >&2
  exit 1
fi
if [ -e "$CONTINUE_IMMUTABLE" ] || ! grep -Fxq "notary_status=Accepted" "$CONTINUE_GITHUB_OUTPUT"; then
  echo "FAIL: a continued submission Apple accepted must report Accepted even when a later check fails" >&2
  cat "$LOG" "$TMP_DIR/continue-licenses.err" >&2
  exit 1
fi

reset_continue
printf 'a different dmg\n' > "$CONTINUE_DMG"
if run_continue >/dev/null 2>"$TMP_DIR/continue-sha.err"; then
  echo "FAIL: a DMG that is not the submitted one must be refused" >&2
  exit 1
fi
if grep -q '^xcrun notarytool' "$LOG" || ! grep -q 'SHA-256' "$TMP_DIR/continue-sha.err"; then
  echo "FAIL: a DMG mismatch must be refused before asking Apple, naming the SHA-256" >&2
  cat "$LOG" "$TMP_DIR/continue-sha.err" >&2
  exit 1
fi

echo "PASS: single DMG submission validates app ticket and delivered artifact"

# cx-urd.68: Apple still holds the helper after its bounded wait (exit 75).
# The run goes on to the DMG, whose ticket covers the helper's slices (Codesign
# kept the helper's submitted signature), instead of failing the nightly. An
# unstapled helper the accepted DMG ticket does not cover stops the run.
QUEUED_APP="$TMP_DIR/queued/cmux NIGHTLY.app"
QUEUED_HELPER="$QUEUED_APP/Contents/Library/cmux Computer Use.app"
mkdir -p "$QUEUED_APP/Contents/MacOS" "$QUEUED_HELPER/Contents/MacOS"
printf 'signed-app-fixture\n' > "$QUEUED_APP/Contents/MacOS/cmux"
printf 'helper\n' > "$QUEUED_HELPER/Contents/MacOS/cmux-cua"
python3 -c 'import plistlib, sys; plistlib.dump({"CFBundleExecutable": "cmux-cua", "CFBundleIdentifier": "com.cmuxterm.cua"}, open(sys.argv[1], "wb"))' \
  "$QUEUED_HELPER/Contents/Info.plist"
helper_cdhash="$(printf '%s' arm64 | shasum | cut -c1-40)"
run_queued() {
  : > "$LOG"
  rm -rf "$TMP_DIR/cmux-nightly-mount" "$TMP_DIR/queued.dmg" "$TMP_DIR/queued-immutable.dmg" "$TMP_DIR/queued.dmg".notarization.*
  CMUX_TEST_HELPER_EXIT=75 CMUX_TEST_HELPER_UNSTAPLED=1 \
    run_helper "$QUEUED_APP" "$TMP_DIR/queued.dmg" "$TMP_DIR/queued-immutable.dmg"
}
if ! CMUX_TEST_DMG_TICKET="[{\"arch\":\"arm64\",\"cdhash\":\"$helper_cdhash\",\"path\":\"cmux Computer Use.app/Contents/MacOS/cmux-cua\"}]" \
  run_queued >/dev/null 2>"$TMP_DIR/queued.err"; then
  echo "FAIL: a helper still in Apple's queue must not fail the nightly" >&2
  cat "$TMP_DIR/queued.err" "$LOG" >&2
  exit 1
fi
if ! grep -Fq "xcrun notarytool submit $TMP_DIR/queued.dmg" "$LOG" || ! grep -Fq "xcrun stapler staple $TMP_DIR/queued.dmg" "$LOG" \
  || [ ! -e "$TMP_DIR/queued-immutable.dmg" ]; then
  echo "FAIL: a queued helper must still produce the notarized, stapled DMG" >&2
  cat "$LOG" >&2
  exit 1
fi
if CMUX_TEST_DMG_TICKET='[]' run_queued >/dev/null 2>"$TMP_DIR/queued-uncovered.err"; then
  echo "FAIL: an unstapled helper the DMG ticket does not cover must stop the run" >&2
  exit 1
fi
if grep -Fq "xcrun stapler staple $QUEUED_APP" "$LOG" || [ -e "$TMP_DIR/queued-immutable.dmg" ] \
  || ! grep -Fq "does not cover the unstapled Computer Use helper" "$TMP_DIR/queued-uncovered.err"; then
  echo "FAIL: an uncovered helper must stop before the app is stapled, saying why" >&2
  exit 1
fi
: > "$LOG"
if CMUX_TEST_HELPER_EXIT=1 run_helper "$QUEUED_APP" "$TMP_DIR/queued.dmg" "$TMP_DIR/queued-immutable.dmg" >/dev/null 2>&1 \
  || grep -q '^xcrun notarytool submit' "$LOG"; then
  echo "FAIL: a rejected helper must still fail before the DMG submission" >&2
  exit 1
fi
echo "PASS: a helper still in Apple's queue falls through to the DMG, whose ticket must cover it"

# The bounded notary wait only helps if the step and the job outlive it: the
# step allows the wait plus DMG creation and the post-notary verification,
# and the job allows the step plus the steps before and after it.
if ! python3 - "$ROOT_DIR/.github/workflows/nightly.yml" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
job = re.search(r"\n  build-sign-notarize-nightly:\n(.*?)(?=\n  [A-Za-z0-9_-]+:\n)", text, re.S)
assert job, "no build-sign-notarize-nightly job"
job = job.group(1)
# Timeouts may be `${{ <notary test> && 200 || 80 }}`: the first value is the
# cx-f58x notary test's, the last one every other build's. Check both pairs.
job_timeouts = [int(v) for v in re.findall(r"\b(\d+)\b", re.search(r"^    timeout-minutes: (.+)$", job, re.M).group(1))]
step = re.search(r"- name: Notarize app ticket through final DMG\n(.*?)(?=\n      - name:)", job, re.S)
assert step, "no notarize step"
step = step.group(1)
step_timeout = re.search(r"^        timeout-minutes: (.+)$", step, re.M)
assert step_timeout, "the notarize step needs its own timeout-minutes"
step_timeouts = [int(v) for v in re.findall(r"\b(\d+)\b", step_timeout.group(1))]
wait = re.search(r"^          CMUX_NOTARY_WAIT_TIMEOUT: (.+)$", step, re.M)
assert wait, "the notarize step must set CMUX_NOTARY_WAIT_TIMEOUT"
# `${{ <nightly-next> && '20m' || '40m' }}`: the last value is main's and RC's.
waits = [int(value) for value in re.findall(r"\b(\d+)m\b", wait.group(1))]
assert waits, f"no wait in {wait.group(1)!r}"
# Run 37648507383: Apple had not finished any of the 3 DMGs after 25m, so
# nothing published. A healthy submission returns in minutes; wait 40m.
# Published nightly-next waits less: it hands a slow one to its next run.
assert waits[-1] >= 40, f"the {waits[-1]}m notary wait gives up before Apple usually finishes a stalled DMG"
# A notary test (the max pair) makes one DMG submission; every other build two
# (CMUX_STAPLE_APP_IN_DMG: the DMG around the stapled app waits as long again).
assert "CMUX_STAPLE_APP_IN_DMG: ${{ needs.decide.outputs.notary_test == 'true' && 'false' || 'true' }}" in step
for submissions, wait, step_timeout, job_timeout in ((1, max(waits), max(step_timeouts), max(job_timeouts)), (2, waits[-1], step_timeouts[-1], job_timeouts[-1])):
    assert step_timeout >= submissions * wait + 10, f"step {step_timeout}m must cover {submissions} x {wait}m waits plus 10m of DMG work and verification"
    assert job_timeout >= step_timeout + 20, f"job {job_timeout}m must cover the {step_timeout}m notarize step plus 20m of other steps"
PY
then
  echo "FAIL: the notarize step and job timeouts must clearly exceed the notary wait" >&2
  exit 1
fi
echo "PASS: notarize step and job timeouts outlive the bounded notary wait"

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
# The RC fixture, like a cmux-next bundle, has no nested Computer Use app, so
# no helper notarization runs for it.
if grep -q '^notarize-helper ' "$LOG"; then
  echo "FAIL: packaging notarized a Computer Use helper the bundle does not carry" >&2
  exit 1
fi
for expected in \
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
echo "PASS: rc channel packaging selects rc metadata checks and skips an absent Computer Use helper"

# Stable packages through the same path with the release entitlements, so the
# stable release can ship per-architecture DMGs the way nightly does.
: > "$LOG"
STABLE_APP="$TMP_DIR/input/cmux.app"
mkdir -p "$STABLE_APP/Contents/MacOS" "$STABLE_APP/Contents/Library/cmux Computer Use.app/Contents"
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
  if ! grep -q '^xcrun notarytool submit .*/stapled-app/[^ /]*-stapled-app\.dmg .*--output-format json$' "$LOG" \
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
