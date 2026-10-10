#!/usr/bin/env bash
# embed-remote-browser-host.sh under Xcode's /bin/bash 3.2, with a stub host
# binary, a fake app CEF framework and a file:// stand-in for the controller
# artifact store (no network, no R2). Covers: the DEV layout (CEF symlink,
# five helpers, signatures), Release embeds nothing and removes a stale host,
# a sha256 mismatch fails the build (also from a damaged store copy), a CEF
# pin mismatch or an unavailable pinned binary fails the build naming the
# artifact and digest, the explicit CMUX_NEXT_SKIP_RB_HOST=1 opt-out embeds
# nothing and records itself in the app (About) and the log, no arm64 skips,
# and the standalone bundle-remote-browser-host.sh still writes its layout. macOS only (codesign,
# clang); run on a GUI host or fleet Mac, not a developer laptop.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
S="$ROOT/scripts/cmux-next"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FW="Chromium Embedded Framework.framework"
fail() { printf 'FAIL: %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }

printf 'int main(void){return 0;}\n' > "$TMP/m.c"
clang -arch arm64 -o "$TMP/host" "$TMP/m.c"
sha=$(shasum -a 256 "$TMP/host" | awk '{print $1}')
app_cef=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$S/cef-manifest.json")

write_pin() { # <host sha> <cef sha>
  cat > "$TMP/pin.json" <<PIN
{"asset": "cmux-remote-browser-host-macos-arm64", "arch": "arm64", "sha256": "$1",
 "r2_bucket": "", "r2_key": "", "cef_sha256": "$2"}
PIN
}
serve() { # <file served for sha256:$sha>
  rm -rf "$TMP/store"; mkdir -p "$TMP/store/v1/artifacts/sha256:$sha"
  cp "$1" "$TMP/blob"
  printf '{"url": "file://%s/blob"}' "$TMP" > "$TMP/store/v1/artifacts/sha256:$sha/url"
}
new_app() {
  rm -rf "$TMP/build"
  mkdir -p "$TMP/build/app.app/Contents/Frameworks/$FW" "$TMP/build/tmp"
}
run() { # <configuration> [ARCHS] [VAR=value...] -> sets out, rc
  local config="$1" archs="${2:-arm64}"
  shift; (( $# )) && shift
  set +e
  out=$(env -i PATH=/usr/bin:/bin HOME="$TMP" TMPDIR="$TMP" ARCHS="$archs" CONFIGURATION="$config" ${1+"$@"} \
    TARGET_BUILD_DIR="$TMP/build" TARGET_TEMP_DIR="$TMP/build/tmp" WRAPPER_NAME=app.app \
    CMUX_NEXT_RB_HOST_PIN="$TMP/pin.json" CMUX_NEXT_RB_HOST_CACHE_DIR="$TMP/cache" \
    CMUX_CEF_STORE_URL="file://$TMP/store" CMUX_RB_HOST_NO_R2=1 \
    /bin/bash "$S/embed-remote-browser-host.sh" 2>&1)
  rc=$?
  set -e
}
host="$TMP/build/app.app/Contents/Helpers/cmux-remote-browser-host.app"
optout="$TMP/build/app.app/Contents/Resources/RemoteBrowserHostOptOut.txt"

# 1. Debug: embeds the pinned binary with the CEF symlink and five signed helpers.
write_pin "$sha" "$app_cef"; serve "$TMP/host"; new_app
run Debug
[[ $rc == 0 ]] || fail "Debug embed failed" "$out"
[[ -x "$host/Contents/MacOS/cmux-remote-browser-host" ]] || fail "no host executable" "$out"
[[ "$(readlink "$host/Contents/Frameworks/$FW")" == "../../../../Frameworks/$FW" ]] || fail "CEF is not the app symlink"
[[ -d "$host/Contents/Frameworks/$FW/" ]] || fail "CEF symlink does not resolve to the app framework"
n=$(ls -d "$host/Contents/Frameworks/cmux-remote-browser-host Helper"*.app | wc -l | tr -d ' ')
[[ $n == 5 ]] || fail "expected 5 helpers, got $n"
codesign --verify "$host/Contents/MacOS/cmux-remote-browser-host" || fail "host executable not signed"
codesign --verify "$host/Contents/Frameworks/cmux-remote-browser-host Helper (GPU).app" || fail "GPU helper not signed"
# Unchanged inputs: the stamp skips the rebuild.
run Debug
grep -q 'already embedded' <<<"$out" || fail "second Debug run did not reuse the embed" "$out"

# 2. Release: embeds nothing and removes the host left by the Debug build.
run Release
[[ $rc == 0 ]] || fail "Release run failed" "$out"
[[ ! -e "$host" ]] || fail "Release left the host in the app" "$out"
grep -q 'Release configuration' <<<"$out" || fail "Release did not say why" "$out"

# 3. sha256 mismatch from the store fails the build (fail closed), also optional mode.
printf 'tampered' > "$TMP/bad"; serve "$TMP/bad"; rm -rf "$TMP/cache"; new_app
run Debug
[[ $rc != 0 ]] || fail "a sha256 mismatch did not fail the build" "$out"
grep -q 'sha256 mismatch' <<<"$out" || fail "mismatch not reported" "$out"
[[ ! -e "$host" ]] || fail "a mismatched host was embedded" "$out"

# 3b. A damaged cache copy is fetched again from a good source.
serve "$TMP/host"; mkdir -p "$TMP/cache/$sha"; printf 'rot' > "$TMP/cache/$sha/cmux-remote-browser-host-macos-arm64"; new_app
run Debug
[[ $rc == 0 && -x "$host/Contents/MacOS/cmux-remote-browser-host" ]] || fail "damaged cache was not repaired" "$out"

# 4. CEF pin mismatch: fails the build, naming both digests.
write_pin "$sha" "0000000000000000000000000000000000000000000000000000000000000000"; new_app
run Debug
[[ $rc != 0 && ! -e "$host" ]] || fail "CEF pin mismatch did not fail the build" "$out"
grep -q 'CEF pin mismatch' <<<"$out" || fail "CEF mismatch not reported" "$out"
grep -q "$app_cef" <<<"$out" || fail "CEF mismatch does not name the app CEF digest" "$out"

# 5. No arm64 in ARCHS: skip.
write_pin "$sha" "$app_cef"; new_app
run Debug x86_64
[[ $rc == 0 && ! -e "$host" ]] || fail "x86_64-only build embedded a host" "$out"

# 6. Unavailable binary (no store entry, no R2): fails the build, naming the
# artifact and its pinned digest. A silent skip shipped DEV apps whose "Open
# Remote Browser Tab" could not work (2026-10-09, controller store miss).
rm -rf "$TMP/store" "$TMP/cache"; new_app
run Debug
[[ $rc != 0 && ! -e "$host" ]] || fail "an unavailable pinned binary did not fail the build" "$out"
grep -q "cmux-remote-browser-host-macos-arm64" <<<"$out" || fail "the failure does not name the artifact" "$out"
grep -q "$sha" <<<"$out" || fail "the failure does not name the pinned digest" "$out"

# 6b. The explicit opt-out embeds nothing, says so in the log and records it in
# the app (Contents/Resources/RemoteBrowserHostOptOut.txt, shown in About).
run Debug arm64 CMUX_NEXT_SKIP_RB_HOST=1
[[ $rc == 0 && ! -e "$host" ]] || fail "the opt-out failed or embedded a host" "$out"
grep -q 'CMUX_NEXT_SKIP_RB_HOST=1' <<<"$out" || fail "the opt-out is not in the build log" "$out"
grep -q 'CMUX_NEXT_SKIP_RB_HOST=1' "$optout" 2>/dev/null || fail "the opt-out is not recorded in the app" "$out"

# 6c. A later build with the host removes the opt-out record.
serve "$TMP/host"
run Debug
[[ $rc == 0 && -x "$host/Contents/MacOS/cmux-remote-browser-host" && ! -e "$optout" ]] || fail "embedding did not clear the opt-out record" "$out"

# 7. The standalone bundle script still writes the shared layout with its own CEF copy.
mkdir -p "$TMP/cef/$FW/Resources"
printf 'int cef_stub(void){return 0;}\n' > "$TMP/f.c"
clang -arch arm64 -dynamiclib -o "$TMP/cef/$FW/Chromium Embedded Framework" "$TMP/f.c"
cat > "$TMP/cef/$FW/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Chromium Embedded Framework</string><key>CFBundleIdentifier</key><string>test.cef</string><key>CFBundlePackageType</key><string>FMWK</string></dict></plist>
PLIST
/bin/bash "$S/bundle-remote-browser-host.sh" "$TMP/host" "$TMP/cef" "$TMP/standalone.app" >/dev/null
[[ -x "$TMP/standalone.app/Contents/MacOS/cmux-remote-browser-host" && -d "$TMP/standalone.app/Contents/Frameworks/$FW" && ! -L "$TMP/standalone.app/Contents/Frameworks/$FW" ]] ||
  fail "standalone bundle layout is wrong"
[[ -d "$TMP/standalone.app/Contents/Frameworks/cmux-remote-browser-host Helper (Renderer).app" ]] || fail "standalone has no Renderer helper"

printf 'embed-remote-browser-host tests: ok\n'
