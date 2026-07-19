#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <hook-helper-binary>" >&2
  exit 2
fi

BINARY="$1"
# Test-only injection lets the signature-policy regression emulate codesign
# failures without changing the production /usr/bin/codesign path.
CODESIGN_TOOL="${CMUX_CODESIGN_TOOL:-/usr/bin/codesign}"

if [[ ! -f "$BINARY" || ! -x "$BINARY" ]]; then
  echo "error: hook helper is missing or not executable: $BINARY" >&2
  exit 1
fi

"$CODESIGN_TOOL" --verify --strict --verbose=2 "$BINARY"
SIGNATURE_DETAILS="$("$CODESIGN_TOOL" -dv --verbose=4 "$BINARY" 2>&1)"
if ! grep -Eq 'flags=.*runtime' <<<"$SIGNATURE_DETAILS"; then
  echo "error: hook helper is missing the hardened runtime signature: $BINARY" >&2
  exit 1
fi

if ! ENTITLEMENTS="$("$CODESIGN_TOOL" -d --entitlements :- "$BINARY" 2>&1)"; then
  echo "error: unable to inspect hook helper entitlements: $BINARY" >&2
  exit 1
fi
for forbidden in \
  application-identifier \
  com.apple.security.cs.allow-jit \
  com.apple.security.cs.allow-unsigned-executable-memory \
  com.apple.security.cs.disable-library-validation
do
  if grep -Fq "$forbidden" <<<"$ENTITLEMENTS"; then
    echo "error: hook helper carries forbidden entitlement $forbidden: $BINARY" >&2
    exit 1
  fi
done

echo "hook helper signature OK: $BINARY"
