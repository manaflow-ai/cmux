#!/usr/bin/env bash
# Proves the native signing seam can import a non-secret PKCS#12 through an
# inherited descriptor. Unlike the regular import test this never writes a
# P12, PEM or P8 to disk: OpenSSL text stays in shell pipes, PKCS#12 is
# base64 on stdout, and security import reads /dev/fd/3.
set -euo pipefail

if [ "$(uname -s)" != Darwin ]; then
  [ "${CMUX_NATIVE_CREDENTIAL_REQUIRED:-0}" = 1 ] && { echo "FAIL: required native credential proof needs macOS" >&2; exit 1; }
  echo "SKIP: fd credential import needs macOS security/codesign"
  exit 0
fi
if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${CMUX_SIGNING_KEYCHAIN_FD_TEST:-}" != 1 ] && [ "${CMUX_NATIVE_CREDENTIAL_REQUIRED:-0}" != 1 ]; then
  echo "SKIP: set CMUX_SIGNING_KEYCHAIN_FD_TEST=1 to run outside GitHub Actions"
  exit 0
fi

OPENSSL="${OPENSSL:-/usr/bin/openssl}"
[ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl)"
SECURITY="${CMUX_SECURITY_TOOL:-security}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KEYCHAIN_TOOL="${CMUX_SIGNING_KEYCHAIN_TOOL:-$ROOT_DIR/scripts/ci/signing-keychain.sh}"
TMP_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cmux-fd-import.XXXXXX")"
NAME="cmux-fd-import-$$.keychain"
KEYCHAIN_FILE="$HOME/Library/Keychains/$NAME-db"
PASSWORD="cmux-fd-test-$RANDOM"
SUBJECT="cmux fd credential test $$"
SAVED_LIST=()
DEFAULT_BEFORE="$("$SECURITY" default-keychain -d user 2>/dev/null || true)"

while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%\"}"; line="${line#\"}"
  [ -n "$line" ] && SAVED_LIST+=("$line")
done < <("$SECURITY" list-keychains -d user)

cleanup() {
  "$SECURITY" delete-keychain "$NAME" >/dev/null 2>&1 || true
  if [ "${#SAVED_LIST[@]}" -gt 0 ]; then
    "$SECURITY" list-keychains -d user -s "${SAVED_LIST[@]}" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Keep private-key text in pipes and shell variables only. OpenSSL output is
# ASCII, so command substitution does not discard binary NUL bytes.
KEY_PEM="$($OPENSSL genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null)"
CERT_PEM="$(printf '%s\n' "$KEY_PEM" | "$OPENSSL" req -new -x509 -days 1 -key /dev/stdin \
  -subj "/CN=$SUBJECT/OU=CMUX-FD-TEST" 2>/dev/null)"
P12_B64="$(printf '%s\n' "$KEY_PEM" | "$OPENSSL" pkcs12 -export -inkey /dev/stdin \
  -in <(printf '%s\n' "$CERT_PEM") -passout "pass:$PASSWORD" -name "$SUBJECT" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null | base64)"
[ -n "$P12_B64" ] || fail "OpenSSL produced no PKCS#12 fixture"
unset KEY_PEM CERT_PEM

mkdir -p "$TMP_DIR/runner-temp"
export RUNNER_TEMP="$TMP_DIR/runner-temp"
export CMUX_SIGNING_KEYCHAIN_STATE_DIR="$TMP_DIR/state"
# The production helper receives the fixture through the normal secret-shaped
# environment. Its native branch imports it through /dev/fd/3 with -f pkcs12;
# this test never gives the helper a P12 pathname.
APPLE_CERTIFICATE_BASE64="$P12_B64" APPLE_CERTIFICATE_PASSWORD="$PASSWORD" \
  "$KEYCHAIN_TOOL" create --keychain "$NAME" > "$TMP_DIR/create.log" 2>&1 \
  || { cat "$TMP_DIR/create.log" >&2; fail "production signing-keychain create failed"; }
unset P12_B64 PASSWORD

IDENTITY="$("$SECURITY" find-identity -p codesigning "$NAME" | awk -v s="$SUBJECT" 'index($0, s) { print $2; exit }')"
[ -n "$IDENTITY" ] || { "$SECURITY" find-identity -p codesigning "$NAME" >&2; fail "fd import made no signing identity"; }
cp /usr/bin/true "$TMP_DIR/signed-binary"
"$SECURITY" list-keychains -d user -s "$NAME"
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN_FILE" "$TMP_DIR/signed-binary" \
  || fail "codesign could not use the fd-imported identity"
codesign -dvv "$TMP_DIR/signed-binary" 2>&1 | grep -F "Authority=$SUBJECT" >/dev/null \
  || fail "signed binary does not contain fd-imported identity"

if ! command -v xcrun >/dev/null 2>&1 && [ "${CMUX_NATIVE_CREDENTIAL_REQUIRED:-0}" = 1 ]; then
  fail "required native credential proof needs xcrun/notarytool"
fi
if command -v xcrun >/dev/null 2>&1; then
  PROFILE="cmux-fd-profile-$$"
  ISSUER="00000000-0000-0000-0000-000000000000"
  KEY_ID="CMUXFDTEST"
  NOTARY_P8="$("$OPENSSL" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 2>/dev/null)"
  [ -n "$NOTARY_P8" ] || fail "OpenSSL produced no API-key fixture"
  xcrun notarytool store-credentials "$PROFILE" \
    --key /dev/fd/3 --key-id "$KEY_ID" --issuer "$ISSUER" \
    --keychain "$KEYCHAIN_FILE" --no-validate \
    3< <(printf '%s' "$NOTARY_P8") \
    || fail "notarytool could not store an API key from fd 3"
  unset NOTARY_P8
  security dump-keychain -d "$KEYCHAIN_FILE" 2>/dev/null | grep -F "$PROFILE" >/dev/null \
    || fail "notarytool profile was not stored in the temporary keychain"
fi

"$KEYCHAIN_TOOL" delete --keychain "$NAME" >/dev/null || fail "production keychain delete failed"
[ ! -e "$KEYCHAIN_FILE" ] || fail "fd-test keychain survived cleanup"
[ "$("$SECURITY" default-keychain -d user 2>/dev/null || true)" = "$DEFAULT_BEFORE" ] \
  || fail "production keychain helper changed the user's default keychain"
if find "$TMP_DIR" -type f \( -name '*.p12' -o -name '*.pem' -o -name '*.p8' \) -print -quit | grep -q .; then
  fail "raw credential file remained in test temp dir"
fi
[ -z "$(find "$TMP_DIR/runner-temp" -mindepth 1 -print -quit 2>/dev/null)" ] || fail "runner temp retained credential state"
echo "PASS: owned-Mac security import from fd 3, codesign, and cleanup"
