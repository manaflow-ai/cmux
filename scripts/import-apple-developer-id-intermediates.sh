#!/usr/bin/env bash
# Import Apple's Developer ID intermediate certificates into an ephemeral
# signing keychain so codesign can build a complete chain on every runner.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <keychain>" >&2
  exit 2
fi

KEYCHAIN="$1"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

download_and_add() {
  local name="$1"
  local url="$2"
  local cert_path="$TMP_DIR/$name.cer"

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
  security add-certificates -k "$KEYCHAIN" "$cert_path"
}

download_and_add \
  DeveloperIDCA \
  https://www.apple.com/certificateauthority/DeveloperIDCA.cer
download_and_add \
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
