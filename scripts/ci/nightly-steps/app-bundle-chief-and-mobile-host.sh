#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Bundle the OptChat Chief and the iPhone host". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
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
python3 scripts/ci/background_build.py join --state "$state" mobile-host
env "${phase_env[@]}" CMUX_NEXT_MOBILE_HOST_BIN="${CMUX_NEXT_MOBILE_HOST_PENDING_BIN:?}" \
  CMUX_NEXT_REQUIRE_MOBILE_HOST=1 scripts/cmux-next/bundle-mobile-host.sh
