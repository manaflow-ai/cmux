#!/usr/bin/env bash
# Real import test for scripts/ci/signing-keychain.sh on macOS: no fake
# `security`, no real secret. A throwaway self-signed code-signing identity is
# made with openssl and exported as a .p12 under a random password, exactly the
# shape of APPLE_CERTIFICATE_BASE64 / APPLE_CERTIFICATE_PASSWORD. The test runs
# the real create, signs a binary with the imported identity (which proves the
# import and the key partition list), then runs delete and checks that the
# keychain, its state and the decoded certificate are gone.
#
# Runs in .github/workflows/signing-keychain-macos.yml on a fresh macOS runner.
set -euo pipefail

if [ "$(uname -s)" != Darwin ]; then
  echo "SKIP: the real keychain import test needs macOS"
  exit 0
fi
# The tool replaces the user keychain search list while the test runs. Run it
# only on a CI runner (or with an explicit opt-in), never by accident on a
# developer Mac whose login keychain a killed run would leave out of the list.
if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${CMUX_SIGNING_KEYCHAIN_REAL_TEST:-}" != 1 ]; then
  echo "SKIP: set CMUX_SIGNING_KEYCHAIN_REAL_TEST=1 to run the real keychain test outside CI"
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT_DIR/scripts/ci/signing-keychain.sh"
TMP_DIR="$(mktemp -d)"
NAME="cmux-real-import-test-$$.keychain"
KEYCHAIN_FILE="$HOME/Library/Keychains/$NAME-db"
SUBJECT="cmux CI throwaway signing test $$"

# The tool replaces the user keychain search list; put it back afterwards.
SAVED_LIST=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%\"}"; line="${line#\"}"
  if [ -n "$line" ]; then SAVED_LIST+=("$line"); fi
done < <(security list-keychains -d user)

cleanup() {
  security delete-keychain "$NAME" >/dev/null 2>&1 || true
  if [ "${#SAVED_LIST[@]}" -gt 0 ]; then
    security list-keychains -d user -s "${SAVED_LIST[@]}" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Throwaway identity. /usr/bin/openssl (LibreSSL) writes a PKCS#12 that
# `security import` reads; the explicit PBE and MAC also suit OpenSSL 3.
OPENSSL=/usr/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl)"
cat > "$TMP_DIR/req.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SUBJECT
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 1 \
  -config "$TMP_DIR/req.cnf" -keyout "$TMP_DIR/key.pem" -out "$TMP_DIR/cert.pem" >/dev/null \
  || fail "openssl could not make the throwaway identity"
PASSWORD="$("$OPENSSL" rand -hex 16)"
# The CI certificate secret carries Apple's Developer ID G2 intermediate next
# to the identity; put it in the throwaway .p12 too, so the import and the
# intermediates step see the same duplicate as in CI.
"$OPENSSL" x509 -inform DER -in "$ROOT_DIR/scripts/apple-developer-id-certs/DeveloperIDG2CA.cer" -out "$TMP_DIR/g2.pem" \
  || fail "openssl could not read the vendored DeveloperIDG2CA.cer"
p12_args=(-export -inkey "$TMP_DIR/key.pem" -in "$TMP_DIR/cert.pem" -certfile "$TMP_DIR/g2.pem" -out "$TMP_DIR/identity.p12"
  -passout "pass:$PASSWORD" -name "$SUBJECT" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1)
if ! "$OPENSSL" pkcs12 "${p12_args[@]}" >/dev/null 2>&1; then
  "$OPENSSL" pkcs12 -legacy "${p12_args[@]}" >/dev/null
fi
rm -f "$TMP_DIR/key.pem"

# 2. The real create, with the secret shapes the workflows pass.
export CMUX_SIGNING_KEYCHAIN_STATE_DIR="$TMP_DIR/state"
APPLE_CERTIFICATE_BASE64="$(base64 < "$TMP_DIR/identity.p12" | tr -d '\n')" \
APPLE_CERTIFICATE_PASSWORD="$PASSWORD" \
  "$TOOL" create --keychain "$NAME" > "$TMP_DIR/create.log" 2>&1 \
  || { cat "$TMP_DIR/create.log" >&2; fail "signing-keychain.sh create failed"; }
cat "$TMP_DIR/create.log"
# The .p12 brought the G2 intermediate, so the intermediates step must have
# met it already in the keychain (the path that broke signing on 2026-10-16).
grep -F "DeveloperIDG2CA is already in $NAME" "$TMP_DIR/create.log" >/dev/null \
  || fail "the intermediates step did not meet the G2 intermediate from the .p12"

[ -e "$KEYCHAIN_FILE" ] || fail "create made no keychain at $KEYCHAIN_FILE"
"$TOOL" is-present || fail "is-present must report the new keychain"
if compgen -G "$CMUX_SIGNING_KEYCHAIN_STATE_DIR/certificate.*" >/dev/null; then
  fail "create left the decoded certificate on disk"
fi

# 3. The identity is in the keychain and signs without a prompt (partition list).
identity="$(security find-identity -p codesigning "$NAME" | awk -v s="$SUBJECT" 'index($0, s) {print $2; exit}')"
[ -n "$identity" ] || { security find-identity -p codesigning "$NAME" >&2; fail "the imported identity is not in $NAME"; }
cp /usr/bin/true "$TMP_DIR/signed-binary"
"$TOOL" unlock
codesign --force --sign "$identity" --keychain "$KEYCHAIN_FILE" "$TMP_DIR/signed-binary" \
  || fail "codesign with the imported identity failed"
codesign -dvv "$TMP_DIR/signed-binary" 2>&1 | grep -F "Authority=$SUBJECT" >/dev/null \
  || fail "the binary is not signed by the imported identity"

# 4. delete removes the keychain and its state.
"$TOOL" delete || fail "signing-keychain.sh delete failed"
[ ! -e "$KEYCHAIN_FILE" ] || fail "the keychain still exists after delete"
if "$TOOL" is-present; then fail "is-present still reports a keychain after delete"; fi
"$TOOL" assert-deleted || fail "assert-deleted fails after delete"
if compgen -G "$CMUX_SIGNING_KEYCHAIN_STATE_DIR/*" >/dev/null; then
  fail "delete left state in $CMUX_SIGNING_KEYCHAIN_STATE_DIR"
fi

# The same secret-bearing macOS lane also exercises the Sparkle key helper's
# stdin-only contract. It uses a fixed non-secret seed and touches no keychain.
"$ROOT_DIR/tests/test_derive_sparkle_public_key.sh" || fail "Sparkle public key derivation failed"

echo "PASS: real signing keychain import, codesign and delete with a throwaway identity"
