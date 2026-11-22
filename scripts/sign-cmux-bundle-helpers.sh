#!/usr/bin/env bash
# Step 0 and 1 of scripts/sign-cmux-bundle.sh: stamp the cmux server launchd
# plists from the FINAL bundle id, then Developer ID sign every Mach-O helper
# under Contents/Resources/bin and Contents/Resources/libexec.
#
#   scripts/sign-cmux-bundle-helpers.sh <app-path> <helper-entitlements> <signing-identity>
#
# Helpers get minimal hardened-runtime entitlements (no application-identifier).
# libexec/cmux-server-helper is a root LaunchDaemon and gets none, with the
# identifier cmux-server-helper. Symlinks (bin/cmux-tui, bin/acpmux -> cmux)
# and scripts are left to the bundle seal: a codesigned script stores its
# signature in an extended attribute, which Sparkle's BinaryDelta refuses to
# diff. Plists under Contents/Library carry no signature of their own; the app
# signature seals them.
#
# Env: CMUX_TIMESTAMP=none for un-timestamped local signatures;
# CMUX_CODESIGN_TOOL and CMUX_FILE_TOOL override the tools (tests).
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <app-path> <helper-entitlements> <signing-identity>" >&2
  exit 2
fi

APP_PATH="$1"
HELPER_ENTITLEMENTS="$2"
IDENTITY="$3"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODESIGN_TOOL="${CMUX_CODESIGN_TOOL:-/usr/bin/codesign}"
FILE_TOOL="${CMUX_FILE_TOOL:-/usr/bin/file}"
if [[ "${CMUX_TIMESTAMP:-}" == "none" ]]; then
  TS_FLAG=(--timestamp=none)
else
  TS_FLAG=(--timestamp)
fi
COMMON=(--force --options runtime "${TS_FLAG[@]}" --sign "$IDENTITY")

# 0. The cmux server's LaunchDaemon (helper) and LaunchAgent (server) plists
# follow the FINAL bundle id (nightly and RC rename the bundle after the build,
# and release jobs install the cmux CLI after it); stable drops both.
"$SCRIPT_DIR/cmux-next/bundle-server-helper.sh" --stamp "$APP_PATH"

# 1. CLI and private helpers
for helper_dir in bin libexec; do
  for helper in "$APP_PATH/Contents/Resources/$helper_dir"/*; do
    # bin/cmux-tui and bin/acpmux are relative symlinks to bin/cmux, which is
    # signed as itself; the bundle seal records the links.
    if [[ -L "$helper" ]]; then
      echo "==> leaving symlink $(basename "$helper") -> $(readlink "$helper") to the bundle seal"
      continue
    fi
    [[ -f "$helper" && -x "$helper" ]] || continue
    if ! "$FILE_TOOL" -b "$helper" | grep -q 'Mach-O'; then
      echo "==> leaving non-Mach-O helper $(basename "$helper") to the bundle seal"
      continue
    fi
    if [[ "$helper_dir/$(basename "$helper")" == "libexec/cmux-server-helper" ]]; then
      # A root LaunchDaemon gets no entitlements (no JIT, no library validation opt-out).
      echo "==> signing root helper $helper_dir/cmux-server-helper (no entitlements)"
      "$CODESIGN_TOOL" "${COMMON[@]}" --identifier cmux-server-helper "$helper"
      continue
    fi
    echo "==> signing helper $helper_dir/$(basename "$helper")"
    "$CODESIGN_TOOL" "${COMMON[@]}" --entitlements "$HELPER_ENTITLEMENTS" "$helper"
  done
done
