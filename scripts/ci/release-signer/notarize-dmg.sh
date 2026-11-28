#!/usr/bin/env bash
# Developer ID sign, notarize and staple a cmux NEXT DMG with the release signer.
#
#   scripts/ci/release-signer/notarize-dmg.sh <dmg-path>
#
# A Mac builds the unsigned DMG; this signs it with the binary build.sh makes,
# has Apple's notary service accept it, and staples the ticket. It refuses to
# go on if the signature is not the expected Developer ID signature. Not used
# by any workflow yet.
#
# Env: APPLE_CERTIFICATE_BASE64 and APPLE_CERTIFICATE_PASSWORD (the PKCS#12),
# APPLE_SIGNING_IDENTITY (the certificate must match it, as codesign matches
# an identity), ASC_API_KEY_ID, ASC_API_ISSUER_ID and ASC_API_KEY_P8_BASE64
# (the notary API key), CMUX_SIGNER (the signer binary, from install.sh),
# NOTARY_MAX_WAIT_SECONDS (default 1800). Keys exist only in a mktemp -d
# directory (umask 077) that the EXIT trap removes, and are never on a command
# line: openssl reads the PKCS#12 on stdin and the password from the
# environment, and the signer reads the PEM and the API key JSON by path.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <dmg-path>" >&2; exit 2; }
DMG="$1"
R="${CMUX_SIGNER:?CMUX_SIGNER names the signer binary}"
[[ -f "$DMG" ]] || { echo "error: DMG not found at $DMG" >&2; exit 1; }
command -v "$R" >/dev/null || { echo "error: signer binary not found ($R)" >&2; exit 1; }
: "${APPLE_CERTIFICATE_BASE64:?}" "${APPLE_CERTIFICATE_PASSWORD:?}" "${APPLE_SIGNING_IDENTITY:?}"
: "${ASC_API_KEY_ID:?}" "${ASC_API_ISSUER_ID:?}" "${ASC_API_KEY_P8_BASE64:?}"
export APPLE_CERTIFICATE_PASSWORD

# Every signer call goes through run_signer, which keeps RCODESIGN_* variables
# (the signer's own configuration) out of its environment.
# shellcheck source=signer-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/signer-env.sh"

secrets=""
trap 'rm -rf ${secrets:+"$secrets"}' EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
secrets="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/cmux-dmg-signer.XXXXXX")"

# The signer cannot read the PBES2 PKCS#12 a keychain exports, so openssl
# turns it into one PEM.
(umask 077 && printf '%s' "$APPLE_CERTIFICATE_BASE64" | base64 -d > "$secrets/identity.p12") 2>/dev/null ||
  { echo "error: APPLE_CERTIFICATE_BASE64 is not valid base64" >&2; exit 1; }
pkcs12_to_pem() {
  (umask 077 && openssl pkcs12 "$@" -passin env:APPLE_CERTIFICATE_PASSWORD -nodes -clcerts \
    < "$secrets/identity.p12" > "$secrets/identity.pem" 2>/dev/null)
}
pkcs12_to_pem || pkcs12_to_pem -legacy || { echo "error: openssl could not open the PKCS#12 (wrong password?)" >&2; exit 1; }
rm -f "$secrets/identity.p12"
unset APPLE_CERTIFICATE_PASSWORD APPLE_CERTIFICATE_BASE64
# The notary key goes to a file before any signer call, so no signer process
# inherits it in its environment.
(umask 077 && printf '%s' "$ASC_API_KEY_P8_BASE64" | base64 -d > "$secrets/AuthKey_${ASC_API_KEY_ID}.p8") 2>/dev/null ||
  { echo "error: ASC_API_KEY_P8_BASE64 is not valid base64" >&2; exit 1; }
[[ -s "$secrets/AuthKey_${ASC_API_KEY_ID}.p8" ]] || { echo "error: ASC_API_KEY_P8_BASE64 decoded to nothing" >&2; exit 1; }
unset ASC_API_KEY_P8_BASE64
[[ "$(grep -c -- '-----BEGIN .*PRIVATE KEY-----' < "$secrets/identity.pem" || true)" == 1 ]] ||
  { echo "error: the PKCS#12 must hold exactly one private key" >&2; exit 1; }
subject="$(openssl x509 -noout -subject -nameopt multiline,utf8,-esc_msb < "$secrets/identity.pem")"
cn="$(awk '/^ *commonName *=/ { sub(/^ *commonName *= */, ""); print; exit }' <<<"$subject")"
team="$(awk '/^ *organizationalUnitName *=/ { sub(/^ *organizationalUnitName *= */, ""); print; exit }' <<<"$subject")"
[[ "$team" == 7WLXT3NR37 ]] || { echo "error: the certificate ($cn) is for team '$team', not 7WLXT3NR37" >&2; exit 1; }
[[ "$cn" == "Developer ID Application:"* ]] ||
  { echo "error: the certificate ($cn) is not a Developer ID Application certificate" >&2; exit 1; }
want="$APPLE_SIGNING_IDENTITY"
if [[ "$want" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  fp="$(openssl x509 -noout -fingerprint -sha1 < "$secrets/identity.pem")"; fp="${fp#*=}"
  [[ "${fp//:/}" == "${want^^}" || "${fp//:/}" == "${want,,}" ]] ||
    { echo "error: the certificate ($cn) is not the SHA-1 APPLE_SIGNING_IDENTITY names" >&2; exit 1; }
elif [[ "$cn" != *"$want"* ]]; then
  echo "error: the certificate ($cn) does not match APPLE_SIGNING_IDENTITY" >&2; exit 1
fi

echo "==> signing ${DMG##*/} as $cn"
run_signer "$R" sign --config-file /dev/null --pem-file "$secrets/identity.pem" \
  --timestamp-url http://timestamp.apple.com/ts01 "$DMG"
rm -f "$secrets/identity.pem"

# The expected Developer ID signature.
ident="$(basename "$DMG" .dmg)"
info="$(run_signer "$R" print-signature-info "$DMG")"
want_dr="designated(3): 0: (identifier \"$ident\") and ((anchor apple generic) and ((certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */) and ((certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */) and (certificate leaf[subject.OU] = \"$team\"))));"
for want in "version: '0x20200'" "flags: CodeSignatureFlags(0x0)" "identifier: $ident" "team_name: $team" "$want_dr"; do
  grep -qF -- "$want" <<<"$info" || { echo "error: the DMG signature lacks: $want" >&2; echo "$info" >&2; exit 1; }
done

(umask 077 && run_signer "$R" encode-app-store-connect-api-key --config-file /dev/null -o "$secrets/api-key.json" \
  "$ASC_API_ISSUER_ID" "$ASC_API_KEY_ID" "$secrets/AuthKey_${ASC_API_KEY_ID}.p8" >/dev/null)
rm -f "$secrets/AuthKey_${ASC_API_KEY_ID}.p8"

# --staple waits for Apple's answer, fails unless it is Accepted (printing the
# notary log), then staples the ticket to the DMG.
echo "==> notarizing and stapling ${DMG##*/}"
run_signer "$R" notary-submit --config-file /dev/null --api-key-file "$secrets/api-key.json" \
  --max-wait-seconds "${NOTARY_MAX_WAIT_SECONDS:-1800}" --staple "$DMG"
echo "==> ${DMG##*/} is signed, notarized and stapled"
