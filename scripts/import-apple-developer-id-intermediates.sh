#!/usr/bin/env bash
# Import Apple's Developer ID intermediate certificates into an ephemeral
# signing keychain so codesign can build a complete chain on every runner.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <keychain>" >&2
  exit 2
fi

KEYCHAIN="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_DIR="$SCRIPT_DIR/apple-developer-id-certs"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Add an intermediate to the keychain. Prefer the vendored copy committed to the
# repo so signing never depends on a live network fetch from Apple (a flaky
# www.apple.com request was producing intermittent "unable to build chain to
# self-signed root" codesign failures on the fleet). Fall back to downloading
# only if the vendored file is missing.
add_intermediate() {
  local name="$1"
  local url="$2"
  local vendored="$VENDOR_DIR/$name.cer"
  local cert_path

  if [[ -s "$vendored" ]]; then
    cert_path="$vendored"
  else
    echo "Vendored $name.cer not found at $vendored; downloading from $url" >&2
    cert_path="$TMP_DIR/$name.cer"
    curl \
      --fail \
      --location \
      --retry 3 \
      --connect-timeout 20 \
      --max-time 120 \
      --silent \
      --show-error \
      "$url" \
      --output "$cert_path"
  fi
  security add-certificates -k "$KEYCHAIN" "$cert_path"
}

add_intermediate \
  DeveloperIDCA \
  https://www.apple.com/certificateauthority/DeveloperIDCA.cer
add_intermediate \
  DeveloperIDG2CA \
  https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer

IMPORTED_COUNT="$(
  security find-certificate -c "Developer ID Certification Authority" -a -p "$KEYCHAIN" \
    | awk '/END CERTIFICATE/ { count++ } END { print count + 0 }'
)"

if [[ "$IMPORTED_COUNT" -lt 2 ]]; then
  echo "Expected both Developer ID intermediate certificates in $KEYCHAIN; found $IMPORTED_COUNT" >&2
  exit 1
fi

echo "Imported Apple Developer ID intermediate certificates into $KEYCHAIN"
