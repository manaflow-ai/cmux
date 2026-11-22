#!/usr/bin/env bash
# reload.sh re-signs the tagged app ad hoc unless CMUX_DEV_SIGN_IDENTITY names an
# identity. Runs reload.sh's own signing block (the identity check through the
# codesign `fi`) in a harness with a fake codesign and security on PATH:
#   - unset, empty or "-" signs with `--sign -`, as before, and never asks security;
#   - a set identity that security lists signs with `--sign <identity>`;
#   - a set identity security does not list fails with a clear error and no codesign
#     call, even with CMUX_ALLOW_UNSIGNED_DEV_APP=1 (no silent ad hoc fallback);
#   - CMUX_ALLOW_UNSIGNED_DEV_APP=1 still tolerates a failed ad hoc sign, but never a
#     failed sign with a set identity.
# Linux and macOS. Run: ./tests/test_reload_dev_sign_identity.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELOAD="$ROOT_DIR/scripts/reload.sh"
LIB="$ROOT_DIR/scripts/lib/dev-sign-identity.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/app/cmux DEV probe.app"
APP="$TMP_DIR/app/cmux DEV probe.app"
CODESIGN_LOG="$TMP_DIR/codesign.log"
SECURITY_LOG="$TMP_DIR/security.log"

cat > "$TMP_DIR/bin/codesign" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CODESIGN_LOG"
[[ "${FAKE_CODESIGN_FAIL:-}" != 1 ]] || exit 1
FAKE
cat > "$TMP_DIR/bin/security" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SECURITY_LOG"
[[ "$*" == "find-identity -v -p codesigning" ]] || exit 2
printf '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: Probe Person (TEAMID1234)"\n'
printf '     1 valid identities found\n'
FAKE
chmod +x "$TMP_DIR/bin/codesign" "$TMP_DIR/bin/security"

# reload.sh's signing block: from the identity check (or, before it existed, the
# codesign line) through the codesign `if`'s closing `fi`, calling codesign by PATH.
BLOCK="$(awk '
  /^cmux_dev_sign_identity_ready / || /^if ! \/usr\/bin\/codesign --force / { on = 1 }
  on { print }
  on && /^fi$/ { exit }
' "$RELOAD")"
[[ "$BLOCK" == *'codesign --force'* ]] || fail "reload.sh lost its codesign re-sign of the tagged app"
BLOCK="${BLOCK//\/usr\/bin\/codesign/codesign}"
[[ "$BLOCK" != *'--deep'* ]] || fail "the re-sign uses --deep, which would re-sign nested helpers"

OUTPUT=""
STATUS=0
run_block() {
  rm -f "$CODESIGN_LOG" "$SECURITY_LOG"
  set +e
  OUTPUT="$(env -u CMUX_DEV_SIGN_IDENTITY -u CMUX_ALLOW_UNSIGNED_DEV_APP -u FAKE_CODESIGN_FAIL \
    PATH="$TMP_DIR/bin:$PATH" CODESIGN_LOG="$CODESIGN_LOG" SECURITY_LOG="$SECURITY_LOG" \
    APP_PATH="$APP" LIB="$LIB" "$@" bash -c '
      set -euo pipefail
      [[ ! -f "$LIB" ]] || source "$LIB"
      '"$BLOCK"'
      echo SIGNED' 2>&1)"
  STATUS=$?
  set -e
}
sign_arg() { awk 'found { print; exit } $0 == "--sign" { found = 1 }' "$CODESIGN_LOG"; }

expect_ad_hoc() {
  [[ "$STATUS" -eq 0 ]] || fail "$1: the block failed: $OUTPUT"
  [[ -f "$CODESIGN_LOG" ]] || fail "$1: codesign never ran: $OUTPUT"
  [[ "$(sign_arg)" == "-" ]] || fail "$1: signed with '$(sign_arg)', not ad hoc"
  [[ "$(tr '\n' ' ' < "$CODESIGN_LOG")" == "--force --sign - --timestamp=none --generate-entitlement-der $APP " ]] \
    || fail "$1: the codesign arguments changed: $(tr '\n' ' ' < "$CODESIGN_LOG")"
  [[ ! -f "$SECURITY_LOG" ]] || fail "$1: asked security for identities when signing ad hoc"
}

run_block
expect_ad_hoc "unset"
run_block CMUX_DEV_SIGN_IDENTITY=
expect_ad_hoc "empty"
run_block CMUX_DEV_SIGN_IDENTITY=-
expect_ad_hoc "'-'"
echo "PASS: unset, empty or '-' CMUX_DEV_SIGN_IDENTITY signs ad hoc with the same arguments as before"

ID="Apple Development: Probe Person (TEAMID1234)"
run_block CMUX_DEV_SIGN_IDENTITY="$ID"
[[ "$STATUS" -eq 0 ]] || fail "a present identity failed: $OUTPUT"
[[ "$(sign_arg)" == "$ID" ]] || fail "a present identity signed with '$(sign_arg 2>/dev/null)', not '$ID'"
[[ "$(tr '\n' ' ' < "$CODESIGN_LOG")" == "--force --sign $ID --timestamp=none --generate-entitlement-der $APP " ]] \
  || fail "a present identity changed the other codesign arguments: $(tr '\n' ' ' < "$CODESIGN_LOG")"
run_block CMUX_DEV_SIGN_IDENTITY=0123456789ABCDEF0123456789ABCDEF01234567
[[ "$STATUS" -eq 0 && "$(sign_arg)" == 0123456789ABCDEF0123456789ABCDEF01234567 ]] \
  || fail "an identity named by its SHA-1 was not used: $OUTPUT"
echo "PASS: a set identity that security lists signs with --sign <identity>"

for missing in "Apple Development: Someone Else (TEAMID9999)" "valid identities found"; do
  for allow in "" 1; do
    run_block CMUX_DEV_SIGN_IDENTITY="$missing" CMUX_ALLOW_UNSIGNED_DEV_APP="$allow"
    [[ "$STATUS" -ne 0 ]] || fail "a missing identity '$missing' (allow-unsigned='$allow') did not fail: $OUTPUT"
    [[ ! -f "$CODESIGN_LOG" ]] || fail "a missing identity '$missing' still ran codesign: $(tr '\n' ' ' < "$CODESIGN_LOG")"
    [[ "$OUTPUT" == *"CMUX_DEV_SIGN_IDENTITY is set to '$missing'"* && "$OUTPUT" == *"no valid code signing identity matches it"* ]] \
      || fail "a missing identity '$missing' failed without a clear error: $OUTPUT"
    [[ "$OUTPUT" != *SIGNED* ]] || fail "a missing identity '$missing' went on past the signing block"
  done
done
echo "PASS: a set identity security does not list fails clearly and never runs codesign"

run_block FAKE_CODESIGN_FAIL=1 CMUX_ALLOW_UNSIGNED_DEV_APP=1
[[ "$STATUS" -eq 0 && "$OUTPUT" == *"continuing because CMUX_ALLOW_UNSIGNED_DEV_APP=1"* ]] \
  || fail "CMUX_ALLOW_UNSIGNED_DEV_APP=1 no longer tolerates a failed ad hoc sign: $OUTPUT"
run_block FAKE_CODESIGN_FAIL=1 CMUX_ALLOW_UNSIGNED_DEV_APP=1 CMUX_DEV_SIGN_IDENTITY="$ID"
[[ "$STATUS" -ne 0 && "$OUTPUT" != *SIGNED* ]] \
  || fail "a failed sign with a set identity continued unsigned under CMUX_ALLOW_UNSIGNED_DEV_APP=1: $OUTPUT"
[[ "$OUTPUT" == *"codesign failed for $APP with CMUX_DEV_SIGN_IDENTITY '$ID'"* ]] \
  || fail "a failed sign with a set identity did not say so: $OUTPUT"
echo "PASS: CMUX_ALLOW_UNSIGNED_DEV_APP=1 tolerates only a failed ad hoc sign, never a failed identity sign"
