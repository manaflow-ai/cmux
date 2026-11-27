#!/usr/bin/env bash
# CmuxMobileLinkFFI.xcframework for the `ios` job's steps (ci/steps.toml ios-kit and ios-phone-cells) on a pull
# request, built on the build fleet's Linux pool (cmuxterm-hq build-fleet/swift-linux-builder/pool/ios-ffi/build.sh).
# This Mac no longer builds it: the fleet build took 150 s from submit to output against the Mac build's 277 s
# (2026-11-27), and it makes the Mac build's checks (the locked fetch, each slice exports the uniffi symbols, the
# generated bindings equal the checked-in ones), so a fleet red is this step's red. The simulator typecheck and link
# the Mac build made is the steps' own kit build, which compiles those bindings and links the framework.
#
# Where: an owned Mac submits with its cmux-ci client (the pull request head when the merge commit has the same FFI
# inputs, so reruns reuse it, else the merge commit). A hosted Mac has no client and asks the controller's public
# route with the job's OIDC token (scripts/ci/fleet_ios_build.py, the run's own commit). A run with neither (a
# fork's pull request gets no OIDC token), or CI_IOS_FFI_FLEET=0, is the one Mac build left, logged "Mac fallback".
#
# A copy is marked with its input key (scripts/ci/ios_link_ffi_key.py, in RUNNER_TEMP): the job's next step with the
# same inputs reuses it instead of building again.
#
#   scripts/ci/ios_link_ffi.sh [JOBS]
set -uo pipefail

jobs="${1:-8}"
dest=cmux-next-ios/CmuxMobileKit/Frameworks
xcf="$dest/CmuxMobileLinkFFI.xcframework"
tmp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
mark="$tmp/link-ffi-fleet.key"  # this job's steps only
key="$(python3 -I scripts/ci/ios_link_ffi_key.py 2>/dev/null)" || key=""

# Only where the fleet cannot be asked (see above).
mac_build() {
  echo "::notice title=Mac fallback::CmuxMobileLinkFFI.xcframework built on this Mac: $1"
  rm -f "$mark"
  local rc=0
  JOBS="$jobs" bash cmux-next-ios/rust/scripts/build-xcframework.sh || rc=$?
  if [[ "$rc" == 0 && -n "$key" && -f "$xcf/Info.plist" ]]; then
    printf '%s\n' "$key" > "$mark"
  fi
  return "$rc"
}

if [[ -n "$key" && -f "$mark" && "$(cat "$mark")" == "$key" && -f "$xcf/Info.plist" ]]; then
  echo "CmuxMobileLinkFFI.xcframework: an earlier step's copy, same inputs"
  exit 0
fi
rm -f "$mark"

[[ "${CI_IOS_FFI_FLEET:-1}" != 0 ]] || { mac_build "the build fleet is off (CI_IOS_FFI_FLEET=0)"; exit; }
client="${CMUX_CI_CLIENT:-$HOME/.local/bin/cmux-ci}"
out="$tmp/link-ffi-fleet"
rm -rf "$out"
start=$SECONDS
status=0
# Queued: at most 10 min (the pool boots a VM for it in 1-3). Running: at most 8 (it takes 1.5-2.5).
if [[ -x "$client" ]]; then
  # The fleet builds a pushed commit: the pull request head (the merge commit's second parent) when the base left
  # the FFI inputs as they were, else the merge commit itself (GitHub serves it by SHA).
  ref="$(git rev-parse HEAD)"
  head="$(git rev-parse -q --verify 'HEAD^2' 2>/dev/null || true)"
  if [[ -n "$head" && -n "$key" ]] && [[ "$(python3 -I scripts/ci/ios_link_ffi_key.py --ref "$head" 2>/dev/null)" == "$key" ]]; then
    ref="$head"
  fi
  echo "CmuxMobileLinkFFI.xcframework: the build fleet builds $ref (cmux-ci client)"
  "$client" ios-build --what ffi --ref "$ref" --out "$out" --timeout 480 --queue-timeout 600 || status=$?
elif [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]]; then
  echo "CmuxMobileLinkFFI.xcframework: the build fleet builds this run's commit (OIDC route)"
  python3 -I scripts/ci/fleet_ios_build.py --what ffi --out "$out" --timeout 480 --queue-timeout 600 || status=$?
else
  mac_build "no build fleet client and no OIDC token on ${RUNNER_NAME:-this runner}"
  exit
fi
if [[ "$status" != 0 || ! -f "$out/CmuxMobileLinkFFI.xcframework/Info.plist" ]]; then
  if [[ "$status" == 1 ]]; then
    echo "::error title=CmuxMobileLinkFFI.xcframework::the build fleet's build failed (its reason is above). A 'bindings' failure is CmuxMobileLinkFFI.swift drift: run cmux-next-ios/rust/scripts/build-xcframework.sh and commit the result (the base autofix, scripts/ios-ffi-bindings.sh, does it too)"
  else
    echo "::error title=CmuxMobileLinkFFI.xcframework::no answer from the build fleet (exit $status). Re-run the job; CI_IOS_FFI_FLEET=0 builds it on this Mac instead"
  fi
  exit 1
fi
mkdir -p "$dest"
rm -rf "$xcf"
cp -R "$out/CmuxMobileLinkFFI.xcframework" "$dest/"
[[ -z "$key" ]] || printf '%s\n' "$key" > "$mark"
echo "fleet-built xcframework after $((SECONDS - start)) s"
