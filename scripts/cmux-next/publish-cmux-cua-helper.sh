#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Publishes the unsigned nightly Computer Use helper and the pinned cmux-cua
# source bundle, and writes their pins:
#   scripts/cmux-next/cmux-cua-helper.pin.json   the helper zip, for one input key
#   scripts/cmux-next/cmux-cua-source.pin.json   a git bundle of the pinned cmux-cua commit
# The nightly reads both (app-assemble-computer-use-helper.sh) from the host
# cache, the controller store, then R2, so a helper input change is built once.
#
#   publish-cmux-cua-helper.sh --dir DIR [--source-only] [--dry-run]
#   publish-cmux-cua-helper.sh --run RUN_ID [--dry-run]
#
# DIR (or the run's cmux-cua-helper-unsigned artifact, from a nightly.yml run
# of this repository) holds what a source-built nightly kept: the zip and
# key.txt. The key is checked twice: key.txt's fields must hash to its
# input_key, and every field but Xcode and the SDK must equal this checkout's
# (scripts/cmux-cua-helper-key.sh). The zip must hold one ad-hoc signed
# com.cmuxterm.cua app: storage stays unsigned; the nightly signs it.
# Upload: publish-cua-pinned-asset.sh (write-once, read back; the cmux-cef
# write credential from the environment or ~/.secrets/cmux-cef.env, never
# printed). Commit the two pins it writes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$SCRIPT_DIR/../.." && pwd)"
dir="" run="" dry=() source_only=0
while (($#)); do
  case "$1" in
    --dir) dir="${2:?}"; shift 2 ;;
    --run) run="${2:?}"; shift 2 ;;
    --source-only) source_only=1; shift ;;
    --dry-run) dry=(--dry-run); shift ;;
    *) echo "usage: publish-cmux-cua-helper.sh --dir DIR | --run RUN_ID [--source-only] [--dry-run]" >&2; exit 2 ;;
  esac
done
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
if [[ -n "$run" ]]; then
  [[ "$run" =~ ^[0-9]+$ ]] || { echo "error: --run takes a run id" >&2; exit 2; }
  path="$(gh run view "$run" --repo manaflow-ai/cmux --json path --jq .path)"
  [[ "$path" == ".github/workflows/nightly.yml" ]] || { echo "error: run $run is $path, not nightly.yml" >&2; exit 1; }
  gh run download "$run" --repo manaflow-ai/cmux --name cmux-cua-helper-unsigned --dir "$work/run"
  dir="$work/run"
fi
build="$root/scripts/build-cmux-cua.sh"
pinned_sha="$(sed -n 's/^CMUX_CUA_PINNED_SHA="\([0-9a-f]\{40\}\)"$/\1/p' "$build")"
repo_url="https://github.com/manaflow-ai/cmux-cua.git"

if (( ! source_only )); then
  [[ -n "$dir" && -f "$dir/key.txt" ]] || { echo "error: no key.txt in ${dir:-the run}" >&2; exit 1; }
  field() { sed -n "s/^$1=//p" "$dir/key.txt" | head -1; }
  key="$(field input_key)" asset="$(field asset)" sha="$(field sha256)"
  zip="$dir/$asset"
  [[ "$asset" =~ ^cmux-computer-use-unsigned-macos-[a-z0-9_-]+\.zip$ && -f "$zip" ]] || { echo "error: no zip $asset" >&2; exit 1; }
  [[ "$(shasum -a 256 "$zip" | awk '{print $1}')" == "$sha" ]] || { echo "error: $asset does not match key.txt's sha256" >&2; exit 1; }
  # key.txt: input_key, asset, sha256, then the fields in the key script's order.
  recorded="$(sed -n '4,$p' "$dir/key.txt")"
  [[ "$(printf '%s\n' "$recorded" | shasum -a 256 | awk '{print $1}')" == "$key" ]] ||
    { echo "error: key.txt's fields do not hash to its input_key" >&2; exit 1; }
  archs="$(printf '%s\n' "$recorded" | sed -n 's/^archs=//p')"
  mine="$(CMUX_CUA_KEY_XCODE="$(printf '%s\n' "$recorded" | sed -n 's/^xcode=//p')" \
    CMUX_CUA_KEY_SDK="$(printf '%s\n' "$recorded" | sed -n 's/^macos_sdk=//p')" \
    "$root/scripts/cmux-cua-helper-key.sh" --archs "$archs")"
  [[ "$mine" == "$key" ]] || { echo "error: the run's key $key is not this checkout's ($mine): another cmux-cua pin, patch or toolchain" >&2; exit 1; }
  mkdir -p "$work/app"
  if command -v ditto >/dev/null 2>&1; then ditto -x -k "$zip" "$work/app"; else unzip -q "$zip" -d "$work/app"; fi
  app="$work/app/cmux Computer Use.app"
  [[ "$(cd "$work/app" && ls -A)" == "cmux Computer Use.app" ]] || { echo "error: the zip holds more than the helper app" >&2; exit 1; }
  [[ "$(/usr/bin/env python3 -I -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb")).get("CFBundleIdentifier",""))' \
    "$app/Contents/Info.plist")" == com.cmuxterm.cua ]] || { echo "error: the helper is not com.cmuxterm.cua" >&2; exit 1; }
  [[ -x "$app/Contents/MacOS/cmux-cua" ]] || { echo "error: the helper has no executable cmux-cua" >&2; exit 1; }
  # Unsigned in storage: an ad-hoc signature only, never a team identity (no provisioning profile,
  # and on a Mac codesign must say adhoc).
  [[ ! -e "$app/Contents/embedded.provisionprofile" ]] || { echo "error: the helper carries a provisioning profile" >&2; exit 1; }
  if command -v codesign >/dev/null 2>&1; then
    codesign -dvv "$app" 2>&1 | grep -q '^Signature=adhoc$' || { echo "error: the helper carries a real signature; publish only the unsigned build" >&2; exit 1; }
  fi
  "$SCRIPT_DIR/publish-cua-pinned-asset.sh" ${dry[@]+"${dry[@]}"} --file "$zip" --prefix cmux-cua-helper \
    --pin "$SCRIPT_DIR/cmux-cua-helper.pin.json" --field "input_key=$key" --field "arch=$archs" \
    --field "bundle_id=com.cmuxterm.cua" --field "signing=adhoc (the nightly signs it)" \
    --field "cmux_cua_pinned_sha=$pinned_sha" --field "built_by=${run:+nightly.yml run $run}"
fi

# The source bundle: one ref at the pinned commit, so build-cmux-cua.sh can seed an empty cache from it.
git init --quiet --bare "$work/src.git"
git -C "$work/src.git" fetch --quiet "$repo_url" "$pinned_sha"
git -C "$work/src.git" update-ref refs/heads/pinned "$pinned_sha"
git -C "$work/src.git" symbolic-ref HEAD refs/heads/pinned
bundle="$work/cmux-cua-$pinned_sha.bundle"
git -C "$work/src.git" bundle create --quiet "$bundle" refs/heads/pinned HEAD
git clone --quiet --no-checkout "$bundle" "$work/check"
git -C "$work/check" cat-file -e "$pinned_sha^{commit}"
"$SCRIPT_DIR/publish-cua-pinned-asset.sh" ${dry[@]+"${dry[@]}"} --file "$bundle" --prefix cmux-cua-source \
  --pin "$SCRIPT_DIR/cmux-cua-source.pin.json" --field "arch=any" --field "cmux_cua_pinned_sha=$pinned_sha" \
  --field "repo=$repo_url"
