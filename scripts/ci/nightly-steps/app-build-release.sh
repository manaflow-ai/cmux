#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Build nightly app (Release)". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
# cx-f58x: compile out browser-import code as `decide` chose (the
# notary tests, and every nightly-next build while
# NIGHTLY_NEXT_BROWSER_DATA_IMPORT=compiled-out).
echo "browser import variant: $IMPORT_VARIANT (flags: ${SWIFT_IMPORT_FLAGS:-none}, empty browser-sources.json: $EMPTY_BROWSER_SOURCES)"
notary_test_flags=(build)
if [[ "$EMPTY_BROWSER_SOURCES" == true ]]; then
  printf '%s\n' '{"schemaVersion": 1, "engines": {}, "browsers": []}' \
    > Packages/macOS/CmuxNext/Sources/CmuxNextBrowserImport/Resources/browser-sources.json
fi
swift_defines=""
if [[ -n "$SWIFT_IMPORT_FLAGS" ]]; then
  [[ "$SWIFT_IMPORT_FLAGS" =~ ^(-DCMUX_NO_[A-Z_]+ ?)+$ ]] || { echo "unexpected import flags: $SWIFT_IMPORT_FLAGS" >&2; exit 1; }
  swift_defines="$SWIFT_IMPORT_FLAGS"
fi
if [[ "${BUILD_TRACK:-}" == nightly-next ]]; then
  # cmux NEXT Nightly carries the main-thread blocking detector, record only
  # (scripts/cmux-next/lib/nightly-swift-defines.sh, plans/cmux-next/threading-model.md).
  # shellcheck source=scripts/cmux-next/lib/nightly-swift-defines.sh
  source scripts/cmux-next/lib/nightly-swift-defines.sh
  swift_defines="${swift_defines:+$swift_defines }$CMUX_NIGHTLY_NEXT_SWIFT_DEFINES"
fi
if [[ -n "$swift_defines" ]]; then
  echo "OTHER_SWIFT_FLAGS defines: $swift_defines"
  # shellcheck disable=SC2016 # $(inherited) is an Xcode build setting, not a shell expansion
  notary_test_flags=("OTHER_SWIFT_FLAGS=\$(inherited) $swift_defines" build)
fi
if [[ "$NIGHTLY_COMPILE_ARCHS" == "arm64" ]]; then
  archs="arm64"
  only_active="YES"
else
  archs="arm64 x86_64"
  only_active="NO"
fi
# No -jobs 1: the two whole-module Swift compiles ran back to back (#12704).
# The Rust helper phases are prebuilt beside the compile at low priority;
# a failed prebuild leaves the work to the phases. Cargo, rustup and CEF
# roots come from the job's HOME so the bytes match a Blacksmith build
# (build 74986f8b recorded /Users/cmux paths).
if [ "${BUILD_TRACK:-}" = nightly-next ]; then
  export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
  export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
  CMUX_CEF_CACHE_DIR="${CMUX_CEF_CACHE_DIR:-$(scripts/cmux-next/cef-cache-root.sh)}"
  export CMUX_CEF_CACHE_DIR
fi
# Bundle cmux-tui bundles none (deferred): "Bundle the fast cmux-tui client"
# or build-sign-notarize-nightly's "Bundle the cmux-tui client" installs
# this tree's client (install-cmux-tui-client.sh).
# Reuse the managed fleet CAS; unavailable nodes keep the local cache.
fleet_cache_settings=()
local_cache_settings=()
while IFS= read -r setting; do
  fleet_cache_settings+=("$setting")
  case "$setting" in
    COMPILATION_CACHE_CAS_PATH=*|COMPILATION_CACHE_ENABLE_PLUGIN=*|COMPILATION_CACHE_REMOTE_SERVICE_PATH=*) ;;
    *) local_cache_settings+=("$setting") ;;
  esac
done < <(CMUX_CI_DISABLE_COMPILATION_CACHE="${DECIDE_COLD_CACHE_DISABLE}" bash scripts/ci/fleet-compilation-cache.sh)
# Keep retry classification identical to the other Release compile
# paths: only compiler diagnostics that identify the CAS/cache as
# failing may fall back to a local cache.
# shellcheck source=scripts/cmux-next/lib/compilation-cache.sh
source scripts/cmux-next/lib/compilation-cache.sh
run_release_build() {
  local disable_fleet_cache="${1:-0}"
  local settings=()
  if [[ "$disable_fleet_cache" != 1 ]]; then
    settings=("${fleet_cache_settings[@]}")
  else
    settings=("${local_cache_settings[@]}")
  fi
  python3 scripts/ci/run-with-helper-prebuild.py \
    --derived-data build-universal --configuration Release --archs "$archs" \
    --log "$RUNNER_TEMP/helper-prebuild.log" -- \
  ./scripts/ci/run-xcodebuild-with-diagnostics.sh -- \
    env CMUX_NEXT_TUI_MODE=deferred CMUX_SKIP_ZIG_BUILD=1 xcodebuild -scheme cmux -configuration Release -derivedDataPath build-universal \
    -destination 'generic/platform=macOS' \
    -clonedSourcePackagesDirPath .spm-cache \
    -packageCachePath "$PWD/.spm-cache/.package-cache" \
    -showBuildTimingSummary \
    ARCHS="$archs" \
    ONLY_ACTIVE_ARCH="$only_active" \
    COMPILATION_CACHE_ENABLE_CACHING=YES \
    COMPILATION_CACHE_LIMIT_SIZE=3221225472 \
    ${settings[@]+"${settings[@]}"} \
    COMPILER_INDEX_STORE_ENABLE=NO \
    CODE_SIGNING_ALLOWED=NO ASSETCATALOG_COMPILER_APPICON_NAME="$CHANNEL_ICON_NAME" \
    "${notary_test_flags[@]}"
}
# A live CAS failure is recoverable: preserve the build's incremental inputs,
# then retry once with Xcode's local cache. Other compile failures remain red.
set +e
run_release_build 0 2>&1 | tee "$RUNNER_TEMP/nightly-release-build.log"
release_status=${PIPESTATUS[0]}
set -e
if [[ "$release_status" -ne 0 ]] && cmux_next_runtime_cas_failed "$RUNNER_TEMP/nightly-release-build.log"; then
  echo "::warning::managed fleet compilation cache failed; retrying the Release build with the local cache"
  run_release_build 1
else
  exit "$release_status"
fi
