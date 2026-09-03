#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <app-bundle>" >&2
    exit 2
fi

app_path="$1"
if [[ ! -d "$app_path" ]]; then
    echo "error: app bundle not found: $app_path" >&2
    exit 1
fi

signing_identity="${CMUX_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning \
        | sed -n '/Apple Development:/ { s/^[[:space:]]*[0-9]*) \([[:xdigit:]]\{40\}\) .*/\1/; p; q; }' \
        | head -n 1)"
fi
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning \
        | sed -n '/Developer ID Application:/ { s/^[[:space:]]*[0-9]*) \([[:xdigit:]]\{40\}\) .*/\1/; p; q; }' \
        | head -n 1)"
fi
if [[ -z "$signing_identity" ]]; then
    echo "error: no Apple Development or Developer ID signing identity found" >&2
    exit 1
fi

echo "Signing $(basename "$app_path") with: $signing_identity"
/usr/bin/codesign \
    --force \
    --deep \
    --timestamp=none \
    --preserve-metadata=entitlements,requirements,flags \
    --sign "$signing_identity" \
    "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"
/usr/bin/codesign -dv --verbose=2 "$app_path" 2>&1 \
    | sed -n '/^Identifier=/p; /^TeamIdentifier=/p; /^Authority=/p; /^Signature=/p'
