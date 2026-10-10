#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# embed-cua-helper-dev.sh and ensure-cua-pinned-asset.sh under Xcode's
# /bin/bash 3.2, with a stub ad-hoc signed "cmux Computer Use (dev).app" and a
# file:// stand-in for the controller artifact store (no network, no R2).
# Covers: the DEV layout at Contents/Library with the helper's own signature
# kept (never re-signed), Release embeds nothing and removes a stale helper, a
# sha256 mismatch fails the build (also with the optional fetch), a missing
# helper warns and embeds nothing, and a cached copy is reused.
# macOS only (codesign, clang); run on a fleet Mac or cmux-lawrence-2.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
S="$ROOT/scripts/cmux-next"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
NAME="cmux Computer Use (dev).app"
fail() { printf 'FAIL: %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }

mkdir -p "$TMP/src/$NAME/Contents/MacOS"
printf 'int main(void){return 0;}\n' > "$TMP/m.c"
clang -arch arm64 -o "$TMP/src/$NAME/Contents/MacOS/cmux-cua-helper" "$TMP/m.c"
/usr/bin/python3 -c 'import plistlib,sys; plistlib.dump({"CFBundleIdentifier":"com.cmuxterm.cua.dev","CFBundleExecutable":"cmux-cua-helper","CFBundlePackageType":"APPL"}, open(sys.argv[1],"wb"))' \
  "$TMP/src/$NAME/Contents/Info.plist"
codesign --force --sign - "$TMP/src/$NAME"
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
want_hash=$(cdhash "$TMP/src/$NAME")
(cd "$TMP/src" && ditto -c -k --keepParent "$NAME" "$TMP/helper.zip")
sha=$(shasum -a 256 "$TMP/helper.zip" | awk '{print $1}')
printf '{"asset": "helper.zip", "arch": "arm64", "sha256": "%s", "r2_bucket": "", "r2_key": ""}\n' "$sha" > "$TMP/pin.json"
serve() { # <file served for sha256:$sha>
  rm -rf "$TMP/store"; mkdir -p "$TMP/store/v1/artifacts/sha256:$sha"
  cp "$1" "$TMP/blob"
  printf '{"url": "file://%s/blob"}' "$TMP" > "$TMP/store/v1/artifacts/sha256:$sha/url"
}
run() { # <configuration> -> out, rc
  set +e
  out=$(env -i PATH=/usr/bin:/bin HOME="$TMP" TMPDIR="$TMP" ARCHS=arm64 CONFIGURATION="$1" \
    TARGET_BUILD_DIR="$TMP/build" TARGET_TEMP_DIR="$TMP/build/tmp" WRAPPER_NAME=app.app \
    CMUX_NEXT_CUA_HELPER_PIN="$TMP/pin.json" CMUX_CUA_ASSET_CACHE_DIR="$TMP/cache" \
    CMUX_CEF_STORE_URL="file://$TMP/store" CMUX_CEF_R2_ENV_FILE=/dev/null \
    /bin/bash "$S/embed-cua-helper-dev.sh" 2>&1)
  rc=$?
  set -e
}
dest="$TMP/build/app.app/Contents/Library/$NAME"
mkdir -p "$TMP/build/app.app/Contents" "$TMP/build/tmp"

serve "$TMP/helper.zip"
run Debug
[[ $rc == 0 ]] || fail "Debug embed failed" "$out"
[[ -x "$dest/Contents/MacOS/cmux-cua-helper" ]] || fail "no helper at Contents/Library" "$out"
[[ "$(cdhash "$dest")" == "$want_hash" ]] || fail "the helper was re-signed" "$out"

# A cached copy is reused with no store.
rm -rf "$TMP/store" "$TMP/build/tmp/embed-cua-helper-dev.stamp"
run Debug
[[ $rc == 0 && -d "$dest" ]] || fail "the cached helper was not reused" "$out"

# Release embeds nothing and removes the stale helper.
run Release
[[ $rc == 0 && ! -e "$dest" ]] || fail "Release kept a helper" "$out"

# Damaged bytes fail the build, even though the fetch is optional.
rm -rf "$TMP/cache"
printf 'not the helper' > "$TMP/bad.zip"
serve "$TMP/bad.zip"
run Debug
[[ $rc != 0 ]] || fail "a sha256 mismatch did not fail the build" "$out"
[[ "$out" == *"sha256 mismatch"* ]] || fail "no mismatch message" "$out"

# No source: a warning and no helper.
rm -rf "$TMP/store" "$TMP/cache"
run Debug
[[ $rc == 0 && ! -e "$dest" ]] || fail "a missing helper should warn and embed nothing" "$out"
[[ "$out" == *"not embedding"* ]] || fail "no skip note" "$out"
echo "embed-cua-helper-dev.test.sh: ok"
