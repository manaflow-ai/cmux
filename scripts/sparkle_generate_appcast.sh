#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <dmg-path> <tag> [output-path]" >&2
  exit 1
fi

DMG_PATH="$1"
TAG="$2"
OUT_PATH="${3:-appcast.xml}"

if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  echo "SPARKLE_PRIVATE_KEY is required (exported from Sparkle generate_keys)." >&2
  exit 1
fi

SPARKLE_VERSION="${SPARKLE_VERSION:-2.8.1}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/manaflow-ai/cmuxterm/releases/download/$TAG/}"
RELEASE_NOTES_URL="${RELEASE_NOTES_URL:-https://github.com/manaflow-ai/cmuxterm/releases/tag/$TAG}"

work_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

echo "Cloning Sparkle ${SPARKLE_VERSION}..."
git clone --depth 1 --branch "$SPARKLE_VERSION" https://github.com/sparkle-project/Sparkle "$work_dir/Sparkle"

echo "Building Sparkle generate_appcast tool..."
xcodebuild \
  -project "$work_dir/Sparkle/Sparkle.xcodeproj" \
  -scheme generate_appcast \
  -configuration Release \
  -derivedDataPath "$work_dir/build" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

echo "Building Sparkle sign_update tool..."
xcodebuild \
  -project "$work_dir/Sparkle/Sparkle.xcodeproj" \
  -scheme sign_update \
  -configuration Release \
  -derivedDataPath "$work_dir/build" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

generate_appcast="$work_dir/build/Build/Products/Release/generate_appcast"
sign_update="$work_dir/build/Build/Products/Release/sign_update"

if [[ ! -x "$generate_appcast" ]]; then
  echo "generate_appcast binary not found at $generate_appcast" >&2
  exit 1
fi
if [[ ! -x "$sign_update" ]]; then
  echo "sign_update binary not found at $sign_update" >&2
  exit 1
fi

archives_dir="$work_dir/archives"
mkdir -p "$archives_dir"
cp "$DMG_PATH" "$archives_dir/$(basename "$DMG_PATH")"

key_file="$work_dir/sparkle_ed_key"
# Ensure base64 padding (keys may be stored without trailing '=')
padded_key="$SPARKLE_PRIVATE_KEY"
while (( ${#padded_key} % 4 != 0 )); do
  padded_key="${padded_key}="
done
printf "%s" "$padded_key" > "$key_file"

"$generate_appcast" \
  --ed-key-file "$key_file" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --full-release-notes-url "$RELEASE_NOTES_URL" \
  "$archives_dir"

if [[ ! -f "$archives_dir/appcast.xml" ]]; then
  echo "appcast.xml not generated." >&2
  exit 1
fi

# Check if generate_appcast added the edSignature. If not, use sign_update
# to sign the DMG and inject the signature. generate_appcast silently skips
# signing when the public key derived from the private key doesn't match the
# SUPublicEDKey in the app's Info.plist.
if ! grep -q 'sparkle:edSignature' "$archives_dir/appcast.xml"; then
  echo "Warning: generate_appcast did not add edSignature. Using sign_update fallback..."
  SIGNATURE=$("$sign_update" -p --ed-key-file "$key_file" "$DMG_PATH")
  DMG_LENGTH=$(stat -f%z "$DMG_PATH")
  echo "  EdDSA signature: ${SIGNATURE:0:20}..."
  echo "  DMG length: $DMG_LENGTH"

  # Inject sparkle:edSignature and correct length into the enclosure element
  python3 -c "
import sys
xml = open('$archives_dir/appcast.xml').read()
sig = '$SIGNATURE'
length = '$DMG_LENGTH'
# Add edSignature to enclosure
xml = xml.replace(
    'type=\"application/octet-stream\"',
    'sparkle:edSignature=\"' + sig + '\" length=\"' + length + '\" type=\"application/octet-stream\"'
)
open('$archives_dir/appcast.xml', 'w').write(xml)
print('  Injected edSignature into appcast.xml')
"
fi

cp "$archives_dir/appcast.xml" "$OUT_PATH"
echo "Generated appcast at $OUT_PATH"

# Verify the appcast has a signature
if grep -q 'sparkle:edSignature' "$OUT_PATH"; then
  echo "Verified: appcast contains sparkle:edSignature"
else
  echo "ERROR: appcast is missing sparkle:edSignature!" >&2
  exit 1
fi
