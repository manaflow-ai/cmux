#!/bin/bash

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "usage: verify-macos-signature.sh <binary>" >&2
  exit 2
fi

binary="$1"
requirement='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and identifier "com.cmuxterm.coderouter" and certificate leaf[subject.OU] = "7WLXT3NR37"'

codesign --verify --strict --verbose=2 -R="$requirement" "$binary"

signing_details="$(codesign -dv --verbose=4 "$binary" 2>&1)"
grep -Fxq 'Identifier=com.cmuxterm.coderouter' <<<"$signing_details"
grep -Fxq 'TeamIdentifier=7WLXT3NR37' <<<"$signing_details"
grep -Eq '^CodeDirectory .*flags=0x[0-9a-fA-F]+\(runtime\)' <<<"$signing_details"

# CodeRouter needs no entitlement. Both the XML and the current text output
# use an explicit key marker when an entitlement is present.
entitlements="$(codesign -d --entitlements - "$binary" 2>/dev/null || true)"
if grep -Eq '<key>|^[[:space:]]*\[Key\]' <<<"$entitlements"; then
  echo "CodeRouter must not contain a code-signing entitlement" >&2
  exit 1
fi
