#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Embeds the pinned, team-signed "cmux Files (dev).app" (files-host-dev.pin.json,
# docs/cmux-files-host.md) at
#   Contents/Library/cmux Files (dev).app
# of a DEV build, where the app finds it (FilesHost) and runs its terminal daemon and acpmux
# under it, so macOS asks for Files and Folders once for every DEV build. Run from the "Embed
# Computer Use helper (dev)" phase (embed-cua-helper-dev.sh). The bytes are never re-signed: the
# helper's code identity, and so a person's answers, must stay the same across builds.
# A Release configuration (stable, NIGHTLY, RC, the NEXT DEV daily, bench) never embeds it.
# No pin file or no asset (no store and no R2 read credentials) embeds nothing with one note line:
# the build then runs as before. A sha256 mismatch or a bad signature fails the build.
# CMUX_NEXT_SKIP_FILES_HOST=1 embeds nothing.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
name="cmux Files (dev).app"
dest="$app/Contents/Library/$name"
stamp="${TARGET_TEMP_DIR:-$TARGET_BUILD_DIR}/embed-files-host-dev.stamp"
requirement='identifier "com.cmuxterm.files.dev" and anchor apple generic and certificate leaf[subject.OU] = "7WLXT3NR37"'
skip() {
  echo "note: not embedding cmux Files (dev): $1"
  rm -rf "$dest"
  rm -f "$stamp"
  exit 0
}
[[ "${CMUX_NEXT_SKIP_FILES_HOST:-0}" == "1" ]] && skip "CMUX_NEXT_SKIP_FILES_HOST=1"
[[ "${CONFIGURATION:-}" == "Release" ]] && skip "Release configuration (DEV builds only)"
[[ " ${ARCHS:-arm64} " == *" arm64 "* ]] || skip "ARCHS=${ARCHS:-} has no arm64"
pin="$SCRIPT_DIR/files-host-dev.pin.json"
[[ -f "$pin" ]] || skip "no pin file $pin"
zip="$("$SCRIPT_DIR/ensure-cua-pinned-asset.sh" "$pin" --optional)"
[[ -n "$zip" ]] || skip "the pinned cmux Files (dev) is unavailable"
want="$(shasum -a 256 "$zip" | awk '{print $1}')"
if [[ -f "$stamp" && "$(cat "$stamp")" == "$want" ]] && codesign --verify --strict "$dest" 2>/dev/null; then
  echo "note: cmux Files (dev) already embedded ($want)"
  exit 0
fi
rm -rf "$dest"
mkdir -p "$app/Contents/Library"
ditto -x -k "$zip" "$app/Contents/Library"
[[ -d "$dest" ]] || { echo "error: $zip has no $name" >&2; exit 1; }
codesign --verify --strict --deep -R "=$requirement" "$dest" ||
  { rm -rf "$dest"; echo "error: the embedded cmux Files (dev) is not signed as $requirement" >&2; exit 1; }
mkdir -p "$(dirname "$stamp")"
echo "$want" > "$stamp"
echo "note: embedded cmux Files (dev) sha256 $want"
