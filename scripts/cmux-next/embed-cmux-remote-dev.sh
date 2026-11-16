#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Embeds the pinned, team-signed "cmux Remote (dev).app"
# (cmux-remote-dev.pin.json; docs/cmux-remote.md) at
#   Contents/Library/cmux Remote (dev).app
# of a DEV build, where its cmux-tui daemon finds it, copies it outside the app
# and starts it. Run from the "Embed Computer Use helper (dev)" phase
# (embed-cua-helper-dev.sh). The bytes are never re-signed (cmux Remote's code
# identity, and so its macOS grants, must stay the same across builds).
# The embedded worker is signed separately and is also used by NIGHTLY Release builds.
# Release requires the pin file and embeds the asset when this Mac has it or can fetch it; a failed
# download fails the build. A Release build on a Mac with no source for the asset (no cached zip,
# none in the store, no read credentials) prints one NOT EMBEDDED warning line and embeds nothing,
# as before the asset became required (decision of 2026-11-16); such a build has no cmux Remote
# (docs/cmux-remote.md). CMUX_NEXT_REQUIRE_CMUX_REMOTE=1 makes the missing asset an error for a
# build that must have it.
# DEV warns and embeds nothing unless CMUX_NEXT_REQUIRE_CMUX_REMOTE=1; a sha256 mismatch fails.
# A bench build (reload.sh --config bench, check-release-compile.sh --bench-hooks: a Release
# configuration with -DCMUX_BENCH_HOOKS in OTHER_SWIFT_FLAGS) is never published
# (check-no-bench-hooks.sh), so the asset is optional there as in DEV.
# CMUX_NEXT_SKIP_CMUX_REMOTE=1 embeds nothing.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
name="cmux Remote (dev).app"
dest="$app/Contents/Library/$name"
stamp="${TARGET_TEMP_DIR:-$TARGET_BUILD_DIR}/embed-cmux-remote-dev.stamp"
skip() {
  echo "note: not embedding cmux Remote (dev): $1"
  rm -rf "$dest"
  rm -f "$stamp"
  exit 0
}
[[ "${CMUX_NEXT_SKIP_CMUX_REMOTE:-0}" == "1" ]] && skip "CMUX_NEXT_SKIP_CMUX_REMOTE=1"
[[ " ${ARCHS:-arm64} " == *" arm64 "* ]] || skip "ARCHS=${ARCHS:-} has no arm64"
pin="${CMUX_NEXT_CMUX_REMOTE_PIN:-$SCRIPT_DIR/cmux-remote-dev.pin.json}"
required="${CMUX_NEXT_REQUIRE_CMUX_REMOTE:-0}"
bench=0
[[ " ${OTHER_SWIFT_FLAGS:-} " == *" -DCMUX_BENCH_HOOKS "* ]] && bench=1
release=0
[[ "${CONFIGURATION:-}" == "Release" && "$bench" == "0" ]] && release=1
if [[ ! -f "$pin" ]]; then
  [[ "$required" == "1" || "$release" == "1" ]] && { echo "error: cmux Remote requires pin file $pin" >&2; exit 1; }
  skip "no pin file $pin"
fi
args=(--optional)
[[ "$release" == "1" ]] && args=(--allow-no-source)
[[ "$required" == "1" ]] && args=()
fetch=0
zip="$("$SCRIPT_DIR/ensure-cua-pinned-asset.sh" "$pin" ${args[@]+"${args[@]}"})" || fetch=$?
if [[ "$fetch" == "3" && "$release" == "1" && "$required" != "1" ]]; then
  echo "warning: cmux-remote-dev: NOT EMBEDDED (this Mac has no cached zip and no read credentials)" >&2
  rm -rf "$dest"
  rm -f "$stamp"
  exit 0
fi
[[ "$fetch" == "0" ]] || exit "$fetch"
[[ -n "$zip" ]] || skip "the pinned cmux Remote is unavailable"
want="$(shasum -a 256 "$zip" | awk '{print $1}')"
if [[ -f "$stamp" && "$(cat "$stamp")" == "$want" ]] && codesign --verify --strict "$dest" 2>/dev/null; then
  echo "note: cmux Remote (dev) already embedded ($want)"
  exit 0
fi
rm -rf "$dest"
mkdir -p "$app/Contents/Library"
ditto -x -k "$zip" "$app/Contents/Library"
[[ -d "$dest" ]] || { echo "error: $zip has no $name" >&2; exit 1; }
codesign --verify --strict --deep "$dest" || { echo "error: the embedded cmux Remote's signature does not verify" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$dest/Contents/Info.plist")" == com.cmuxterm.remote.dev ]] ||
  { echo "error: the embedded cmux Remote is not com.cmuxterm.remote.dev" >&2; exit 1; }
python3 -I "$SCRIPT_DIR/../ci/macho_minos.py" scan "$dest" --floor "${MACOSX_DEPLOYMENT_TARGET:-14.0}" ||
  { rm -rf "$dest"; echo "error: the pinned cmux Remote cannot load on macOS ${MACOSX_DEPLOYMENT_TARGET:-14.0}" >&2; exit 1; }
mkdir -p "$(dirname "$stamp")"
# Nothing in it may be a .framework: a fleet cross build re-signs nested frameworks ad hoc.
if find "$dest" -name "*.framework" -type d | grep -q .; then
  rm -rf "$dest"; echo "error: cmux Remote must ship no nested .framework (build-cmux-remote-dev.sh)" >&2; exit 1
fi
echo "$want" > "$stamp"
echo "note: embedded cmux Remote (dev) sha256 $want"
