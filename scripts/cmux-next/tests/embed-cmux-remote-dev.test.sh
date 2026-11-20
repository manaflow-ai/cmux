#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Exercise DEV pin selection and the boundary with Release assembly. No real signing or downloads.
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
dest="$scratch/build/cmux.app/Contents/Library/cmux Computer Use (dev).app"
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

legacy="$scratch/build/cmux.app/Contents/Library/cmux Remote (dev).app"
release="$scratch/build/cmux.app/Contents/Library/cmux Computer Use.app"
stale() { mkdir -p "$dest/Contents" "$legacy/Contents" "$scratch/temp"; echo stale > "$stamp"; }
gone() { [[ ! -e "$legacy" && ! -e "$dest" && ! -e "$stamp" ]]; }

# The Xcode phase owns only generated DEV products; the signer owns the Release bundle.
mkdir -p "$release/Contents"
for flags in "" "-DCMUX_BENCH_HOOKS_OFF"; do
  stale
  run Release OTHER_SWIFT_FLAGS="$flags" CMUX_NEXT_EMBED_CMUX_REMOTE_IN_RELEASE=1 CMUX_NEXT_REQUIRE_CMUX_REMOTE=1
  if [[ "$result" == 0 && -d "$release/Contents" && ! -e "$scratch/curl.calls" ]] && gone; then
    pass "Release retains its own helper and skips DEV"
  else fail "Release loaded the DEV asset"; fi
done

for config in Debug bench; do
  flags=""
  if [[ "$config" == bench ]]; then config=Release; flags="$bench_flags"; fi
  stale
  run "$config" OTHER_SWIFT_FLAGS="$flags"
  if [[ "$result" == 0 && "$output" == *"no pin file"* ]] && gone; then pass "missing optional pin"; else fail "missing optional pin"; fi
  run "$config" OTHER_SWIFT_FLAGS="$flags" CMUX_NEXT_REQUIRE_CMUX_REMOTE=1
  if [[ "$result" != 0 && "$output" == *"requires pin file"* ]]; then pass "missing required pin"; else fail "missing required pin"; fi
done

write_pin() {
  printf '{"asset":"%s","sha256":"%s","arch":"arm64","bundle_id":"%s"}\n' "$asset" "$1" "$2" > "$scratch/pin.json"
}
printf 'signed zip stand-in\n' > "$scratch/zip"
sha="$(shasum -a 256 "$scratch/zip" | awk '{print $1}')"
write_pin "$sha" com.cmuxterm.remote.dev
stale
run Debug CMUX_CUA_ASSET_FILE="$scratch/zip"
if [[ "$result" == 0 && "$(warnings)" == 1 && ! -e "$scratch/ditto.calls" ]] && gone; then
  pass "the obsolete DEV pin stays out of optional builds"
else fail "obsolete DEV pin remained in the build"; fi
run Debug CMUX_NEXT_REQUIRE_CMUX_REMOTE=1 CMUX_CUA_ASSET_FILE="$scratch/zip"
if [[ "$result" != 0 && "$output" == *"expected com.cmuxterm.cua.dev"* && ! -e "$scratch/ditto.calls" ]]; then
  pass "old signed artifact rejected before unpacking"
else fail "old signed artifact reached the new helper"; fi

write_pin "$sha" com.cmuxterm.cua.dev
stale
run Debug
if [[ "$result" == 0 && "$(warnings)" == 1 ]] && gone; then pass "missing optional asset"; else fail "missing optional asset"; fi
run Debug CMUX_NEXT_REQUIRE_CMUX_REMOTE=1
if [[ "$result" != 0 && "$output" == *"pin.json unavailable"* ]]; then pass "missing required asset"; else fail "missing required asset"; fi

printf 'wrong zip\n' > "$scratch/wrong.zip"
run Debug CMUX_CUA_ASSET_FILE="$scratch/wrong.zip"
if [[ "$result" != 0 && "$output" == *"sha256"* && ! -e "$scratch/ditto.calls" ]]; then pass "different bytes refused"; else fail "different bytes accepted"; fi
for config in Debug bench; do
  flags=""
  if [[ "$config" == bench ]]; then config=Release; flags="$bench_flags"; fi
  : > "$scratch/ditto.calls"
  run "$config" OTHER_SWIFT_FLAGS="$flags" CMUX_CUA_ASSET_FILE="$scratch/zip"
  if [[ "$result" != 0 && "$output" == *"has no cmux Computer Use (dev).app"* && -s "$scratch/ditto.calls" ]]; then
    pass "verified asset unpacked into staging and checked for the new helper"
  else fail "verified asset selection"; fi
done
# A download can return successfully with incorrect bytes; the pin still decides.
printf 'downloaded archive stand-in\n' > "$scratch/fetched.zip"
sha="$(shasum -a 256 "$scratch/fetched.zip" | awk '{print $1}')"
printf '{"asset":"%s","sha256":"%s","arch":"arm64","bundle_id":"com.cmuxterm.cua.dev","r2_bucket":"bucket","r2_key":"objects/%s"}\n' \
  "$asset" "$sha" "$asset" > "$scratch/pin.json"
credentials=(CMUX_CEF_R2_ACCESS_KEY_ID=stand-in CMUX_CEF_R2_SECRET_ACCESS_KEY=stand-in CMUX_CEF_R2_ENDPOINT=https://store.invalid)
cp "$scratch/wrong.zip" "$scratch/remote.zip"
run Debug "${credentials[@]}"
if [[ "$result" != 0 && "$output" == *"sha256 mismatch"* ]]; then pass "wrong downloaded bytes refused"; else fail "wrong downloaded bytes accepted"; fi
cp "$scratch/fetched.zip" "$scratch/remote.zip"
: > "$scratch/ditto.calls"
run Debug "${credentials[@]}"
if [[ "$result" != 0 && "$output" == *"has no cmux Computer Use (dev).app"* && -s "$scratch/ditto.calls" ]]; then
  pass "correct downloaded bytes reach bundle verification"
else fail "correct downloaded bytes discarded"; fi

[[ "$failed" == 0 ]]
