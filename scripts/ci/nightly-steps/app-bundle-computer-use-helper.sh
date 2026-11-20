#!/usr/bin/env bash
# nightly.yml build-nightly-app: assemble the one Computer Use permission app
# after Xcode has produced cmux.app and before the unsigned app is handed to
# the signing job. The helper is built from this tree's Rust Computer Use
# engine and cmux-remote Swift host on the same fleet Mac.
set -euo pipefail

app="build-universal/Build/Products/Release/cmux.app"
[[ -d "$app/Contents" ]] || { echo "error: no Release cmux.app at $app" >&2; exit 1; }

archs="${NIGHTLY_COMPILE_ARCHS:?missing NIGHTLY_COMPILE_ARCHS}"
case "$archs" in
  arm64|"arm64 x86_64") ;;
  *) echo "error: unsupported Computer Use helper architectures: $archs" >&2; exit 1 ;;
esac

out="$(mktemp -d "$RUNNER_TEMP/cmux-computer-use.XXXXXX")"
trap 'rm -rf "$out"' EXIT

# The caller has joined the Screen Sharing build for this exact checkout and architecture.
screen="${CMUX_NEXT_SCREEN_HELPER_PENDING_BIN:?missing Screen Sharing helper path}"
[[ -x "$screen" ]] || { echo "error: Screen Sharing helper was not built at $screen" >&2; exit 1; }

CMUX_NEXT_SCREEN_HELPER_BIN="$screen" \
  scripts/cmux-next/build-cmux-remote-dev.sh \
    --release --archs "$archs" --out "$out"

helper="$out/cmux Computer Use.app"
[[ -d "$helper/Contents" ]] || { echo "error: helper assembly produced no $helper" >&2; exit 1; }
for path in \
  Contents/MacOS/cmux-remote \
  Contents/MacOS/cmux-screen-sharing \
  Contents/Frameworks/libcmux_computer_use.dylib \
  Contents/Frameworks/libWebRTC.dylib; do
  [[ -f "$helper/$path" ]] || { echo "error: assembled helper is missing $path" >&2; exit 1; }
done

library="$app/Contents/Library"
mkdir -p "$library"
if [[ -e "$library/cmux Remote.app" || -e "$library/cmux Remote (dev).app" ]]; then
  echo "error: obsolete Remote helper in the Release product" >&2
  exit 1
fi
ditto "$helper" "$library/cmux Computer Use.app"
echo "assembled $library/cmux Computer Use.app ($archs)"
