#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Portable regression for the missing Remote bundle. A Release build embeds the asset only when
# asked (decision of 2026-11-16): without CMUX_NEXT_EMBED_CMUX_REMOTE_IN_RELEASE=1 it prints one
# note line, embeds nothing and passes, also with no pin file, with a cached asset and with the
# opt-in below. With CMUX_NEXT_REQUIRE_CMUX_REMOTE=1 and not that variable it fails with one line
# that names the variable. A Release build that is asked requires the pin file and the asset. Only
# with CMUX_NEXT_ALLOW_NO_CMUX_REMOTE=1 added, and with no source for the asset (no cached
# zip, a store that gives no URL for it, no read credentials), it prints one NOT EMBEDDED warning
# line and embeds nothing; a failed download and a sha256 mismatch stay errors, and
# CMUX_NEXT_REQUIRE_CMUX_REMOTE=1 is stronger than the opt-in. A DEV build and a bench build (a
# Release configuration with -DCMUX_BENCH_HOOKS in OTHER_SWIFT_FLAGS) warn and embed nothing.
# The last section reads the project file: each variable is an input of the Xcode phase.
# No signing, network, or real credentials. Each case prints `ok:` or `FAIL:`; all cases run.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
failed=0
output=""
result=0
pass() { echo "ok: $1"; }
fail() { echo "FAIL: $1" >&2; echo "$output" >&2; failed=$((failed + 1)); }
# What the app target's script phase gets from `reload.sh --config bench` (the flags of a real build
# line). The bench defines come from the one shared file that reload.sh reads, so a change of the
# define there that the embed script does not follow makes the bench cases fail.
# shellcheck source=../lib/bench-swift-defines.sh
source "$root/scripts/cmux-next/lib/bench-swift-defines.sh"
bench_flags="-Xcc -fmodule-map-file=/b/GeneratedModuleMaps/CmuxNextMallocZone.modulemap $CMUX_BENCH_SWIFT_DEFINES"
dest="$scratch/build/cmux.app/Contents/Library/cmux Remote (dev).app"
asset="cmux-remote-dev-macos-arm64.zip"
# A stand-in for ditto: it records its arguments and unpacks nothing.
mkdir -p "$scratch/bin"
cat > "$scratch/bin/ditto" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$scratch/ditto.calls"
STUB
chmod +x "$scratch/bin/ditto"
# A stand-in for curl (no network): it records the URL. The artifact store's request for a signed
# URL gets the URL in $scratch/store.url, when there is one; with none the request fails. A download
# copies $scratch/remote.zip, when there is one, to the -o path; with none the download fails.
cat > "$scratch/bin/curl" <<STUB
#!/bin/bash
out=""
url=""
while (( \$# )); do
  case "\$1" in
    --config) cat > /dev/null; shift 2 ;;
    -o) out="\$2"; shift 2 ;;
    *) url="\$1"; shift ;;
  esac
done
printf '%s\n' "\$url" >> "$scratch/curl.calls"
if [[ "\$url" == */v1/artifacts/*/url ]]; then
  [[ -f "$scratch/store.url" ]] || exit 22
  printf '{"url": "%s"}\n' "\$(cat "$scratch/store.url")"
  exit 0
fi
[[ -f "$scratch/remote.zip" ]] || exit 22
cp "$scratch/remote.zip" "\$out"
STUB
chmod +x "$scratch/bin/curl"
run() { # <configuration> [NAME=VALUE ...] -> output, result
  local configuration="$1"
  shift
  set +e
  output="$(env -i PATH="$scratch/bin:/usr/bin:/bin" HOME="$scratch" ARCHS=arm64 CONFIGURATION="$configuration" \
    TARGET_BUILD_DIR="$scratch/build" TARGET_TEMP_DIR="$scratch/temp" WRAPPER_NAME=cmux.app \
    CMUX_NEXT_CMUX_REMOTE_PIN="$scratch/pin.json" CMUX_CUA_ASSET_CACHE_DIR="$scratch/cache" \
    CMUX_CUA_ASSET_NO_STORE=1 CMUX_CEF_R2_ENV_FILE=/dev/null ${@+"$@"} \
    /bin/bash "$root/scripts/cmux-next/embed-cmux-remote-dev.sh" 2>&1)"
  result=$?
  set -e
}
warnings() { printf '%s\n' "$output" | grep -c '^warning: ' || true; }
stamp="$scratch/temp/embed-cmux-remote-dev.stamp"
not_embedded="warning: cmux-remote-dev: NOT EMBEDDED (this Mac has no cached zip and no read credentials)"
# A Release build embeds the asset only with this variable (decision of 2026-11-16). No track sets it.
embed=(CMUX_NEXT_EMBED_CMUX_REMOTE_IN_RELEASE=1)
# The opt-in of a Release build that is asked and may go out with no cmux Remote. No track sets it.
allow=(CMUX_NEXT_ALLOW_NO_CMUX_REMOTE=1)
# The copy and the stamp of an earlier build: a build that embeds nothing removes both. Each case
# that expects `gone` makes them first, so the check can fail.
stale() { mkdir -p "$dest/Contents" "$scratch/temp"; echo stale > "$stamp"; }
gone() { [[ ! -e "$dest" && ! -e "$stamp" ]]; }
# A build that is optional and has no asset: one warning, the note, nothing left in the app.
optional_without_asset() {
  [[ "$result" == 0 && "$(warnings)" == 1 && "$output" == *"warning: pin.json unavailable"* &&
    "$output" == *"not embedding"* && "$output" != *"NOT EMBEDDED"* ]] && gone
}
# A Release build that is not asked to embed: the one note line that names the variable, exit 0,
# nothing left in the app. It reads no pin file and looks for no asset.
release_not_asked() {
  [[ "$result" == 0 && "$output" == "note: not embedding cmux Remote (dev): Release configuration"* &&
    "$output" == *"CMUX_NEXT_EMBED_CMUX_REMOTE_IN_RELEASE=1"* && "$output" != *$'\n'* ]] && gone
}
# A Release build that requires the asset and is not asked to embed it: one error line that names
# the variable. A build that requires the asset does not go out with none.
require_not_asked() {
  [[ "$result" != 0 && "$output" == "error: "*"CMUX_NEXT_EMBED_CMUX_REMOTE_IN_RELEASE=1"* && "$output" != *$'\n'* ]]
}

# 1. No pin file.
name="Release that is asked to embed, with no pin file, fails"
run Release "${embed[@]}"
if [[ "$result" != 0 && "$output" == *"requires pin file"* ]]; then pass "$name"; else fail "$name"; fi
name="Release that is not asked to embed, with no pin file, prints the one note line, embeds nothing and passes"
stale
run Release
if release_not_asked; then pass "$name"; else fail "$name"; fi
name="Release with CMUX_NEXT_REQUIRE_CMUX_REMOTE=1 that is not asked to embed fails with one line that names the variable"
run Release CMUX_NEXT_REQUIRE_CMUX_REMOTE=1
if require_not_asked; then pass "$name"; else fail "$name"; fi
name="Debug with no pin file embeds nothing and passes"
stale
run Debug
if [[ "$result" == 0 && "$output" == *"not embedding"* ]] && gone; then pass "$name"; else fail "$name"; fi
name="a bench build with no pin file embeds nothing and passes"
stale
run Release OTHER_SWIFT_FLAGS="$bench_flags"
if [[ "$result" == 0 && "$output" == *"not embedding"* ]] && gone; then pass "$name"; else fail "$name"; fi

# 2. A pin, and the asset in no source: no cache, no store, no credentials.
printf '{"asset":"%s","sha256":"%064d","arch":"arm64"}\n' "$asset" 0 > "$scratch/pin.json"
name="Release that is asked to embed, with no source for the asset, fails"
run Release "${embed[@]}"
if [[ "$result" != 0 && "$output" == *"error: pin.json unavailable"* && "$output" != *"NOT EMBEDDED"* ]]; then pass "$name"; else fail "$name"; fi
name="Release that is asked to embed, with other defines and no bench define, fails with no source for the asset"
run Release "${embed[@]}" OTHER_SWIFT_FLAGS="-DCMUX_BLOCKING_CHECKS -DCMUX_BENCH_HOOKS_OFF"
if [[ "$result" != 0 && "$output" == *"error: pin.json unavailable"* && "$output" != *"NOT EMBEDDED"* ]]; then pass "$name"; else fail "$name"; fi
name="Release that is asked to embed, with the opt-in and no source, prints the one NOT EMBEDDED line, embeds nothing and passes"
stale
run Release "${embed[@]}" "${allow[@]}"
if [[ "$result" == 0 && "$output" == "$not_embedded" ]] && gone; then pass "$name"; else fail "$name"; fi
name="Release that is asked to embed, with the opt-in and CMUX_NEXT_REQUIRE_CMUX_REMOTE=1, fails with no source for the asset"
run Release "${embed[@]}" "${allow[@]}" CMUX_NEXT_REQUIRE_CMUX_REMOTE=1
if [[ "$result" != 0 && "$output" == *"error: pin.json unavailable"* && "$output" != *"NOT EMBEDDED"* ]]; then pass "$name"; else fail "$name"; fi
name="Release that is not asked to embed, with no source for the asset, prints the one note line, embeds nothing and passes"
stale
run Release
if release_not_asked; then pass "$name"; else fail "$name"; fi
name="Release that is not asked to embed, with other defines and no bench define, prints the one note line, embeds nothing and passes"
stale
run Release OTHER_SWIFT_FLAGS="-DCMUX_BLOCKING_CHECKS -DCMUX_BENCH_HOOKS_OFF"
if release_not_asked; then pass "$name"; else fail "$name"; fi
# The opt-in is for a Release build that is asked: alone it does not ask, and the build has the
# note line, not the NOT EMBEDDED line.
name="Release with the opt-in that is not asked to embed prints the one note line, embeds nothing and passes"
stale
run Release "${allow[@]}"
if release_not_asked; then pass "$name"; else fail "$name"; fi
name="Release with the opt-in and CMUX_NEXT_REQUIRE_CMUX_REMOTE=1 that is not asked to embed fails with one line that names the variable"
run Release "${allow[@]}" CMUX_NEXT_REQUIRE_CMUX_REMOTE=1
if require_not_asked; then pass "$name"; else fail "$name"; fi
name="Debug with no asset warns one time, embeds nothing and passes"
stale
run Debug
if optional_without_asset; then pass "$name"; else fail "$name"; fi
name="Debug with the opt-in and no asset is a DEV build: it warns one time, embeds nothing and passes"
stale
run Debug "${allow[@]}"
if optional_without_asset; then pass "$name"; else fail "$name"; fi
name="Debug with the bench define and no asset warns one time, embeds nothing and passes"
stale
run Debug OTHER_SWIFT_FLAGS="$bench_flags"
if optional_without_asset; then pass "$name"; else fail "$name"; fi
name="a bench build with no asset warns one time, embeds nothing and passes"
stale
run Release OTHER_SWIFT_FLAGS="$bench_flags"
if optional_without_asset; then pass "$name"; else fail "$name"; fi
# The opt-in is for a Release build with no bench define only: a bench build with it gets the
# warning of an optional build, not the NOT EMBEDDED line.
name="a bench build with the opt-in and no asset is a bench build: it warns one time, embeds nothing and passes"
stale
run Release OTHER_SWIFT_FLAGS="$bench_flags" "${allow[@]}"
if optional_without_asset; then pass "$name"; else fail "$name"; fi
# The variable that asks is for a Release build with no bench define only: a bench build and a DEV
# build with it are as without it.
name="a bench build that is asked to embed, with no asset, is a bench build: it warns one time, embeds nothing and passes"
stale
run Release OTHER_SWIFT_FLAGS="$bench_flags" "${embed[@]}"
if optional_without_asset; then pass "$name"; else fail "$name"; fi
name="Debug that is asked to embed, with no asset, is a DEV build: it warns one time, embeds nothing and passes"
stale
run Debug "${embed[@]}"
if optional_without_asset; then pass "$name"; else fail "$name"; fi
# The embed script looks for the word -DCMUX_BENCH_HOOKS between spaces: also as the only flag and
# as the last flag.
name="a bench build with the bench define as its only flag is a bench build"
stale
run Release OTHER_SWIFT_FLAGS="-DCMUX_BENCH_HOOKS"
if optional_without_asset; then pass "$name"; else fail "$name"; fi
name="a bench build with the bench define as its last flag is a bench build"
stale
run Release OTHER_SWIFT_FLAGS="-DCMUX_BLOCKING_CHECKS -DCMUX_BENCH_HOOKS"
if optional_without_asset; then pass "$name"; else fail "$name"; fi
name="a bench build with CMUX_NEXT_REQUIRE_CMUX_REMOTE=1 fails with no asset"
run Release OTHER_SWIFT_FLAGS="$bench_flags" CMUX_NEXT_REQUIRE_CMUX_REMOTE=1
if [[ "$result" != 0 && "$output" == *"unavailable"* ]]; then pass "$name"; else fail "$name"; fi
# A local copy with other bytes than the pin's: a sha256 mismatch is an error in each build, also
# where a missing asset is not.
printf 'not the pinned bytes\n' > "$scratch/other.zip"
name="a bench build with a local copy of other bytes fails with a sha256 mismatch"
run Release OTHER_SWIFT_FLAGS="$bench_flags" CMUX_CUA_ASSET_FILE="$scratch/other.zip"
if [[ "$result" != 0 && "$output" == *"error: sha256 mismatch"* ]]; then pass "$name"; else fail "$name"; fi
name="Release that is asked to embed, with the opt-in and a local copy of other bytes, fails with a sha256 mismatch"
run Release "${embed[@]}" "${allow[@]}" CMUX_CUA_ASSET_FILE="$scratch/other.zip"
if [[ "$result" != 0 && "$output" == *"error: sha256 mismatch"* && "$output" != *"NOT EMBEDDED"* ]]; then pass "$name"; else fail "$name"; fi
name="Release that is not asked to embed does not read a local copy: the one note line, nothing embedded, it passes"
stale
run Release CMUX_CUA_ASSET_FILE="$scratch/other.zip"
if release_not_asked; then pass "$name"; else fail "$name"; fi

# 3. The asset is in the cache: each configuration goes on to the unpack step with the cached file.
# The stand-in unpacks nothing, so the script stops at its next check; the embed itself needs macOS
# tools (ditto, codesign, PlistBuddy) and is not run here.
printf 'a stand-in for the signed zip\n' > "$scratch/asset.zip"
sha="$(shasum -a 256 "$scratch/asset.zip" | awk '{print $1}')"
mkdir -p "$scratch/cache/$sha"
cp "$scratch/asset.zip" "$scratch/cache/$sha/$asset"
printf '{"asset":"%s","sha256":"%s","arch":"arm64"}\n' "$asset" "$sha" > "$scratch/pin.json"
unpack="-x -k $scratch/cache/$sha/$asset $scratch/build/cmux.app/Contents/Library"
unpacked() { [[ "$result" != 0 && "$output" == *"has no cmux Remote (dev).app"* && "$(cat "$scratch/ditto.calls")" == "$unpack" ]]; }
name="Release that is asked to embed, with a cached asset, goes on to unpack it"
: > "$scratch/ditto.calls"
run Release "${embed[@]}"
if unpacked; then pass "$name"; else fail "$name"; fi
name="Release that is asked to embed, with CMUX_NEXT_REQUIRE_CMUX_REMOTE=1 and a cached asset, goes on to unpack it"
: > "$scratch/ditto.calls"
run Release "${embed[@]}" CMUX_NEXT_REQUIRE_CMUX_REMOTE=1
if unpacked; then pass "$name"; else fail "$name"; fi
name="Release that is not asked to embed, with a cached asset, does not unpack it: the one note line, nothing embedded, it passes"
stale
: > "$scratch/ditto.calls"
run Release
if release_not_asked && [[ ! -s "$scratch/ditto.calls" ]]; then pass "$name"; else fail "$name"; fi
name="Release with CMUX_NEXT_REQUIRE_CMUX_REMOTE=1 that is not asked to embed, with a cached asset, fails with the one line and does not unpack it"
: > "$scratch/ditto.calls"
run Release CMUX_NEXT_REQUIRE_CMUX_REMOTE=1
if require_not_asked && [[ ! -s "$scratch/ditto.calls" ]]; then pass "$name"; else fail "$name"; fi
name="Debug with a cached asset goes on to unpack it"
: > "$scratch/ditto.calls"
run Debug
if unpacked; then pass "$name"; else fail "$name"; fi
name="a bench build with a cached asset goes on to unpack it"
: > "$scratch/ditto.calls"
run Release OTHER_SWIFT_FLAGS="$bench_flags"
if unpacked; then pass "$name"; else fail "$name"; fi

# 4. Read credentials (stand-in values; the stand-in for curl is the only fetch): a Release build
# that is asked and can reach the asset embeds it, and a failed download is an error, not a NOT
# EMBEDDED build, also with the opt-in.
printf 'a stand-in for the fetched zip\n' > "$scratch/fetched.zip"
sha="$(shasum -a 256 "$scratch/fetched.zip" | awk '{print $1}')"
printf '{"asset":"%s","sha256":"%s","arch":"arm64","r2_bucket":"bucket","r2_key":"key/%s"}\n' "$asset" "$sha" "$asset" > "$scratch/pin.json"
credentials=(CMUX_CEF_R2_ACCESS_KEY_ID=stand-in CMUX_CEF_R2_SECRET_ACCESS_KEY=stand-in CMUX_CEF_R2_ENDPOINT=https://store.invalid)
name="Release that is asked to embed, with the opt-in, read credentials and a failed download, fails"
: > "$scratch/curl.calls"
run Release "${embed[@]}" "${allow[@]}" "${credentials[@]}"
if [[ "$result" != 0 && "$output" == *"error: pin.json unavailable: R2 download failed"* && "$output" != *"NOT EMBEDDED"* &&
  "$(cat "$scratch/curl.calls")" == "https://store.invalid/bucket/key/$asset" ]]; then pass "$name"; else fail "$name"; fi
name="Release that is asked to embed, with read credentials, fetches the asset and goes on to unpack it"
cp "$scratch/fetched.zip" "$scratch/remote.zip"
unpack="-x -k $scratch/cache/$sha/$asset $scratch/build/cmux.app/Contents/Library"
: > "$scratch/ditto.calls"
: > "$scratch/curl.calls"
run Release "${embed[@]}" "${credentials[@]}"
if unpacked && [[ "$output" != *"NOT EMBEDDED"* && "$(cat "$scratch/curl.calls")" == "https://store.invalid/bucket/key/$asset" ]]; then pass "$name"; else fail "$name"; fi
name="Release that is not asked to embed, with read credentials, fetches and unpacks nothing: the one note line, it passes"
stale
: > "$scratch/ditto.calls"
: > "$scratch/curl.calls"
run Release "${credentials[@]}"
if release_not_asked && [[ ! -s "$scratch/curl.calls" && ! -s "$scratch/ditto.calls" ]]; then pass "$name"; else fail "$name"; fi

# 5. The artifact store is on (the stand-in for curl answers for it), for a Release build that is
# asked, with the opt-in and no credentials. A store that gives no URL for the asset is no source: NOT EMBEDDED. A store that
# gives a URL, and a download of the bytes that then fails, is a failed download: an error, as with
# credentials.
rm -f "$scratch/remote.zip"
printf 'a stand-in for the stored zip\n' > "$scratch/stored.zip"
sha="$(shasum -a 256 "$scratch/stored.zip" | awk '{print $1}')"
printf '{"asset":"%s","sha256":"%s","arch":"arm64"}\n' "$asset" "$sha" > "$scratch/pin.json"
store=(CMUX_CUA_ASSET_NO_STORE=0 CMUX_CEF_STORE_URL=http://store.invalid)
ask="http://store.invalid/v1/artifacts/sha256:$sha/url"
name="Release that is asked to embed, with the opt-in and a store that gives no URL for the asset, prints the one NOT EMBEDDED line and passes"
stale
: > "$scratch/curl.calls"
run Release "${embed[@]}" "${allow[@]}" "${store[@]}"
if [[ "$result" == 0 && "$output" == "$not_embedded" && "$(cat "$scratch/curl.calls")" == "$ask" ]] && gone; then pass "$name"; else fail "$name"; fi
name="Release that is asked to embed, with the opt-in, a store that gives a URL and a failed download, fails"
echo "https://signed.invalid/object" > "$scratch/store.url"
: > "$scratch/curl.calls"
run Release "${embed[@]}" "${allow[@]}" "${store[@]}"
if [[ "$result" != 0 && "$output" == *"error: pin.json unavailable: the download from the artifact store failed"* &&
  "$output" != *"NOT EMBEDDED"* && "$(cat "$scratch/curl.calls")" == "$ask"$'\n'"https://signed.invalid/object" ]]; then pass "$name"; else fail "$name"; fi
name="Release that is asked to embed, with the opt-in and a store that gives a URL, fetches the asset and goes on to unpack it"
cp "$scratch/stored.zip" "$scratch/remote.zip"
unpack="-x -k $scratch/cache/$sha/$asset $scratch/build/cmux.app/Contents/Library"
: > "$scratch/ditto.calls"
run Release "${embed[@]}" "${allow[@]}" "${store[@]}"
if unpacked && [[ "$output" != *"NOT EMBEDDED"* ]]; then pass "$name"; else fail "$name"; fi

# 6. A cached file with other bytes than the pin's is no cache hit: the fetch removes it and looks
# for the asset again. With the opt-in and no source, the build has the one NOT EMBEDDED warning
# line; the fact about the damaged file is a note, not a second warning.
printf 'a stand-in for a zip that no cache has\n' > "$scratch/absent.zip"
sha="$(shasum -a 256 "$scratch/absent.zip" | awk '{print $1}')"
printf '{"asset":"%s","sha256":"%s","arch":"arm64"}\n' "$asset" "$sha" > "$scratch/pin.json"
mkdir -p "$scratch/cache/$sha"
printf 'damaged\n' > "$scratch/cache/$sha/$asset"
name="Release that is asked to embed, with the opt-in, a damaged cached file and no source, has the one NOT EMBEDDED warning line and passes"
stale
run Release "${embed[@]}" "${allow[@]}"
if [[ "$result" == 0 && "$(warnings)" == 1 && "$output" == *"$not_embedded"* && "$output" == *"is damaged"* &&
  ! -e "$scratch/cache/$sha/$asset" ]] && gone; then pass "$name"; else fail "$name"; fi

# 7. The embed script reads its variables from the environment of the Xcode phase that runs it
# ("Embed Computer Use helper (dev)"). Each one is an input of that phase in the project file, so a
# build after a change of one of them runs the phase again. This reads the project file; no Xcode.
inputs="$(awk '
  /\/\* Embed Computer Use helper \(dev\) \*\/ = \{/ { phase = 1 }
  phase && /inputPaths = \(/ { list = 1; next }
  phase && list && /^[[:space:]]*\);/ { exit }
  phase && list { print }
' "$root/cmux.xcodeproj/project.pbxproj")"
for variable in CMUX_NEXT_CMUX_REMOTE_PIN CMUX_NEXT_SKIP_CMUX_REMOTE CMUX_NEXT_REQUIRE_CMUX_REMOTE \
  CMUX_NEXT_ALLOW_NO_CMUX_REMOTE CMUX_NEXT_EMBED_CMUX_REMOTE_IN_RELEASE; do
  name="the embed phase of the project file has $variable as an input"
  output="the inputs of the phase:"$'\n'"$inputs"
  if grep -q -F -- "\"\$($variable)\"," <<< "$inputs"; then pass "$name"; else fail "$name"; fi
done

if [[ "$failed" != 0 ]]; then
  echo "embed-cmux-remote-dev.test.sh: $failed failed" >&2
  exit 1
fi
echo "embed-cmux-remote-dev.test.sh: passed (Release embeds the asset only when asked; asked = required; the opt-in and no source = NOT EMBEDDED; DEV and bench stay optional)"
