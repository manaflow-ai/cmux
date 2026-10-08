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
LOG="$TMP_DIR/calls.log"
HELPER_STATE="$TMP_DIR/helper-notarization.state"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/cmux Computer Use.app/Contents" "$FAKE_BIN"
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
    # notarytool --wait --timeout: the submission is still In Progress when the wait ends.
    printf '{"id":"fixture-id","status":"In Progress","message":"Timeout of 25m reached"}\n'
    exit 1
  fi
  printf '{"id":"fixture-id","status":"%s"}\n' "${CMUX_TEST_NOTARY_STATUS:-Accepted}"
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
  CMUX_NOTARIZE_COMPUTER_USE_HELPER_TOOL="$FAKE_BIN/notarize-computer-use-helper" \
  CMUX_COMPUTER_USE_NOTARY_SUBMISSION_FILE="$HELPER_STATE" \
  CMUX_APP_ENTITLEMENTS="$TMP_DIR/cmux.nightly.entitlements" \
  ASC_API_KEY_ID="${TEST_ASC_API_KEY_ID-FIXTUREKEY}" \
  ASC_API_ISSUER_ID="${TEST_ASC_API_ISSUER_ID-fixture-issuer}" \
  ASC_API_KEY_P8_BASE64="${TEST_ASC_API_KEY_P8_BASE64-$FIXTURE_P8_BASE64}" \
  APPLE_SIGNING_IDENTITY='Developer ID Application: Fixture' \
  "$SCRIPT" "$APP" "$DMG" "$IMMUTABLE"
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

echo "PASS: single DMG submission validates app ticket and delivered artifact"

# The bounded notary wait only helps if the step and the job outlive it: the
# step allows the wait plus DMG creation and the post-notary verification,
# and the job allows the step plus the steps before and after it.
if ! python3 - "$ROOT_DIR/.github/workflows/nightly.yml" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
job = re.search(r"\n  build-sign-notarize-nightly:\n(.*?)(?=\n  [A-Za-z0-9_-]+:\n)", text, re.S)
assert job, "no build-sign-notarize-nightly job"
job = job.group(1)
job_timeout = int(re.search(r"^    timeout-minutes: (\d+)$", job, re.M).group(1))
step = re.search(r"- name: Notarize app ticket through final DMG\n(.*?)(?=\n      - name:)", job, re.S)
assert step, "no notarize step"
step = step.group(1)
step_timeout = re.search(r"^        timeout-minutes: (\d+)$", step, re.M)
assert step_timeout, "the notarize step needs its own timeout-minutes"
step_timeout = int(step_timeout.group(1))
wait = re.search(r"^          CMUX_NOTARY_WAIT_TIMEOUT: (\d+)m$", step, re.M)
assert wait, "the notarize step must set CMUX_NOTARY_WAIT_TIMEOUT"
wait = int(wait.group(1))
# Run 37648507383: Apple had not finished any of the 3 DMGs after 25m, so
# nothing published. A healthy submission returns in minutes; wait 40m.
assert wait >= 40, f"the {wait}m notary wait gives up before Apple usually finishes a stalled DMG"
assert step_timeout >= wait + 10, f"step {step_timeout}m must cover the {wait}m wait plus 10m of DMG work and verification"
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
