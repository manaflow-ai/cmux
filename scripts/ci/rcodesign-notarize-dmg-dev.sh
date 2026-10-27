#!/usr/bin/env bash
# Developer ID sign, notarize and staple the cmux NEXT DEV tip DMG on Linux.
#
#   scripts/ci/rcodesign-notarize-dmg-dev.sh <dmg-path>
#
# The Linux half of the tip DMG (cmux-next-dev-daily.yml, job tip-dmg): a Mac
# builds the unsigned DMG (hdiutil has no Linux equivalent for ULMO), and this
# signs it with rcodesign 0.29.0 plus scripts/ci/rcodesign-0.29.0-dmg.patch
# (scripts/ci/build-rcodesign-dmg.sh), makes Apple's notary service accept it,
# and staples the ticket. It replaces codesign --force --timestamp, notarytool
# submit/wait and stapler staple.
#
# The signature is codesign's (Leo, 2026-10-24: "the linux built ones the ones
# we send to apple we wanna make sure it's byte perfect"): the patched signer
# writes the 0x20200 Code Directory with the certificate's team and the
# Developer ID designated requirement, with no flags (codesign sets none on a
# DMG; --for-notarization would add the hardened runtime flag, so the time
# stamp is asked for directly). The step after signing refuses a signature
# whose team, requirement, version or flags differ from that.
#
# Env: APPLE_CERTIFICATE_BASE64 and APPLE_CERTIFICATE_PASSWORD (the PKCS#12),
# APPLE_SIGNING_IDENTITY (the certificate must match it, as in
# rcodesign-sign-bundle-dev.sh), ASC_API_KEY_ID, ASC_API_ISSUER_ID and
# ASC_API_KEY_P8_BASE64 (the notary API key), RCODESIGN (default rcodesign),
# NOTARY_MAX_WAIT_SECONDS (default 1800). Keys exist only in a mktemp -d
# directory (umask 077) that the EXIT trap removes, and are never on a command
# line: openssl reads the PKCS#12 on stdin and the password from the
# environment, and rcodesign reads the PEM and the API key JSON by path.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <dmg-path>" >&2; exit 2; }
DMG="$1"
R="${RCODESIGN:-rcodesign}"
[[ -f "$DMG" ]] || { echo "error: DMG not found at $DMG" >&2; exit 1; }
command -v "$R" >/dev/null || { echo "error: rcodesign not found ($R)" >&2; exit 1; }
: "${APPLE_CERTIFICATE_BASE64:?}" "${APPLE_CERTIFICATE_PASSWORD:?}" "${APPLE_SIGNING_IDENTITY:?}"
: "${ASC_API_KEY_ID:?}" "${ASC_API_ISSUER_ID:?}" "${ASC_API_KEY_P8_BASE64:?}"
export APPLE_CERTIFICATE_PASSWORD

secrets=""
trap 'rm -rf ${secrets:+"$secrets"}' EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
secrets="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/cmux-rcodesign-dmg.XXXXXX")"

# As rcodesign-sign-bundle-dev.sh: rcodesign 0.29 cannot read the PBES2
# PKCS#12 a keychain exports, so openssl turns it into one PEM.
(umask 077 && printf '%s' "$APPLE_CERTIFICATE_BASE64" | base64 -d > "$secrets/identity.p12") 2>/dev/null ||
  { echo "error: APPLE_CERTIFICATE_BASE64 is not valid base64" >&2; exit 1; }
pkcs12_to_pem() {
  (umask 077 && openssl pkcs12 "$@" -passin env:APPLE_CERTIFICATE_PASSWORD -nodes -clcerts \
    < "$secrets/identity.p12" > "$secrets/identity.pem" 2>/dev/null)
}
pkcs12_to_pem || pkcs12_to_pem -legacy || { echo "error: openssl could not open the PKCS#12 (wrong password?)" >&2; exit 1; }
rm -f "$secrets/identity.p12"
unset APPLE_CERTIFICATE_PASSWORD APPLE_CERTIFICATE_BASE64
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
"$R" sign --config-file /dev/null --pem-file "$secrets/identity.pem" \
  --timestamp-url http://timestamp.apple.com/ts01 "$DMG"
rm -f "$secrets/identity.pem"

# What codesign writes for a Developer ID DMG (scripts/ci/build-rcodesign-dmg.sh).
ident="$(basename "$DMG" .dmg)"
info="$("$R" print-signature-info "$DMG")"
want_dr="designated(3): 0: (identifier \"$ident\") and ((anchor apple generic) and ((certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */) and ((certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */) and (certificate leaf[subject.OU] = \"$team\"))));"
for want in "version: '0x20200'" "flags: CodeSignatureFlags(0x0)" "identifier: $ident" "team_name: $team" "$want_dr"; do
  grep -qF -- "$want" <<<"$info" || { echo "error: the DMG signature lacks: $want" >&2; echo "$info" >&2; exit 1; }
done

(umask 077 && printf '%s' "$ASC_API_KEY_P8_BASE64" | base64 -d > "$secrets/AuthKey_${ASC_API_KEY_ID}.p8") 2>/dev/null ||
  { echo "error: ASC_API_KEY_P8_BASE64 is not valid base64" >&2; exit 1; }
[[ -s "$secrets/AuthKey_${ASC_API_KEY_ID}.p8" ]] || { echo "error: ASC_API_KEY_P8_BASE64 decoded to nothing" >&2; exit 1; }
(umask 077 && "$R" encode-app-store-connect-api-key --config-file /dev/null -o "$secrets/api-key.json" \
  "$ASC_API_ISSUER_ID" "$ASC_API_KEY_ID" "$secrets/AuthKey_${ASC_API_KEY_ID}.p8" >/dev/null)
rm -f "$secrets/AuthKey_${ASC_API_KEY_ID}.p8"

# --staple waits for Apple's answer, fails unless it is Accepted (printing the
# notary log), then staples the ticket to the DMG.
echo "==> notarizing and stapling ${DMG##*/}"
"$R" notary-submit --config-file /dev/null --api-key-file "$secrets/api-key.json" \
  --max-wait-seconds "${NOTARY_MAX_WAIT_SECONDS:-1800}" --staple "$DMG"
echo "==> ${DMG##*/} is signed, notarized and stapled"
