#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Signs the unsigned "cmux Files (dev).app" (build-files-host-dev.sh) with an Apple Development
# or Developer ID identity of cmux's team (hardened runtime), checks it against the requirement
# the helper stages with (identifier com.cmuxterm.files.dev, team 7WLXT3NR37), and writes the
# signed zip and files-host-dev.pin.json. Every DEV build embeds these exact bytes, so the
# helper's code identity, and a person's Files and Folders answers, stay the same until the pin
# changes (docs/cmux-files-host.md). Codesign only; the key never leaves this Mac.
#
#   sign-files-host-dev.sh UNSIGNED.zip [--identity NAME] [--keychain PATH] [--timestamp] [--out DIR]
#
# Then publish the zip where builds read it, by its sha256: `cmux-ci artifact-put` (the fleet
# store) and, with the R2 write credentials, publish-signed-pinned-asset.sh --prefix files-host-dev
# (its own R2 prefix; the fetch reads the key from the pin).
set -euo pipefail
zip="${1:?usage: sign-files-host-dev.sh UNSIGNED.zip [--identity NAME] [--keychain PATH] [--timestamp] [--out DIR]}"; shift
identity=""; keychain=(); timestamp=--timestamp=none; out="$PWD"
while (( $# )); do
  case "$1" in
    --identity) identity="${2:?}"; shift 2 ;;
    --keychain) keychain=(--keychain "${2:?}"); shift 2 ;;
    --timestamp) timestamp=--timestamp; shift ;;
    --out) out="${2:?}"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
team_id=7WLXT3NR37
bundle_id=com.cmuxterm.files.dev
asset=cmux-files-host-dev-macos-arm64.zip
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning ${keychain[1]+"${keychain[1]}"} | sed -n "s/.*\"\(Apple Development: [^\"]*\)\".*/\1/p" | head -1)"
fi
[[ -n "$identity" ]] || { echo "error: no Apple Development identity in the keychain (pass --identity)" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ditto -x -k "$zip" "$work"
app="$work/cmux Files (dev).app"
[[ -d "$app" ]] || { echo "error: $zip has no cmux Files (dev).app" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "$bundle_id" ]] ||
  { echo "error: unexpected bundle id" >&2; exit 1; }
codesign --force --options runtime "$timestamp" ${keychain[@]+"${keychain[@]}"} --sign "$identity" "$app"
team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$team" == "$team_id" ]] || { echo "error: signed by team '$team', expected $team_id" >&2; exit 1; }
requirement="identifier \"$bundle_id\" and anchor apple generic and certificate leaf[subject.OU] = \"$team_id\""
codesign --verify --strict --deep -R "=$requirement" "$app" || { echo "error: the signature does not satisfy $requirement" >&2; exit 1; }
kind="$(codesign -dvv "$app" 2>&1 | sed -En 's/^Authority=(Apple Development|Developer ID Application).*/\1/p' | head -1)"
mkdir -p "$out"
rm -f "$out/$asset"
ditto -c -k --keepParent "$app" "$out/$asset"
sha="$(shasum -a 256 "$out/$asset" | awk '{print $1}')"
unsigned_sha="$(shasum -a 256 "$zip" | awk '{print $1}')"
/usr/bin/python3 -I - "$SCRIPT_DIR/files-host-dev.pin.json" "$asset" "$sha" "$bundle_id" "$kind" "$team_id" "$unsigned_sha" <<'PY'
import json, sys
path, asset, sha, bundle_id, kind, team, unsigned = sys.argv[1:]
pin = {
    "asset": asset,
    "arch": "arm64",
    "sha256": sha,
    "r2_bucket": "cmux-cef",
    "r2_key": f"files-host-dev/{sha}/{asset}",
    "bundle_id": bundle_id,
    "signing": kind or "unknown",
    "team_id": team,
    "unsigned_sha256": unsigned,
}
with open(path, "w") as handle:
    json.dump(pin, handle, indent=2)
    handle.write("\n")
PY
echo "signed: $out/$asset ($sha); pin written to $SCRIPT_DIR/files-host-dev.pin.json"
