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
# The iPhone host and the Screen Sharing helper are separate executables the app runs on demand, so on the
# nightly a red build of either no longer stops the Mac app from publishing (Leo, 11-25, after
# cmux-mobile-link's E0063 failed run 45556730650: "are we able to decouple"). Each green build is kept
# per runner and arch set; a failed one bundles the last green copy, says so as a ::warning::
# and in the step summary, and the next green build replaces it. The Chief stays strict
# (chat runs through it). release.yml stays strict too (no GITHUB_WORKFLOW_REF match), and a runner with no
# kept copy fails as before.
last_good_root=""
if [[ "${GITHUB_WORKFLOW_REF:-}" == */.github/workflows/nightly.yml@* ]]; then
  last_good_root="${CMUX_NIGHTLY_HELPER_LAST_GOOD_DIR:-$HOME/Library/Caches/cmux-nightly-next/helper-last-good}/${archs// /-}"
fi
helper_or_last_good() {  # NAME PENDING_BIN: prints the binary to bundle
  local name="$1" pending="$2" kept
  if python3 scripts/ci/background_build.py join --state "$state" "$name" >&2; then
    if [[ -n "$last_good_root" && -f "$pending" ]]; then
      mkdir -p "$last_good_root/$name"
      kept="$last_good_root/$name/$(basename "$pending")"
      cp -f "$pending" "$kept.tmp" && mv -f "$kept.tmp" "$kept"
      cp -f "$pending.ref" "$kept.ref" 2>/dev/null || rm -f "$kept.ref"
    fi
    printf '%s\n' "$pending"
    return 0
  fi
  kept="$last_good_root/$name/$(basename "$pending")"
  if [[ -n "$last_good_root" && -f "$kept" ]]; then
    local from; from="$(cat "$kept.ref" 2>/dev/null || stat -f %Sm "$kept" 2>/dev/null || echo unknown)"
    echo "::warning title=$name build failed::bundling the last green $name ($from) so the nightly still publishes; fix the build, the next green one replaces it" >&2
    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && printf -- '- %s: build failed, bundled the last green copy (%s)\n' "$name" "$from" >> "$GITHUB_STEP_SUMMARY"
    printf '%s\n' "$kept"
    return 0
  fi
  echo "error: $name failed and this runner keeps no green copy (${last_good_root:-not the nightly}); failing as before" >&2
  return 1
}
[ -d "build-universal/Build/Products/Release/cmux.app/Contents/Resources" ] || { echo "no Release cmux.app to bundle into" >&2; exit 1; }
python3 scripts/ci/background_build.py join --state "$state" optchat-chief
env "${phase_env[@]}" CMUX_NEXT_OPTCHAT_CHIEF_BIN="${CMUX_NEXT_OPTCHAT_CHIEF_PENDING_BIN:?}" \
  CMUX_NEXT_REQUIRE_OPTCHAT_CHIEF=1 scripts/cmux-next/bundle-optchat-chief.sh
mobile_host_bin="$(helper_or_last_good mobile-host "${CMUX_NEXT_MOBILE_HOST_PENDING_BIN:?}")"
env "${phase_env[@]}" CMUX_NEXT_MOBILE_HOST_BIN="$mobile_host_bin" \
  CMUX_NEXT_REQUIRE_MOBILE_HOST=1 scripts/cmux-next/bundle-mobile-host.sh
screen_helper_bin="$(helper_or_last_good screen-sharing-helper "${CMUX_NEXT_SCREEN_HELPER_PENDING_BIN:?}")"
env "${phase_env[@]}" CMUX_NEXT_SCREEN_HELPER_BIN="$screen_helper_bin" \
  CMUX_NEXT_REQUIRE_SCREEN_HELPER=1 scripts/cmux-next/bundle-screen-sharing-helper.sh
