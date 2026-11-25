#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Bundle the OptChat Chief and the iPhone host". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# The Chief and the iPhone host built beside the Release build. Their Xcode
# phases found no CMUX_NEXT_*_BIN and bundled nothing; this joins each
# background build (a failed one fails here) and runs the same phase
# script on the built app, with the variables Xcode gave it, so the copy,
# its checks and Resources/bin are what the phase made before.
set -euo pipefail
state="$RUNNER_TEMP/nightly-helper-builds"
if [[ "$NIGHTLY_COMPILE_ARCHS" == "arm64" ]]; then archs="arm64"; else archs="arm64 x86_64"; fi
phase_env=(SRCROOT="$PWD" CONFIGURATION=Release ARCHS="$archs"
  TARGET_BUILD_DIR="$PWD/build-universal/Build/Products/Release"
  UNLOCALIZED_RESOURCES_FOLDER_PATH=cmux.app/Contents/Resources
  TARGET_TEMP_DIR="$RUNNER_TEMP/nightly-helper-bundle")
[ -d "build-universal/Build/Products/Release/cmux.app/Contents/Resources" ] || { echo "no Release cmux.app to bundle into" >&2; exit 1; }
python3 scripts/ci/background_build.py join --state "$state" optchat-chief
env "${phase_env[@]}" CMUX_NEXT_OPTCHAT_CHIEF_BIN="${CMUX_NEXT_OPTCHAT_CHIEF_PENDING_BIN:?}" \
  CMUX_NEXT_REQUIRE_OPTCHAT_CHIEF=1 scripts/cmux-next/bundle-optchat-chief.sh
# The iPhone host does not hold the nightly (Leo, 2026-11-25: "are we able to decouple"): a failed build
# bundles the newest host this Mac built before (the last good artifact), or none, and says so as a stale
# part; the app still launches, and Settings > Mobile says iPhone connections are unavailable without it.
# NIGHTLY_COMPONENT_GATES=block (a repository variable) restores the old hold.
host_bin="${CMUX_NEXT_MOBILE_HOST_PENDING_BIN:?}"
if ! python3 scripts/ci/background_build.py join --state "$state" mobile-host; then
  [ "${NIGHTLY_COMPONENT_GATES:-}" != block ] || exit 1
  host_bin="$(scripts/ci/nightly-steps/last-good-mobile-host.sh "${archs// /-}" || true)"
  if [ -n "$host_bin" ]; then
    bash scripts/ci/nightly-steps/stale-part.sh cmux-mobile-host \
      "the iPhone host failed to build; bundled the last good one ($(tr '\n' ' ' < "$host_bin.ref" 2>/dev/null || echo "$host_bin"))"
  elif bash scripts/ci/nightly-steps/mobile-host-fallback.sh "$archs" "${CMUX_NEXT_MOBILE_HOST_PENDING_BIN:?}"; then
    # No earlier build on this Mac (a fresh runner): the published NIGHTLY's copy keeps iPhone connections.
    host_bin="$CMUX_NEXT_MOBILE_HOST_PENDING_BIN"
    bash scripts/ci/nightly-steps/stale-part.sh cmux-mobile-host \
      "the iPhone host failed to build; bundled the published NIGHTLY's ($(tr '\n' ' ' < "$host_bin.ref"))"
  else
    bash scripts/ci/nightly-steps/stale-part.sh cmux-mobile-host \
      "the iPhone host failed to build and neither this Mac nor the published NIGHTLY has one; the nightly ships without iPhone connections"
  fi
fi
if [ -n "$host_bin" ]; then
  env "${phase_env[@]}" CMUX_NEXT_MOBILE_HOST_BIN="$host_bin" \
    CMUX_NEXT_REQUIRE_MOBILE_HOST=1 scripts/cmux-next/bundle-mobile-host.sh
fi
python3 scripts/ci/background_build.py join --state "$state" screen-sharing-helper
env "${phase_env[@]}" CMUX_NEXT_SCREEN_HELPER_BIN="${CMUX_NEXT_SCREEN_HELPER_PENDING_BIN:?}" \
  CMUX_NEXT_REQUIRE_SCREEN_HELPER=1 scripts/cmux-next/bundle-screen-sharing-helper.sh
