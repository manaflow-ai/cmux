#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Portable regression for the missing Remote bundle: a Release build requires it; a DEV build and a
# bench build (a Release configuration with -DCMUX_BENCH_HOOKS in OTHER_SWIFT_FLAGS) warn and embed
# nothing. No signing, network, or credentials. Each case prints `ok:` or `FAIL:`; all cases run.
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
# line, with the two bench defines of lib/bench-swift-defines.sh).
bench_flags="-Xcc -fmodule-map-file=/b/GeneratedModuleMaps/CmuxNextMallocZone.modulemap -DCMUX_BENCH_HOOKS -DCMUX_BLOCKING_CHECKS"
dest="$scratch/build/cmux.app/Contents/Library/cmux Remote (dev).app"
asset="cmux-remote-dev-macos-arm64.zip"
# A stand-in for ditto: it records its arguments and unpacks nothing.
mkdir -p "$scratch/bin"
cat > "$scratch/bin/ditto" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$scratch/ditto.calls"
STUB
chmod +x "$scratch/bin/ditto"
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

# 1. No pin file.
name="Release with no pin file fails"
run Release
if [[ "$result" != 0 && "$output" == *"requires pin file"* ]]; then pass "$name"; else fail "$name"; fi
name="Debug with no pin file embeds nothing and passes"
run Debug
if [[ "$result" == 0 && "$output" == *"not embedding"* ]]; then pass "$name"; else fail "$name"; fi
name="a bench build with no pin file embeds nothing and passes"
run Release OTHER_SWIFT_FLAGS="$bench_flags"
if [[ "$result" == 0 && "$output" == *"not embedding"* ]]; then pass "$name"; else fail "$name"; fi

# 2. A pin, and the asset in no source: no cache, no store, no credentials.
printf '{"asset":"%s","sha256":"%064d","arch":"arm64"}\n' "$asset" 0 > "$scratch/pin.json"
name="Release with no asset fails"
run Release
if [[ "$result" != 0 && "$output" == *"unavailable"* ]]; then pass "$name"; else fail "$name"; fi
name="Release with other defines, and no bench define, fails with no asset"
run Release OTHER_SWIFT_FLAGS="-DCMUX_BLOCKING_CHECKS -DCMUX_BENCH_HOOKS_OFF"
if [[ "$result" != 0 && "$output" == *"unavailable"* ]]; then pass "$name"; else fail "$name"; fi
name="Debug with no asset warns one time, embeds nothing and passes"
run Debug
if [[ "$result" == 0 && "$(warnings)" == 1 && "$output" == *"not embedding"* && ! -e "$dest" ]]; then pass "$name"; else fail "$name"; fi
name="a bench build with no asset warns one time, embeds nothing and passes"
run Release OTHER_SWIFT_FLAGS="$bench_flags"
if [[ "$result" == 0 && "$(warnings)" == 1 && "$output" == *"warning: pin.json unavailable"* &&
  "$output" == *"not embedding"* && ! -e "$dest" ]]; then pass "$name"; else fail "$name"; fi
name="a bench build with CMUX_NEXT_REQUIRE_CMUX_REMOTE=1 fails with no asset"
run Release OTHER_SWIFT_FLAGS="$bench_flags" CMUX_NEXT_REQUIRE_CMUX_REMOTE=1
if [[ "$result" != 0 && "$output" == *"unavailable"* ]]; then pass "$name"; else fail "$name"; fi

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
name="Release with a cached asset goes on to unpack it"
: > "$scratch/ditto.calls"
run Release
if unpacked; then pass "$name"; else fail "$name"; fi
name="Debug with a cached asset goes on to unpack it"
: > "$scratch/ditto.calls"
run Debug
if unpacked; then pass "$name"; else fail "$name"; fi
name="a bench build with a cached asset goes on to unpack it"
: > "$scratch/ditto.calls"
run Release OTHER_SWIFT_FLAGS="$bench_flags"
if unpacked; then pass "$name"; else fail "$name"; fi

if [[ "$failed" != 0 ]]; then
  echo "embed-cmux-remote-dev.test.sh: $failed failed" >&2
  exit 1
fi
echo "embed-cmux-remote-dev.test.sh: passed (a missing Release pin or asset fails; DEV and bench stay optional)"
