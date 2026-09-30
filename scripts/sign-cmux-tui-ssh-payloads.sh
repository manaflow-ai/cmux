#!/usr/bin/env bash
# Developer ID sign the macOS cmux-tui SSH payloads in an app bundle and re-pin
# their checksums in the bundled manifest.
#
#   scripts/sign-cmux-tui-ssh-payloads.sh <app-path> <entitlements> <signing-identity>
#
# install-cmux-tui-client.sh copies every platform's cmux-tui build into
# Contents/Resources/bin/cmux-tui-ssh/ so the app can bootstrap an SSH host
# without a download. Notarization rejects the bundle while the two
# *-apple-darwin payloads there are unsigned or only linker-signed, so each
# Mach-O payload is signed with the hardened runtime and a secure timestamp,
# the same way sign-cmux-bundle.sh signs Resources/bin helpers.
#
# Signing rewrites the file, and cmux-tui checks a payload's sha256 against
# manifest.json before uploading it, so the manifest's entry for each signed
# payload is updated to the signed bytes. Payloads that are not Mach-O (the
# Linux builds) are left alone and must still match the manifest. The manifest
# is sealed by the app signature, which is applied after this script runs.
#
# Env: CMUX_TIMESTAMP=none for un-timestamped local signatures;
# CMUX_CODESIGN_TOOL and CMUX_FILE_TOOL override the tools (tests).
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <app-path> <entitlements> <signing-identity>" >&2
  exit 2
fi

APP_PATH="$1"
ENTITLEMENTS="$2"
IDENTITY="$3"
CODESIGN_TOOL="${CMUX_CODESIGN_TOOL:-/usr/bin/codesign}"
FILE_TOOL="${CMUX_FILE_TOOL:-/usr/bin/file}"
PAYLOAD_DIR="$APP_PATH/Contents/Resources/bin/cmux-tui-ssh"
MANIFEST="$PAYLOAD_DIR/manifest.json"

if [[ ! -d "$PAYLOAD_DIR" ]]; then
  echo "==> no cmux-tui SSH payloads to sign"
  exit 0
fi
if [[ ! -f "$MANIFEST" ]]; then
  echo "error: $PAYLOAD_DIR has payloads but no manifest.json" >&2
  exit 1
fi
if [[ "${CMUX_TIMESTAMP:-}" == "none" ]]; then
  TS_FLAG=(--timestamp=none)
else
  TS_FLAG=(--timestamp)
fi

signed=()
for payload in "$PAYLOAD_DIR"/*; do
  [[ -f "$payload" && ! -L "$payload" ]] || continue
  [[ "$(basename "$payload")" == manifest.json ]] && continue
  if ! "$FILE_TOOL" -b "$payload" | grep -q 'Mach-O'; then
    continue
  fi
  echo "==> signing cmux-tui SSH payload $(basename "$payload")"
  "$CODESIGN_TOOL" --force --options runtime "${TS_FLAG[@]}" --sign "$IDENTITY" \
    --entitlements "$ENTITLEMENTS" "$payload"
  signed+=("$(basename "$payload")")
done

# Re-pin the signed payloads, and fail if any payload no longer matches its pin.
python3 - "$MANIFEST" ${signed[@]+"${signed[@]}"} <<'PY'
import hashlib
import json
import os
import sys

manifest_path, signed = sys.argv[1], set(sys.argv[2:])
directory = os.path.dirname(manifest_path)
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
binaries = manifest.get("binaries")
if not isinstance(binaries, dict):
    sys.exit(f"error: {manifest_path} has no binaries map")

def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()

for name in sorted(os.listdir(directory)):
    path = os.path.join(directory, name)
    if name == "manifest.json" or os.path.islink(path) or not os.path.isfile(path):
        continue
    if name not in binaries:
        sys.exit(f"error: {manifest_path} has no checksum for payload {name}")
    actual = sha256(path)
    if name in signed:
        binaries[name] = actual
    elif binaries[name].lower() != actual:
        sys.exit(f"error: payload {name} does not match its manifest checksum")

tmp = manifest_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
os.replace(tmp, manifest_path)
PY
chmod 644 "$MANIFEST"
echo "==> re-pinned ${#signed[@]} signed cmux-tui SSH payload(s) in manifest.json"
