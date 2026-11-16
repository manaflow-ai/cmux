#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Portable regression for the missing Remote bundle in Release. No signing, network, or credentials.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL: $1" >&2; echo "$output" >&2; exit 1; }
run() {
  set +e
  output="$(env -i PATH=/usr/bin:/bin HOME="$scratch" ARCHS=arm64 CONFIGURATION="$1" \
    TARGET_BUILD_DIR="$scratch/build" TARGET_TEMP_DIR="$scratch/temp" WRAPPER_NAME=cmux.app \
    CMUX_NEXT_CMUX_REMOTE_PIN="$scratch/pin.json" CMUX_CUA_ASSET_CACHE_DIR="$scratch/cache" \
    CMUX_CUA_ASSET_NO_STORE=1 CMUX_CEF_R2_ENV_FILE=/dev/null \
    /bin/bash "$root/scripts/cmux-next/embed-cmux-remote-dev.sh" 2>&1)"
  result=$?
  set -e
}
run Release
[[ "$result" != 0 && "$output" == *"requires pin file"* ]] || fail "Release accepted a missing pin"
run Debug
[[ "$result" == 0 && "$output" == *"not embedding"* ]] || fail "Debug lost its optional local-build path"
printf '{"asset":"cmux-remote-dev-macos-arm64.zip","sha256":"%064d","arch":"arm64"}\n' 0 > "$scratch/pin.json"
run Release
[[ "$result" != 0 && "$output" == *"unavailable"* ]] || fail "Release accepted a missing Remote asset"
run Debug
[[ "$result" == 0 && "$output" == *"not embedding"* ]] || fail "Debug missing-asset behavior changed"
echo "embed-cmux-remote-dev.test.sh: passed (missing Release pin/asset fail; optional DEV preserved)"
