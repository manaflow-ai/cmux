#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Embeds the pinned, team-signed "cmux Helper Host (dev).app"
# (helper-host-dev.pin.json; docs/computer-use-helper.md) at
#   Contents/Library/cmux Helper Host (dev).app
# of a DEV build, where its cmux-tui daemon finds it, copies it outside the app
# and starts it. Run from the "Embed Computer Use helper (dev)" phase
# (embed-cua-helper-dev.sh). The bytes are never re-signed (cmux Computer Use's code
# identity, and so its macOS grants, must stay the same across builds).
# A Release build embeds it only with CMUX_NEXT_EMBED_HELPER_HOST_IN_RELEASE=1 (decision of
# 2026-11-16: the third-party notices and the load-command check of a published build do not cover
# the embedded bundle yet). Without the variable a Release build prints one note line and embeds
# nothing, and with CMUX_NEXT_REQUIRE_HELPER_HOST=1 and not the variable it fails: a build that
# requires the asset does not go out with none. With the variable, Release requires the asset.
# CMUX_NEXT_ALLOW_NO_HELPER_HOST=1 is the opt-in of such a Release build that may go out with no cmux
# Computer Use (decision of 2026-11-16): on a Mac with no source for the asset (no cached zip, a store
# that gives no URL for it, no read credentials) that build prints one NOT EMBEDDED warning line and
# embeds nothing (docs/computer-use-helper.md). With the opt-in a missing pin file, a failed download and a
# sha256 mismatch still fail the build, and CMUX_NEXT_REQUIRE_HELPER_HOST=1 is stronger than it.
# DEV warns and embeds nothing unless CMUX_NEXT_REQUIRE_HELPER_HOST=1; a sha256 mismatch fails.
# A bench build (reload.sh --config bench: a Release configuration with -DCMUX_BENCH_HOOKS in
# OTHER_SWIFT_FLAGS, lib/bench-swift-defines.sh) is never published (check-no-bench-hooks.sh), so
# the asset is optional there as in DEV. A dogfood `reload.sh --release` build with a tag of
# release_bench_tags (cmux-next.dogfood.conf) is a bench build too: on a Mac with no asset it has no
# cmux Computer Use, and the only sign is the warning line in the build log.
# CMUX_NEXT_SKIP_HELPER_HOST=1 embeds nothing.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
name="cmux Helper Host (dev).app"
dest="$app/Contents/Library/$name"
stamp="${TARGET_TEMP_DIR:-$TARGET_BUILD_DIR}/embed-helper-host-dev.stamp"
skip() {
  echo "note: not embedding cmux Computer Use (dev): $1"
  rm -rf "$dest"
  rm -f "$stamp"
  exit 0
}
[[ "${CMUX_NEXT_SKIP_HELPER_HOST:-0}" == "1" ]] && skip "CMUX_NEXT_SKIP_HELPER_HOST=1"
[[ " ${ARCHS:-arm64} " == *" arm64 "* ]] || skip "ARCHS=${ARCHS:-} has no arm64"
pin="${CMUX_NEXT_HELPER_HOST_PIN:-$SCRIPT_DIR/helper-host-dev.pin.json}"
required="${CMUX_NEXT_REQUIRE_HELPER_HOST:-0}"
bench=0
[[ " ${OTHER_SWIFT_FLAGS:-} " == *" -DCMUX_BENCH_HOOKS "* ]] && bench=1
allow_no_source=0
if [[ "${CONFIGURATION:-}" == "Release" && "$bench" == "0" ]]; then
  if [[ "${CMUX_NEXT_EMBED_HELPER_HOST_IN_RELEASE:-0}" != "1" ]]; then
    [[ "$required" == "1" ]] && { echo "error: CMUX_NEXT_REQUIRE_HELPER_HOST=1 in a Release build needs CMUX_NEXT_EMBED_HELPER_HOST_IN_RELEASE=1 (a Release build embeds cmux Computer Use only when asked)" >&2; exit 1; }
    skip "Release configuration (embedded only with CMUX_NEXT_EMBED_HELPER_HOST_IN_RELEASE=1)"
  fi
  [[ "$required" != "1" && "${CMUX_NEXT_ALLOW_NO_HELPER_HOST:-0}" == "1" ]] && allow_no_source=1
  required=1
fi
if [[ ! -f "$pin" ]]; then
  [[ "$required" == "1" ]] && { echo "error: cmux Computer Use requires pin file $pin" >&2; exit 1; }
  skip "no pin file $pin"
fi
args=(--optional)
[[ "$required" == "1" ]] && args=()
[[ "$allow_no_source" == "1" ]] && args=(--allow-no-source)
fetch=0
zip="$("$SCRIPT_DIR/ensure-cua-pinned-asset.sh" "$pin" ${args[@]+"${args[@]}"})" || fetch=$?
if [[ "$fetch" == "3" && "$allow_no_source" == "1" ]]; then
  echo "warning: helper-host-dev: NOT EMBEDDED (this Mac has no cached zip and no read credentials)" >&2
  rm -rf "$dest"
  rm -f "$stamp"
  exit 0
fi
[[ "$fetch" == "0" ]] || exit "$fetch"
[[ -n "$zip" ]] || skip "the pinned cmux Computer Use is unavailable"
want="$(shasum -a 256 "$zip" | awk '{print $1}')"
if [[ -f "$stamp" && "$(cat "$stamp")" == "$want" ]] && codesign --verify --strict "$dest" 2>/dev/null; then
  echo "note: cmux Computer Use (dev) already embedded ($want)"
  exit 0
fi
rm -rf "$dest"
mkdir -p "$app/Contents/Library"
ditto -x -k "$zip" "$app/Contents/Library"
[[ -d "$dest" ]] || { echo "error: $zip has no $name" >&2; exit 1; }
codesign --verify --strict --deep "$dest" || { echo "error: the embedded cmux Computer Use's signature does not verify" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$dest/Contents/Info.plist")" == com.cmuxterm.helper-host.dev ]] ||
  { echo "error: the embedded cmux Computer Use is not com.cmuxterm.helper-host.dev" >&2; exit 1; }
python3 -I "$SCRIPT_DIR/../ci/macho_minos.py" scan "$dest" --floor "${MACOSX_DEPLOYMENT_TARGET:-14.0}" ||
  { rm -rf "$dest"; echo "error: the pinned cmux Computer Use cannot load on macOS ${MACOSX_DEPLOYMENT_TARGET:-14.0}" >&2; exit 1; }
mkdir -p "$(dirname "$stamp")"
# Nothing in it may be a .framework: a fleet cross build re-signs nested frameworks ad hoc.
if find "$dest" -name "*.framework" -type d | grep -q .; then
  rm -rf "$dest"; echo "error: cmux Computer Use must ship no nested .framework (build-helper-host-dev.sh)" >&2; exit 1
fi
echo "$want" > "$stamp"
echo "note: embedded cmux Computer Use (dev) sha256 $want"
