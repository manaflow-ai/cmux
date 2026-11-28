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

# Sparkle publishes these exact tools, universal and linked only against the
# system Swift runtime, with each release. Building them from source cost ~40s
# in every nightly variant job. SPARKLE_TOOLS_DIR points at an existing tools
# directory (tests); other versions still build from source.
SPARKLE_281_TARBALL_SHA256="5cddb7695674ef7704268f38eccaee80e3accbf19e61c1689efff5b6116d85be"
if [[ -n "${SPARKLE_TOOLS_DIR:-}" ]]; then
  tools_dir="$SPARKLE_TOOLS_DIR"
elif [[ "$SPARKLE_VERSION" == "2.8.1" ]]; then
  echo "Downloading Sparkle ${SPARKLE_VERSION} tools..."
  tarball="$work_dir/Sparkle-${SPARKLE_VERSION}.tar.xz"
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    --connect-timeout 15 --max-time 300 -o "$tarball" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
  actual_sha="$(shasum -a 256 "$tarball" | awk '{print $1}')"
  if [[ "$actual_sha" != "$SPARKLE_281_TARBALL_SHA256" ]]; then
    echo "Sparkle ${SPARKLE_VERSION} tarball checksum mismatch: $actual_sha" >&2
    exit 1
  fi
  mkdir -p "$work_dir/Sparkle"
  tar -xf "$tarball" -C "$work_dir/Sparkle" ./bin
  tools_dir="$work_dir/Sparkle/bin"
else
  echo "Cloning Sparkle ${SPARKLE_VERSION}..."
  git clone --depth 1 --branch "$SPARKLE_VERSION" https://github.com/sparkle-project/Sparkle "$work_dir/Sparkle"
  for scheme in generate_appcast sign_update BinaryDelta; do
    echo "Building Sparkle $scheme tool..."
    xcodebuild \
      -project "$work_dir/Sparkle/Sparkle.xcodeproj" \
      -scheme "$scheme" \
      -configuration Release \
      -derivedDataPath "$work_dir/build" \
      CODE_SIGNING_ALLOWED=NO \
      build >/dev/null
  done
  tools_dir="$work_dir/build/Build/Products/Release"
fi

generate_appcast="$tools_dir/generate_appcast"
sign_update="$tools_dir/sign_update"
binary_delta="$tools_dir/BinaryDelta"

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
    # generate_appcast builds deltas one after another and reuses delta files
    # that already exist, so build them concurrently first.
    "$(dirname "$0")/prebuild_sparkle_deltas.sh" \
      "$binary_delta" "$archives_dir" "$archives_dir/$(basename "$DMG_PATH")" "${SPARKLE_MAXIMUM_DELTAS:-2}"
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

# ${arr[@]+"${arr[@]}"} expands to nothing when the array is empty. A bare
# "${delta_args[@]}" is an "unbound variable" error under `set -u` in bash 3.2
# (macOS /bin/bash), and with the EXIT trap above bash 3.2 then exits 0, so the
# stable release lane (no previous archives) silently produced no appcast
# (release dry run 34227505375, 2026-09-08). Nightly never hit it because it
# always has previous archives.
"$generate_appcast" \
  --ed-key-file "$key_file" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --full-release-notes-url "$RELEASE_NOTES_URL" \
  ${delta_args[@]+"${delta_args[@]}"} \
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

# A prebuilt delta generate_appcast chose not to use (for example an old build
# it skipped) must not reach the release.
for delta in "$archives_dir"/*.delta; do
  [[ -f "$delta" ]] || continue
  name="$(basename "$delta")"
  encoded="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$name")"
  if ! grep -Fq -- "$encoded" "$generated_appcast_path" && ! grep -Fq -- "$name" "$generated_appcast_path"; then
    echo "Dropping unused delta $name"
    rm -f "$delta"
  fi
done

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
