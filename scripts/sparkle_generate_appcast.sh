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
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/manaflow-ai/cmux/releases/download/$TAG/}"
RELEASE_NOTES_URL="${RELEASE_NOTES_URL:-https://github.com/manaflow-ai/cmux/releases/tag/$TAG}"

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

# Delta updates: older archives of the same track placed next to the new one
# make generate_appcast emit <sparkle:deltas> items plus .delta files, so a
# machine on a recent build downloads only what changed.
delta_args=()
if [[ -n "${SPARKLE_PREVIOUS_ARCHIVES_DIR:-}" ]]; then
  previous_count=0
  for previous in "$SPARKLE_PREVIOUS_ARCHIVES_DIR"/*.dmg; do
    [[ -f "$previous" ]] || continue
    cp "$previous" "$archives_dir/$(basename "$previous")"
    previous_count=$((previous_count + 1))
  done
  echo "Previous archives available for deltas: $previous_count"
  if [[ "$previous_count" -gt 0 ]]; then
    delta_args=(--maximum-deltas "${SPARKLE_MAXIMUM_DELTAS:-2}")
  fi
fi

key_file="$work_dir/sparkle_ed_key"
# Ensure base64 padding (keys may be stored without trailing '=')
padded_key="$SPARKLE_PRIVATE_KEY"
while (( ${#padded_key} % 4 != 0 )); do
  padded_key="${padded_key}="
done
printf "%s" "$padded_key" > "$key_file"

generated_appcast_path="$archives_dir/$(basename "$OUT_PATH")"

"$generate_appcast" \
  --ed-key-file "$key_file" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --full-release-notes-url "$RELEASE_NOTES_URL" \
  "${delta_args[@]}" \
  "$archives_dir"

if [[ ! -f "$generated_appcast_path" ]]; then
  fallback_generated_appcast="$(find "$archives_dir" -maxdepth 1 -name '*.xml' | head -n 1)"
  if [[ -n "$fallback_generated_appcast" ]]; then
    generated_appcast_path="$fallback_generated_appcast"
  fi
fi

if [[ ! -f "$generated_appcast_path" ]]; then
  echo "Expected appcast was not generated." >&2
  exit 1
fi

# Check if generate_appcast added the edSignature. If not, use sign_update
# to sign the DMG and inject the signature. generate_appcast silently skips
# signing when the public key derived from the private key doesn't match the
# SUPublicEDKey in the app's Info.plist.
if ! grep -q 'sparkle:edSignature' "$generated_appcast_path"; then
  echo "Warning: generate_appcast did not add edSignature. Using sign_update fallback..."
  SIGNATURE=$("$sign_update" -p --ed-key-file "$key_file" "$DMG_PATH")
  DMG_LENGTH=$(stat -f%z "$DMG_PATH")
  echo "  EdDSA signature: ${SIGNATURE:0:20}..."
  echo "  DMG length: $DMG_LENGTH"

  # Inject sparkle:edSignature and correct length into the full-archive
  # enclosure only. Deltas cannot be signed here, and unsigned deltas would be
  # rejected by Sparkle at install time, so drop them from the feed.
  python3 - "$generated_appcast_path" "$SIGNATURE" "$DMG_LENGTH" "$(basename "$DMG_PATH")" <<'EOF'
import re, sys, urllib.parse
path, sig, length, dmg_name = sys.argv[1:5]
xml = open(path, encoding="utf-8").read()
deltas = re.compile(r"\s*<sparkle:deltas>.*?</sparkle:deltas>", re.S)
if deltas.search(xml):
    print("  Dropping unsigned delta entries from the appcast")
    xml = deltas.sub("", xml)
needle = re.compile(r'<enclosure(?P<attrs>[^>]*url="[^"]*' + re.escape(urllib.parse.quote(dmg_name)) + r'"[^>]*)/>')
match = needle.search(xml) or re.search(r'<enclosure(?P<attrs>[^>]*url="[^"]*' + re.escape(dmg_name) + r'"[^>]*)/>', xml)
if not match:
    print("  error: full-archive enclosure not found in appcast", file=sys.stderr)
    sys.exit(1)
attrs = match.group("attrs")
if "sparkle:edSignature" not in attrs:
    attrs = attrs.replace('type="application/octet-stream"', 'sparkle:edSignature="' + sig + '" length="' + length + '" type="application/octet-stream"')
    xml = xml[:match.start()] + "<enclosure" + attrs + "/>" + xml[match.end():]
open(path, "w", encoding="utf-8").write(xml)
print("  Injected edSignature into the full-archive enclosure")
EOF
  rm -f "$archives_dir"/*.delta
fi

# generate_appcast names deltas after the app ("cmux NIGHTLY<new>-<old>.delta"),
# which collides across per-architecture tracks and gets mangled by GitHub
# release assets. Rename them after the archive and rewrite the appcast URLs.
delta_prefix="${SPARKLE_DELTA_NAME_PREFIX:-$(basename "$DMG_PATH" .dmg | sed -E 's/-[0-9]+$//')-}"
"$(dirname "$0")/ci/finalize-sparkle-deltas.sh" \
  "$generated_appcast_path" "$archives_dir" "$(cd "$(dirname "$OUT_PATH")" && pwd)" "$delta_prefix"

cp "$generated_appcast_path" "$OUT_PATH"
echo "Generated appcast at $OUT_PATH"

# Verify the appcast has a signature
if grep -q 'sparkle:edSignature' "$OUT_PATH"; then
  echo "Verified: appcast contains sparkle:edSignature"
else
  echo "ERROR: appcast is missing sparkle:edSignature!" >&2
  exit 1
fi
