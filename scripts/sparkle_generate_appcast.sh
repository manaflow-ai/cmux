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

generate_appcast="$work_dir/build/Build/Products/Release/generate_appcast"
if [[ ! -x "$generate_appcast" ]]; then
  echo "generate_appcast binary not found at $generate_appcast" >&2
  exit 1
fi

archives_dir="$work_dir/archives"
mkdir -p "$archives_dir"
cp "$DMG_PATH" "$archives_dir/$(basename "$DMG_PATH")"

printf "%s" "$SPARKLE_PRIVATE_KEY" | "$generate_appcast" \
  --ed-key-file - \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --full-release-notes-url "$RELEASE_NOTES_URL" \
  "$archives_dir"

if [[ ! -f "$archives_dir/appcast.xml" ]]; then
  echo "appcast.xml not generated." >&2
  exit 1
fi

cp "$archives_dir/appcast.xml" "$OUT_PATH"
echo "Generated appcast at $OUT_PATH"
