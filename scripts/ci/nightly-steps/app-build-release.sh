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
# The live code variant (app-build-live-code.sh): every CmuxNext target unoptimized, testable and a
# file at a time, linked with its symbols exported (and, on the relink, the listed ones interposable).
# Its Swift defines join the nightly's in the one OTHER_SWIFT_FLAGS, so the -DCMUX_NO_* defines stay.
live_code_args=()
if [[ "${CMUX_LIVE_CODE_BUILD:-0}" == 1 ]]; then
  # shellcheck source=scripts/live-code/lib/xcodebuild-args.sh
  source scripts/live-code/lib/xcodebuild-args.sh
  live_flags="$(live_code_swift_flags)"
  swift_defines="${swift_defines:+$swift_defines }$live_flags"
  while IFS= read -r setting; do
    case "$setting" in
      OTHER_SWIFT_FLAGS=*) ;;
      ?*) live_code_args+=("$setting") ;;
    esac
  done < <(live_code_xcodebuild_args Release "${CMUX_LIVE_CODE_INTERPOSABLE_LIST:-}")
  echo "live code variant: ${#live_code_args[@]} xcodebuild settings${CMUX_LIVE_CODE_INTERPOSABLE_LIST:+, interposable as listed in $CMUX_LIVE_CODE_INTERPOSABLE_LIST}"
fi
if [[ -n "$swift_defines" ]]; then
  echo "OTHER_SWIFT_FLAGS defines: $swift_defines"
  # shellcheck disable=SC2016 # $(inherited) is an Xcode build setting, not a shell expansion
  notary_test_flags=("OTHER_SWIFT_FLAGS=\$(inherited) $swift_defines" build)
fi
notary_test_flags=(${live_code_args[@]+"${live_code_args[@]}"} "${notary_test_flags[@]}")
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
# Which cache the first build uses, for the job summary (release-build-summary.sh).
if [[ "${DECIDE_COLD_CACHE_DISABLE:-}" == 1 ]]; then
  build_cache=cold
elif [[ " ${fleet_cache_settings[*]} " == *" COMPILATION_CACHE_REMOTE_SERVICE_PATH="* ]]; then
  build_cache=fleet
else
  build_cache=unavailable
fi
# Keep retry classification identical to the other Release compile
# paths: only compiler diagnostics that identify the CAS/cache as
# failing may fall back to a local cache.
# shellcheck source=scripts/cmux-next/lib/compilation-cache.sh
source scripts/cmux-next/lib/compilation-cache.sh
# The CAS size limit. The CAS starts a new primary generation whenever one ends a build above half
# the limit and keeps one generation behind it, so with 3 GiB (1.5 GiB per generation, under one
# build's 3.3 GB) every build rotated and two builds of other keys emptied it (16 nightly-next runs,
# 2026-11-02). 10 GiB keeps about three builds when the CAS's volume has room for it beside the
# build root and the nightly's other work (60 GiB free); glaeda's prune empties a CAS past 20 GiB.
cas_limit_bytes=3221225472
cas_dir=/Users/Shared
for setting in "${fleet_cache_settings[@]}"; do
  case "$setting" in COMPILATION_CACHE_CAS_PATH=*) cas_dir="${setting#*=}" ;; esac
done
while [[ ! -d "$cas_dir" && "$cas_dir" == /?* ]]; do cas_dir="${cas_dir%/*}"; done
cas_free_kib="$(df -Pk "${cas_dir:-/}" 2>/dev/null | awk 'NR==2 {print $4}')" || cas_free_kib=""
if [[ "${BUILD_TRACK:-}" == nightly-next && "$cas_free_kib" =~ ^[0-9]+$ ]] && (( cas_free_kib >= 60 * 1024 * 1024 )); then
  cas_limit_bytes=10737418240
fi
echo "compilation cache limit: $cas_limit_bytes bytes (${cas_free_kib:-unknown} KiB free under ${cas_dir:-/})" >&2
# One build root per nightly Mac when this slot keeps build state (app-host-build-root.sh).
# shellcheck source=scripts/ci/nightly-steps/app-host-build-root.sh
source scripts/ci/nightly-steps/app-host-build-root.sh
run_release_build() (
  local disable_fleet_cache="${1:-0}"
  local settings=()
  if [[ "$disable_fleet_cache" != 1 ]]; then
    settings=("${fleet_cache_settings[@]}")
  else
    settings=("${local_cache_settings[@]}")
  fi
  cd "$build_root"
  python3 scripts/ci/run-with-helper-prebuild.py \
    --derived-data "$derived_data" --configuration Release --archs "$archs" \
    --log "$RUNNER_TEMP/helper-prebuild.log" -- \
  ./scripts/ci/run-xcodebuild-with-diagnostics.sh -- \
    env CMUX_NEXT_TUI_MODE=deferred CMUX_SKIP_ZIG_BUILD=1 xcodebuild -scheme cmux -configuration Release -derivedDataPath "$derived_data" \
    -destination 'generic/platform=macOS' \
    -clonedSourcePackagesDirPath .spm-cache \
    -packageCachePath "$PWD/.spm-cache/.package-cache" \
    -showBuildTimingSummary \
    ARCHS="$archs" \
    ONLY_ACTIVE_ARCH="$only_active" \
    COMPILATION_CACHE_ENABLE_CACHING=YES \
    COMPILATION_CACHE_LIMIT_SIZE="$cas_limit_bytes" \
    ${settings[@]+"${settings[@]}"} \
    COMPILER_INDEX_STORE_ENABLE=NO \
    CODE_SIGNING_ALLOWED=NO ASSETCATALOG_COMPILER_APPICON_NAME="$CHANNEL_ICON_NAME" \
    "${notary_test_flags[@]}"
)
# The job summary's build lines (LOG CACHE). They never fail the build, and a tree without the helper (a test
# harness that copies only the helpers it knows) skips them.
summarize_release_build() {
  [[ -f scripts/ci/nightly-steps/release-build-summary.sh ]] && bash scripts/ci/nightly-steps/release-build-summary.sh "$@" || true
}
# The host root's products go to this workspace while the lock is still held.
finish_host_build() {
  [[ -z "$host_root" ]] || python3 scripts/ci/nightly_build_state.py finish-host "$host_root"
}
# A live CAS failure is recoverable: preserve the build's incremental inputs,
# then retry once with Xcode's local cache. Other compile failures remain red.
set +e
run_release_build 0 2>&1 | tee "$RUNNER_TEMP/nightly-release-build.log"
release_status=${PIPESTATUS[0]}
set -e
if [[ "$release_status" -ne 0 ]] && cmux_next_runtime_cas_failed "$RUNNER_TEMP/nightly-release-build.log"; then
  echo "::warning::managed fleet compilation cache failed; retrying the Release build with the local cache"
  run_release_build 1 2>&1 | tee "$RUNNER_TEMP/nightly-release-build-retry.log"
  summarize_release_build "$RUNNER_TEMP/nightly-release-build-retry.log" "$([[ $build_cache == fleet ]] && echo fallback || echo "$build_cache")"
  finish_host_build
elif [[ "$release_status" -eq 0 ]]; then
  summarize_release_build "$RUNNER_TEMP/nightly-release-build.log" "$build_cache"
  finish_host_build
else
  exit "$release_status"
fi
