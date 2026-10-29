#!/usr/bin/env bash
# DO NOT MERGE. Runs signing-keychain.sh create with a throwaway identity (no real key), then codesigns, the way
# sign-nightly-identity-legacy does, and checks a real Developer ID chain while the job's search list is in place.
set -uo pipefail
work="$RUNNER_TEMP/probe"; mkdir -p "$work"; cd "$work" || exit 1
leaf=""; for a in /Applications/*.app /Applications/*/*.app; do
  [ -e "$a" ] || continue
  if codesign -dvv "$a" 2>&1 | grep -q "Authority=Developer ID Application"; then
    codesign -d --extract-certificates=devid "$a" >/dev/null 2>&1 && leaf="$work/devid0" && echo "Developer ID app: $a" && break
  fi
done
verify() { [ -n "$leaf" ] || { echo "no Developer ID app here"; return; }
  echo "verify-cert ($1): $(security verify-cert -c "$leaf" -p codeSign -L 2>&1 | tail -1)"; }
verify "before create"
openssl req -x509 -newkey rsa:2048 -nodes -keyout k.pem -out c.pem -days 2 -subj "/CN=zz probe signer $$" \
  -addext basicConstraints=critical,CA:FALSE -addext keyUsage=critical,digitalSignature \
  -addext extendedKeyUsage=critical,codeSigning 2>/dev/null
openssl pkcs12 -export -legacy -inkey k.pem -in c.pem -out c.p12 -passout pass:probe 2>/dev/null \
  || openssl pkcs12 -export -inkey k.pem -in c.pem -out c.p12 -passout pass:probe
rm -f k.pem
export APPLE_CERTIFICATE_BASE64="$(base64 < c.p12 | tr -d '\n')" APPLE_CERTIFICATE_PASSWORD=probe
rm -f c.p12
cd "$GITHUB_WORKSPACE" || exit 1
./scripts/ci/signing-keychain.sh create; echo "create rc=$?"
echo "search list during the job: $(security list-keychains -d user | tr -d ' \n')"
verify "with only build.keychain listed"
cp /bin/echo "$work/bin"
/usr/bin/codesign --force --options runtime --timestamp --sign "zz probe signer $$" "$work/bin"; echo "codesign identity-name rc=$?"
cp /bin/echo "$work/bin2"
/usr/bin/codesign --force --timestamp --keychain build.keychain --sign "zz probe signer $$" "$work/bin2"; echo "codesign --keychain rc=$?"
./scripts/ci/signing-keychain.sh delete --keychain build.keychain; echo "delete rc=$?"
echo "search list after: $(security list-keychains -d user | tr -d ' \n')"
verify "after delete"
