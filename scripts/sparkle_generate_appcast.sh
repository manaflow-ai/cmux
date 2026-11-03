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

# The macOS floor of the build in the DMG, from its bundle:
#   SPARKLE_MINIMUM_SYSTEM_VERSION="$(scripts/ci/appcast_minimum_system_version.py floor "$APP")"
# The new item must carry it as sparkle:minimumSystemVersion, or Sparkle would
# offer a macOS 26 build (cmux-next) to macOS 14/15. Required: fail closed.
if [[ -z "${SPARKLE_MINIMUM_SYSTEM_VERSION:-}" ]]; then
  echo "SPARKLE_MINIMUM_SYSTEM_VERSION is required (scripts/ci/appcast_minimum_system_version.py floor <app>)." >&2
  exit 1
fi

SPARKLE_VERSION="${SPARKLE_VERSION:-2.8.1}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/manaflow-ai/cmux/releases/download/$TAG/}"
RELEASE_NOTES_URL="${RELEASE_NOTES_URL:-https://github.com/manaflow-ai/cmux/releases/tag/$TAG}"

work_dir="$(mktemp -d)"
app_mount=""
cleanup() {
  if [[ -n "$app_mount" ]]; then
    hdiutil detach "$app_mount" -quiet >/dev/null 2>&1 || hdiutil detach "$app_mount" -force -quiet >/dev/null 2>&1 || true
  fi
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

# The feed must be signed by the key the shipped app trusts. generate_appcast
# silently skips signing when the private key's public key is not the
# SUPublicEDKey of the app in the archive, and a feed signed with another key
# looks fine here but every installed app rejects the update. Compare the two
# keys up front and fail closed.
derive_public_key() {
  # openssl (OpenSSL 1.1.1+) first; LibreSSL (macOS /usr/bin/openssl) has no
  # Ed25519, so fall back to CryptoKit through swift.
  python3 "$(dirname "$0")/ci/dev_app_linux.py" sparkle-public-key SPARKLE_PRIVATE_KEY 2>/dev/null && return 0
  command -v swift >/dev/null 2>&1 || return 1
  printf '%s' "$SPARKLE_PRIVATE_KEY" | env -u SPARKLE_PRIVATE_KEY swift "$(dirname "$0")/derive_sparkle_public_key.swift" --stdin
}
if ! private_public_key="$(derive_public_key)" || [[ -z "$private_public_key" ]]; then
  echo "ERROR: could not derive the public key of SPARKLE_PRIVATE_KEY (expected a base64 Ed25519 Sparkle key)." >&2
  exit 1
fi
app_mount="$work_dir/app-mount"
mkdir -p "$app_mount"
if ! hdiutil attach "$archives_dir/$(basename "$DMG_PATH")" -nobrowse -readonly -noautoopen -mountpoint "$app_mount" -quiet >/dev/null; then
  app_mount=""
  echo "ERROR: could not mount $DMG_PATH to read the app's SUPublicEDKey." >&2
  exit 1
fi
if ! app_public_key="$(python3 - "$app_mount" <<'PY'
import glob, os, plistlib, sys
apps = sorted(glob.glob(os.path.join(sys.argv[1], "*.app")))
if len(apps) != 1:
    sys.exit(f"ERROR: expected one .app at the root of the DMG, found {len(apps)}")
with open(os.path.join(apps[0], "Contents", "Info.plist"), "rb") as f:
    key = plistlib.load(f).get("SUPublicEDKey")
if not isinstance(key, str) or not key.strip():
    sys.exit(f"ERROR: {os.path.basename(apps[0])} has no SUPublicEDKey to check SPARKLE_PRIVATE_KEY against")
print(key.strip())
PY
)"; then
  exit 1
fi
hdiutil detach "$app_mount" -quiet >/dev/null 2>&1 || hdiutil detach "$app_mount" -force -quiet >/dev/null 2>&1 || true
app_mount=""
if [[ "$private_public_key" != "$app_public_key" ]]; then
  echo "ERROR: SPARKLE_PRIVATE_KEY's public key ($private_public_key) does not match the app's SUPublicEDKey ($app_public_key) in $(basename "$DMG_PATH"); every installed app would reject this feed." >&2
  exit 1
fi
echo "Verified: SPARKLE_PRIVATE_KEY matches the app's SUPublicEDKey"
dmg_length="$(wc -c < "$DMG_PATH" | tr -d ' ')"

# Delta updates: older archives of the same track placed next to the new one
# make generate_appcast emit <sparkle:deltas> items plus .delta files, so a
# machine on a recent build downloads only what changed.
delta_args=()
if [[ -n "${SPARKLE_PREVIOUS_ARCHIVES_DIR:-}" ]]; then
  previous_count=0
  for previous in "$SPARKLE_PREVIOUS_ARCHIVES_DIR"/*.dmg; do
    [[ -f "$previous" ]] || continue
    cp -p "$previous" "$archives_dir/$(basename "$previous")"
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
# to sign the DMG and inject the signature. The key was checked against the
# app's SUPublicEDKey above, and the signature is verified before it is used.
if ! grep -q 'sparkle:edSignature' "$generated_appcast_path"; then
  echo "Warning: generate_appcast did not add edSignature. Using sign_update fallback..."
  SIGNATURE=$("$sign_update" -p --ed-key-file "$key_file" "$DMG_PATH")
  if [[ -z "$SIGNATURE" ]] || ! "$sign_update" --verify --ed-key-file "$key_file" "$DMG_PATH" "$SIGNATURE"; then
    echo "ERROR: sign_update's signature for $(basename "$DMG_PATH") does not verify." >&2
    exit 1
  fi
  DMG_LENGTH="$dmg_length"
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
    # Replace generate_appcast's length rather than add a second one: a
    # duplicate attribute makes the whole feed unparsable.
    attrs = re.sub(r'\s+length="[^"]*"', "", attrs).rstrip()
    attrs += ' sparkle:edSignature="' + sig + '" length="' + length + '"'
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

floor_tool="$(dirname "$0")/ci/appcast_minimum_system_version.py"
python3 "$floor_tool" enforce "$generated_appcast_path" \
  --archive "$(basename "$DMG_PATH")" --minimum "$SPARKLE_MINIMUM_SYSTEM_VERSION"
# Optional: the last build below the floor (the final legacy release), so
# older macOS keeps being offered it instead of nothing. See
# skills/cmux-release/references/cmux-next-update-floor.md.
if [[ -n "${SPARKLE_LEGACY_APPCAST_ITEM_FILE:-}" ]]; then
  python3 "$floor_tool" append-legacy "$generated_appcast_path" \
    --item-file "$SPARKLE_LEGACY_APPCAST_ITEM_FILE" --floor "$SPARKLE_MINIMUM_SYSTEM_VERSION"
fi

# Optional: tag every item with one Sparkle channel (the cmux-next track uses
# `cmux-next`). Sparkle offers a channel-tagged item only to an updater whose
# allowedChannels include it, so builds that read another feed ignore them.
if [[ -n "${SPARKLE_CHANNEL:-}" ]]; then
  python3 - "$generated_appcast_path" "$SPARKLE_CHANNEL" <<'EOF'
import re, sys
path, channel = sys.argv[1:3]
if not re.fullmatch(r"[A-Za-z0-9._-]+", channel):
    sys.exit(f"invalid SPARKLE_CHANNEL {channel!r}")
xml = open(path, encoding="utf-8").read()
xml = re.sub(r"\s*<sparkle:channel>[^<]*</sparkle:channel>", "", xml)
xml, count = re.subn(r"<item>", f"<item>\n            <sparkle:channel>{channel}</sparkle:channel>", xml)
if count == 0:
    sys.exit("appcast has no items to tag")
open(path, "w", encoding="utf-8").write(xml)
print(f"Tagged {count} appcast item(s) with sparkle:channel {channel}")
EOF
fi

cp "$generated_appcast_path" "$OUT_PATH"
echo "Generated appcast at $OUT_PATH"

# Verify the full-archive enclosure is signed and announces the DMG's exact size.
if python3 - "$OUT_PATH" "$(basename "$DMG_PATH")" "$dmg_length" <<'PY'
import sys, urllib.parse
import xml.etree.ElementTree as ET
path, dmg_name, length = sys.argv[1:4]
signature_attr = "{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"
names = {dmg_name, urllib.parse.quote(dmg_name)}
enclosures = [e for e in ET.parse(path).iter("enclosure") if e.get("url", "").rsplit("/", 1)[-1] in names]
if len(enclosures) != 1:
    sys.exit(f"ERROR: expected one enclosure for {dmg_name}, found {len(enclosures)}")
enclosure = enclosures[0]
if not enclosure.get(signature_attr):
    sys.exit(f"ERROR: the enclosure for {dmg_name} is missing sparkle:edSignature!")
if enclosure.get("length") != length:
    sys.exit(f"ERROR: the enclosure for {dmg_name} has length {enclosure.get('length')!r}, but the DMG is {length} bytes")
PY
then
  echo "Verified: appcast signs $(basename "$DMG_PATH") with its exact length ($dmg_length bytes)"
else
  rm -f "$OUT_PATH"
  exit 1
fi
