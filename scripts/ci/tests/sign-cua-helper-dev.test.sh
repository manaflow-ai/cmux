#!/usr/bin/env bash
# Layout check of the main-only Computer Use helper signer, on any checkout.
# Signing itself needs macOS codesign; this covers the bundle-contents check
# that runs before it, in the C locale and in en_US.UTF-8 (where sort puts
# libcua_driver_sdk.dylib before libWebRTC.dylib).
set -euo pipefail
signer="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sign-cua-helper-dev.sh"
bash -n "$signer"
# shellcheck source=SCRIPTDIR/../sign-cua-helper-dev.sh
source "$signer"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/new" "$work/old" "$work/extra" "$work/hidden"
touch "$work/new/libWebRTC.dylib" "$work/new/libcua_driver_sdk.dylib"
touch "$work/old/libcua_driver_sdk.dylib"
touch "$work/extra/libWebRTC.dylib" "$work/extra/libcua_driver_sdk.dylib" "$work/extra/libevil.dylib"
touch "$work/hidden/libcua_driver_sdk.dylib" "$work/hidden/.libevil.dylib"

locales=(C)
if LC_ALL=en_US.UTF-8 bash -c 'true' 2>/dev/null &&
  [[ "$(printf 'libWebRTC.dylib\nlibcua_driver_sdk.dylib\n' | LC_ALL=en_US.UTF-8 sort | head -1)" == libcua_driver_sdk.dylib ]]; then
  locales+=(en_US.UTF-8)
else
  echo "note: en_US.UTF-8 not installed or sorts like C here; only the C locale is covered" >&2
fi
for locale in "${locales[@]}"; do
  export LC_ALL="$locale"
  holds_only "$work/new" libcua_driver_sdk.dylib libWebRTC.dylib || { echo "FAIL [$locale]: new layout rejected" >&2; exit 1; }
  holds_only "$work/new" libWebRTC.dylib libcua_driver_sdk.dylib || { echo "FAIL [$locale]: argument order matters" >&2; exit 1; }
  holds_only "$work/old" libcua_driver_sdk.dylib || { echo "FAIL [$locale]: old layout rejected" >&2; exit 1; }
  if holds_only "$work/old" libcua_driver_sdk.dylib libWebRTC.dylib; then echo "FAIL [$locale]: missing dylib accepted" >&2; exit 1; fi
  if holds_only "$work/new" libcua_driver_sdk.dylib; then echo "FAIL [$locale]: extra dylib accepted" >&2; exit 1; fi
  if holds_only "$work/extra" libcua_driver_sdk.dylib libWebRTC.dylib; then echo "FAIL [$locale]: unknown dylib accepted" >&2; exit 1; fi
  if holds_only "$work/hidden" libcua_driver_sdk.dylib; then echo "FAIL [$locale]: dotfile accepted" >&2; exit 1; fi
  if holds_only "$work/missing" libcua_driver_sdk.dylib 2>/dev/null; then echo "FAIL [$locale]: missing dir accepted" >&2; exit 1; fi
  echo "layout check ok under LC_ALL=$locale"
done
echo "Computer Use helper signer layout contract: ok"
