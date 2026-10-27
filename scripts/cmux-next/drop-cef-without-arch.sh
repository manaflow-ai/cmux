#!/usr/bin/env bash
# Removes the embedded Chromium engine (embed-cef.sh) from an app bundle when
# its framework has no slice for <arch>. The pinned CEF artifact is arm64
# only, so a thin x86_64 variant cut from the universal build would otherwise
# fail scripts/thin-app-bundle.sh and could never load the engine anyway. The
# app reports the browser unavailable when the framework is absent.
#
# The Chromium host (Contents/MacOS/<product> Chromium Host) and its remote
# shim go with the engine, and also alone when the host has no <arch> slice
# (its build for that arch failed): the app then reports it has no host, as
# embed-cef.sh's builds without one do.
#
# Usage: drop-cef-without-arch.sh <app> <arm64|x86_64>
# Run before thinning and signing.
set -euo pipefail
app="${1:?usage: drop-cef-without-arch.sh <app> <arch>}"
arch="${2:?usage: drop-cef-without-arch.sh <app> <arch>}"
frameworks="$app/Contents/Frameworks"
framework="$frameworks/Chromium Embedded Framework.framework"
binary="$framework/Versions/A/Chromium Embedded Framework"

drop_host() {
  local host
  rm -f "$frameworks/libcmux_cef_shim_remote.dylib"
  for host in "$app/Contents/MacOS/"*" Chromium Host"; do
    if [[ -f "$host" ]]; then rm -f "$host"; fi
  done
}

[[ -d "$framework" ]] || { echo "no Chromium engine embedded"; exit 0; }
if lipo "$binary" -verify_arch "$arch" 2>/dev/null; then
  echo "Chromium engine has an $arch slice; keeping it"
  for host in "$app/Contents/MacOS/"*" Chromium Host"; do
    [[ -f "$host" ]] || continue
    if ! lipo "$host" -verify_arch "$arch" 2>/dev/null; then
      echo "::warning title=No Chromium host for $arch::$(basename "$host") has no $arch slice ($(lipo -archs "$host")); the $arch app ships without the Chromium host"
      drop_host
    fi
  done
  exit 0
fi
echo "::warning title=No Chromium engine for $arch::the CEF artifact has no $arch slice ($(lipo -archs "$binary")); the $arch app ships the browser as unavailable"
rm -rf "$framework" "$frameworks/libcmux_cef_shim.dylib"
for helper in "$frameworks"/*" Helper.app" "$frameworks"/*" Helper ("*").app"; do
  [[ -d "$helper" ]] && rm -rf "$helper"
done
drop_host
exit 0
