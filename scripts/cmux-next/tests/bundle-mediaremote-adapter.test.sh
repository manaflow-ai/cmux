#!/usr/bin/env bash
# bundle-mediaremote-adapter.sh under Xcode's /bin/bash 3.2, into a fake app:
# the framework (both slices, the adapter_* symbols the Perl script calls, a
# valid signature), the script and license in Resources, an unchanged second
# run skips the compile, and `/usr/bin/perl` can load the framework and answer
# `get` (JSON or null, whatever plays on the host). macOS only (clang,
# codesign); run on a GUI host or fleet Mac.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }

app="$TMP/build/cmux NEXT.app"
mkdir -p "$app/Contents"
run() {
  env SRCROOT="$ROOT" TARGET_BUILD_DIR="$TMP/build" WRAPPER_NAME="cmux NEXT.app" TARGET_TEMP_DIR="$TMP/temp" \
    ARCHS="arm64 x86_64" MACOSX_DEPLOYMENT_TARGET=14.0 EXPANDED_CODE_SIGN_IDENTITY= \
    /bin/bash "$ROOT/scripts/cmux-next/bundle-mediaremote-adapter.sh"
}

out=$(run 2>&1) || fail "the phase failed" "$out"
fw="$app/Contents/Frameworks/MediaRemoteAdapter.framework"
binary="$fw/Versions/A/MediaRemoteAdapter"
[[ -f "$binary" ]] || fail "no framework binary" "$out"
archs=$(lipo -archs "$binary")
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "slices: $archs"
for symbol in adapter_stream adapter_get adapter_send adapter_seek; do
  nm -gU "$binary" | grep -q "_${symbol}$" || fail "the framework does not export $symbol"
done
codesign --verify --strict "$fw" || fail "the framework's signature does not verify"
[[ -f "$app/Contents/Resources/MediaRemoteAdapter/mediaremote-adapter.pl" ]] || fail "no adapter script"
[[ -f "$app/Contents/Resources/MediaRemoteAdapter/LICENSE" ]] || fail "no adapter license"

again=$(run 2>&1) || fail "the second run failed" "$again"
[[ "$again" == *"unchanged"* ]] || fail "an unchanged second run compiled again" "$again"

got=$(/usr/bin/perl "$app/Contents/Resources/MediaRemoteAdapter/mediaremote-adapter.pl" "$fw" get 2>&1) \
  || fail "perl could not run the adapter" "$got"
/usr/bin/python3 -c 'import json,sys; json.loads(sys.argv[1])' "$got" || fail "get printed no JSON" "$got"
echo "PASS bundle-mediaremote-adapter"
