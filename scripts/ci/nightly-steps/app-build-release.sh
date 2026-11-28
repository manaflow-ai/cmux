#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Build nightly app (Release)". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
# The asset catalog compile leaves Xcode's ibtoold running, detached, with this job's environment, for about a
# minute after xcodebuild returns; nightly-next-one's check before the signing secrets then counted two of them
# (run 43431310245). This step ends the build daemons it started however it exits (refuse_stray_processes.py).
end_build_daemons_script="$PWD/scripts/ci/refuse_stray_processes.py"
end_build_daemons() {
  if [[ -n "${RUNNER_TRACKING_ID:-}" && -f "$end_build_daemons_script" ]]; then
    python3 "$end_build_daemons_script" --end-build-daemons || true
  fi
}
trap end_build_daemons EXIT
# cx-f58x: compile out browser-import code as `decide` chose (the
# notary tests, and every nightly-next build when nightly.yml sets
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
# cmux NEXT Nightly's Release Swift for size, hot targets at -O (scripts/cmux-next/lib/swift-size-opt.sh).
# The classic tracks keep their optimization, and the live code variant sets its own.
size_opt_args=()
if [[ "${BUILD_TRACK:-}" == nightly-next && "${CMUX_LIVE_CODE_BUILD:-0}" != 1 ]]; then
  # shellcheck source=scripts/cmux-next/lib/swift-size-opt.sh
  source scripts/cmux-next/lib/swift-size-opt.sh
  while IFS= read -r setting; do size_opt_args+=("$setting"); done < <(swift_size_opt_xcodebuild_args)
fi
notary_test_flags=(${size_opt_args[@]+"${size_opt_args[@]}"} ${live_code_args[@]+"${live_code_args[@]}"} "${notary_test_flags[@]}")
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
# Every binary artifact (Iroh, Sentry-Dynamic, WebRTC, CCmuxAppFFI) is in this tree's own SourcePackages before the
# build: one missing or recorded in another tree drops the artifact state and resolves again
# (spm_artifact_preflight.py). The project's local packages are read from cmux.xcodeproj, since the seeded tree
# has no workspace-state.json to name them.
# A dead or half-dead github.com egress proxy on the mini: probed first, and a resolve that failed on it runs once
# more, direct; the build below inherits the route (github-egress-direct.sh).
# shellcheck source=scripts/ci/github-egress-direct.sh
source scripts/ci/github-egress-direct.sh
github_egress_probe >&2
spm_preflight_log="$(mktemp "${RUNNER_TEMP:-/tmp}/spm-preflight.XXXXXX")"
spm_artifact_preflight() (
  cd "$build_root"
  python3 scripts/ci/spm_artifact_preflight.py .spm-cache --xcodeproj cmux.xcodeproj \
    --resolved cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved -- \
    xcodebuild -resolvePackageDependencies -scheme cmux \
    -clonedSourcePackagesDirPath .spm-cache \
    -packageCachePath "$PWD/.spm-cache/.package-cache"
)
if ! spm_artifact_preflight 2>&1 | tee "$spm_preflight_log" >&2; then
  github_egress_retry_direct "$spm_preflight_log" >&2 || { rm -f "$spm_preflight_log"; exit 1; }
  spm_artifact_preflight >&2
fi
rm -f "$spm_preflight_log"
# run_release_build 0: the fleet cache; 1: Xcode's local cache; 2: no compilation cache at all.
run_release_build() (
  local disable_fleet_cache="${1:-0}"
  local settings=()
  local caching=YES
  if [[ "$disable_fleet_cache" == 2 ]]; then
    caching=NO
  elif [[ "$disable_fleet_cache" != 1 ]]; then
    settings=("${fleet_cache_settings[@]}")
  else
    settings=("${local_cache_settings[@]}")
  fi
  cd "$build_root"
  python3 scripts/ci/run-with-helper-prebuild.py \
    --derived-data "$derived_data" --configuration Release --archs "$archs" \
    --log "$RUNNER_TEMP/helper-prebuild.log" -- \
  ./scripts/ci/run-xcodebuild-with-diagnostics.sh -- \
    env CMUX_NEXT_TUI_MODE=deferred CMUX_SKIP_ZIG_BUILD=1 xcodebuild -skipPackagePluginValidation -scheme cmux -configuration Release -derivedDataPath "$derived_data" \
    -destination 'generic/platform=macOS' \
    -clonedSourcePackagesDirPath .spm-cache \
    -packageCachePath "$PWD/.spm-cache/.package-cache" \
    -showBuildTimingSummary \
    ARCHS="$archs" \
    ONLY_ACTIVE_ARCH="$only_active" \
    COMPILATION_CACHE_ENABLE_CACHING="$caching" \
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
# A build xcodebuild ended with a failure (status 65) lets the next one build on what it finished, once
# (nightly_build_state.py fail_host); any other status leaves the build unfinished, so the next one is clean.
fail_host_build() {
  [[ -z "$host_root" ]] || python3 scripts/ci/nightly_build_state.py fail-host "$host_root" "$1" || true
}
# The stall window for this build: 8 min, not the wrapper's 15. Six healthy nightly-next-one Release builds on
# 2026-11-15 (both nightly Macs, Xcode 26.6, clean DerivedData, 127 to 367 s) went at most 27 s without an
# xcodebuild line; run 43673773157's deadlock went silent about a minute in. The CPU condition still has to hold.
export CMUX_XCODEBUILD_STALL_SECONDS="${CMUX_XCODEBUILD_STALL_SECONDS:-480}"
# Where run-xcodebuild-with-diagnostics.sh keeps a stalled build's `sample` of its build service: on the host,
# outside RUNNER_TEMP (the runner empties that at the next job), one folder per run attempt, the last 30 days.
if [[ -z "${CMUX_XCODEBUILD_STALL_DIR:-}" ]]; then
  stall_root="$HOME/Library/Logs/cmux-ci/xcodebuild-stall"
  find "$stall_root" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} + 2>/dev/null || true
  export CMUX_XCODEBUILD_STALL_DIR="$stall_root/${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${GITHUB_JOB:-job}"
fi
# A build on the fleet cache that fails for any reason retries once with Xcode's local cache, keeping the
# build's incremental inputs. The fleet cache has failed in one form after another (a corrupt object, a missing
# module key, a precompile's "CAS operation failed", a compiler crash reading the CAS; runs 42100189059,
# 42524304475, 42527779911, 42535989825), and matching each error's text lost to the next form. A real
# compile error fails the retry the same way, so it costs at most one extra build, on a nightly that is red
# anyway. A build without the fleet cache retries only on a runtime CAS diagnostic, as before.
set +e
run_release_build 0 2>&1 | tee "$RUNNER_TEMP/nightly-release-build.log"
release_status=${PIPESTATUS[0]}
set -e
release_retry=""
retry_mode=1
# Status 124: run-xcodebuild-with-diagnostics.sh ended a build that had stopped. In run 43673773157 the build
# service deadlocked and held the nightly-next slot for hours. A new build service gets one more try.
if [[ "$release_status" -eq 124 ]]; then
  release_retry="the Release build stalled (no output and no CPU use), so the wrapper ended it"
elif [[ "$release_status" -ne 0 && "$build_cache" == fleet ]]; then
  release_retry="the Release build failed on the managed fleet compilation cache"
elif [[ "$release_status" -ne 0 ]] && cmux_next_runtime_cas_failed "$RUNNER_TEMP/nightly-release-build.log"; then
  release_retry="the compilation cache failed"
# Xcode's build service crashed ("Build again to continue"; run 46020152626): a compile error never
# prints that line, so the retry is one more build with a new build service, not a masked red.
elif [[ "$release_status" -ne 0 ]] && cmux_next_build_service_crashed "$RUNNER_TEMP/nightly-release-build.log"; then
  release_retry="Xcode's build service crashed"
fi
# Xcode 27.2's build service crashes replaying a cached compile's diagnostics (swiftscan_cache_replay_compilation >
# replayCachedDiagnostics > bad_optional_access), on the local cache as on the fleet one: nightly-next runs
# 46024218260, 46026219141 and 46033303025, the last after its local CAS was emptied. A cached retry replays the
# same entries, so a crashed build service's retry, whichever cache the first build used, builds without one.
if [[ -n "$release_retry" ]] && cmux_next_build_service_crashed "$RUNNER_TEMP/nightly-release-build.log"; then
  retry_mode=2
fi
if [[ -n "$release_retry" ]]; then
  echo "::warning::$release_retry (status $release_status); retrying the Release build once $([[ $retry_mode == 2 ]] && echo 'without the compilation cache' || echo 'with the local cache')"
  # The one retry. Its failure ends the step red; there is no third build.
  set +e
  run_release_build "$retry_mode" 2>&1 | tee "$RUNNER_TEMP/nightly-release-build-retry.log"
  retry_status=${PIPESTATUS[0]}
  set -e
  if [[ "$retry_status" -eq 124 ]]; then
    stall_samples="$(find "$CMUX_XCODEBUILD_STALL_DIR" -name '*.sample.txt' 2>/dev/null | sort | paste -sd' ' - || true)"
    echo "::error::the Release build stalled again on its retry, with a new build service; the build service's stacks: ${stall_samples:-none taken (see $CMUX_XCODEBUILD_STALL_DIR)}"
  fi
  [[ "$retry_status" -eq 0 ]] || { fail_host_build "$retry_status"; exit "$retry_status"; }
  summarize_release_build "$RUNNER_TEMP/nightly-release-build-retry.log" "$([[ $build_cache == fleet ]] && echo fallback || echo "$build_cache")"
  finish_host_build
elif [[ "$release_status" -eq 0 ]]; then
  summarize_release_build "$RUNNER_TEMP/nightly-release-build.log" "$build_cache"
  finish_host_build
else
  fail_host_build "$release_status"
  exit "$release_status"
fi
