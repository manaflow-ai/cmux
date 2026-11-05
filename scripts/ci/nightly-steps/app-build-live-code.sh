#!/usr/bin/env bash
# The live code variant of the nightly app (docs/cmux-next/live-code.md): the same Release build as
# app-build-release.sh, with the nightly's own flags (decide's -DCMUX_NO_* import defines, the
# nightly-next defines), plus the live code settings for every CmuxNext target
# (scripts/live-code/lib/xcodebuild-args.sh). Two passes, as scripts/live-code/build.sh:
#   1. build and link; list the app's exported CmuxNext symbols (live_code_list);
#   2. the same build with that list made interposable (only the link reruns);
# then live_code_check writes binds, exports, missing and cost.json, and fails the build when the
# relinked app binds a CmuxNext symbol it does not export (dyld would stop the launch).
#   app-build-live-code.sh OUT
# The step's env is app-build-release.sh's (IMPORT_VARIANT, SWIFT_IMPORT_FLAGS, EMPTY_BROWSER_SOURCES,
# BUILD_TRACK, NIGHTLY_COMPILE_ARCHS, CHANNEL_ICON_NAME, RUNNER_TEMP). The variant never touches the
# nightly's kept build state: no host build root, and no fleet compilation cache (its -Onone entries
# would push the nightly's out of the size-capped cache). OUT gets xcodebuild.log (pass 1, which
# scripts/live-code/patch.py compiles patches from), interposable.txt, cost.json and app-path.
set -euo pipefail
out="$(mkdir -p "${1:?usage: app-build-live-code.sh OUT}" && cd "$1" && pwd)"
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
# shellcheck source=scripts/live-code/lib/two-pass.sh
source scripts/live-code/lib/two-pass.sh
export CMUX_LIVE_CODE_BUILD=1 CMUX_NIGHTLY_HOST_BUILD_ROOT=0 DECIDE_COLD_CACHE_DISABLE=1
unset CMUX_LIVE_CODE_INTERPOSABLE_LIST
app="$PWD/build-universal/Build/Products/Release/cmux.app"
bin="$app/Contents/MacOS/cmux"
start=$SECONDS
bash scripts/ci/nightly-steps/app-build-release.sh
cp "$RUNNER_TEMP/nightly-release-build.log" "$out/xcodebuild.log"
[[ -f "$bin" ]] || { echo "live-code variant: pass 1 left no $bin" >&2; exit 1; }
live_code_list "$bin" "$out"
CMUX_LIVE_CODE_INTERPOSABLE_LIST="$out/interposable.txt" bash scripts/ci/nightly-steps/app-build-release.sh
cp "$RUNNER_TEMP/nightly-release-build.log" "$out/xcodebuild-relink.log"
live_code_check "$bin" "$out" || { echo "::error title=live code variant::the relinked app binds CmuxNext symbols it does not export, or no bind was read; see $out/missing-2.txt" >&2; exit 1; }
echo "live-code variant: built in $((SECONDS - start)) s"
printf '%s\n' "$app" > "$out/app-path"
echo "$app"
