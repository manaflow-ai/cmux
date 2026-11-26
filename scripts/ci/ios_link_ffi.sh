#!/usr/bin/env bash
# CmuxMobileLinkFFI.xcframework for the `ios` job's steps (ci/steps.toml ios-kit and ios-phone-cells) on a pull
# request: the build fleet's copy of the pull request head when it has the same FFI inputs as the merge commit, else
# this Mac builds it with cmux-next-ios/rust/scripts/build-xcframework.sh as before. pr-pipeline.yml's
# ios-ffi-fleet job submits the same fleet build (one request key per commit) while this job still waits for a Mac,
# so the copy is usually ready when the step starts.
#
# The fleet's build passes only when the bindings it generates match the checked-in CmuxMobileLinkFFI.swift, and the
# key (scripts/ci/ios_link_ffi_key.py) names those bindings, so a fleet copy has passed the drift check the Mac build
# makes. A fleet copy is marked with its key (in RUNNER_TEMP): the job's next step reuses it instead of building again
# (the cargo target a Mac build would reuse is cold then). Every path that is not the fleet copy is a logged
# "Mac fallback". CI_IOS_FFI_FLEET=0 turns the fleet off.
#
#   scripts/ci/ios_link_ffi.sh [JOBS]
set -uo pipefail

jobs="${1:-8}"
dest=cmux-next-ios/CmuxMobileKit/Frameworks
xcf="$dest/CmuxMobileLinkFFI.xcframework"
tmp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
mark="$tmp/link-ffi-fleet.key"  # this job's steps only
key="$(python3 -I scripts/ci/ios_link_ffi_key.py 2>/dev/null)" || key=""

mac_build() {
  echo "::notice title=Mac fallback::CmuxMobileLinkFFI.xcframework built on this Mac: $1"
  rm -f "$mark"
  JOBS="$jobs" bash cmux-next-ios/rust/scripts/build-xcframework.sh
}

if [[ -n "$key" && -f "$mark" && "$(cat "$mark")" == "$key" && -f "$xcf/Info.plist" ]]; then
  echo "CmuxMobileLinkFFI.xcframework: the build fleet's copy from an earlier step, same inputs"
  exit 0
fi
rm -f "$mark"

[[ "${CI_IOS_FFI_FLEET:-1}" != 0 ]] || { mac_build "the build fleet is off (CI_IOS_FFI_FLEET=0)"; exit; }
[[ "${RUNNER_NAME:-}" != blacksmith* ]] || { mac_build "a hosted runner"; exit; }
client="${CMUX_CI_CLIENT:-$HOME/.local/bin/cmux-ci}"
[[ -x "$client" ]] || { mac_build "no build fleet client on ${RUNNER_NAME:-this runner}"; exit; }
[[ -n "$key" ]] || { mac_build "no input key"; exit; }
# The fleet builds a pushed commit: the pull request head (the merge commit's second parent).
head="$(git rev-parse -q --verify 'HEAD^2' 2>/dev/null || git rev-parse HEAD)"
head_key="$(python3 -I scripts/ci/ios_link_ffi_key.py --ref "$head" 2>/dev/null)" || head_key=""
[[ "$head_key" == "$key" ]] || { mac_build "the base changed the FFI inputs since the head"; exit; }

out="$tmp/link-ffi-fleet"
rm -rf "$out"
start=$SECONDS
status=0
# Queued: at most 2 min (a Mac build takes 3-5). Running: at most 8 min, or the Mac builds it.
"$client" ios-build --what ffi --ref "$head" --out "$out" --timeout 480 --queue-timeout 120 || status=$?
if [[ "$status" != 0 || ! -f "$out/CmuxMobileLinkFFI.xcframework/Info.plist" ]]; then
  mac_build "no copy from the build fleet (exit $status)"
  exit
fi
mkdir -p "$dest"
rm -rf "$xcf"
cp -R "$out/CmuxMobileLinkFFI.xcframework" "$dest/"
printf '%s\n' "$key" > "$mark"
echo "fleet-built xcframework after $((SECONDS - start)) s"
