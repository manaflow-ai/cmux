#!/usr/bin/env bash
# Puts the pinned full uBlock Origin (GPL-3.0) into the app bundle at
# Contents/Resources/Extensions/ublock-origin (run by embed-cef.sh, the Xcode
# "Embed CEF" phase; the app loads it when browser.builtInAdBlocker is on,
# CEFBuiltInExtensions.swift). The copy comes from fetch-ublock.sh (pinned
# release ZIP, SHA-256 checked, cached). It carries LICENSE.txt, SOURCE.txt
# (corresponding source link) and its source receipt.
#
# No network or a failed check leaves a build without it: the app then starts
# Chromium without the built-in blocker. CMUX_NEXT_REQUIRE_UBLOCK=1 turns
# that into a build failure (release builds). CMUX_NEXT_SKIP_UBLOCK=1 skips it.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
dest="$app/Contents/Resources/Extensions/ublock-origin"

if [[ "${CMUX_NEXT_SKIP_UBLOCK:-}" == 1 ]]; then
  rm -rf "$dest"
  echo "uBlock Origin: skipped (CMUX_NEXT_SKIP_UBLOCK=1)"
  exit 0
fi
if ! src="$("$script_dir/fetch-ublock.sh")" || [[ ! -f "$src/manifest.json" ]]; then
  rm -rf "$dest"
  if [[ "${CMUX_NEXT_REQUIRE_UBLOCK:-}" == 1 ]]; then
    echo "error: the built-in uBlock Origin could not be staged (scripts/cmux-next/fetch-ublock.sh)" >&2
    exit 1
  fi
  echo "warning: built-in uBlock Origin not bundled (fetch-ublock.sh failed); Chromium starts without it" >&2
  exit 0
fi
mkdir -p "$dest"
/usr/bin/rsync -a --delete "$src/" "$dest/"
echo "bundled uBlock Origin from $src"
