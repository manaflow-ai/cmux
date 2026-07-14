#!/usr/bin/env bash
# shellcheck disable=SC2016 # GitHub expressions and shell snippets are literal test fixtures.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CI_FILE="$ROOT_DIR/.github/workflows/ci.yml"
RELEASE_FILE="$ROOT_DIR/.github/workflows/release.yml"
CACHE_ACTION_SHA="27d5ce7f107fe9357f9df03efb73ab90386fccae"
CACHE_KEY='xcode-compilation-release-${{ runner.os }}-${{ runner.arch }}-${{ steps.release-compilation-cache-key.outputs.toolchain }}-${{ steps.release-compilation-cache-key.outputs.utc_week }}'

job_section() {
  local file="$1" job="$2"
  awk -v job="$job" '
    $0 ~ "^  "job":" { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { exit }
    in_job { print }
  ' "$file"
}

step_section() {
  local section="$1" step="$2"
  awk -v step="$step" '
    $0 == "      - name: "step { in_step=1; next }
    in_step && /^      - name:/ { exit }
    in_step { print }
  ' <<<"$section"
}

require_contains() {
  local text="$1" needle="$2" message="$3"
  if [[ "$text" != *"$needle"* ]]; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

require_not_contains() {
  local text="$1" needle="$2" message="$3"
  if [[ "$text" == *"$needle"* ]]; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

CI_JOB="$(job_section "$CI_FILE" "release-build")"
RELEASE_JOB="$(job_section "$RELEASE_FILE" "build-sign-notarize")"

for job in "$CI_JOB" "$RELEASE_JOB"; do
  require_contains "$job" 'CMUX_CI_XCODE_APP: ${{ vars.CMUX_CI_XCODE_APP_MACOS_26 }}' \
    "CI and stable release builds must use the same configured Xcode"
  require_contains "$job" 'CMUX_CI_REQUIRED_MACOS_SDK_MAJOR: "26"' \
    "CI and stable release builds must require the macOS 26 SDK"

  select_step="$(step_section "$job" "Select Xcode")"
  require_contains "$select_step" './scripts/select-ci-xcode.sh' \
    "CI and stable release builds must share the guarded Xcode selector"

  key_step="$(step_section "$job" "Compute release compilation cache key")"
  require_contains "$key_step" 'utc_week=$(date -u +%Y-W%W)' \
    "release compilation cache keys must rotate weekly"
  require_contains "$key_step" "toolchain=\$(xcodebuild -version | shasum -a 256" \
    "release compilation cache keys must include the exact Xcode toolchain"

  restore_step="$(step_section "$job" "Restore release compilation cache")"
  require_contains "$restore_step" "uses: actions/cache/restore@$CACHE_ACTION_SHA" \
    "release compilation caches must use the pinned restore-only action"
  require_contains "$restore_step" 'path: build-universal/CompilationCache.noindex' \
    "only Xcode content-addressed compiler results may be restored"
  require_contains "$restore_step" "key: $CACHE_KEY" \
    "CI and stable release builds must use the same cache key"
  require_not_contains "$restore_step" 'restore-keys:' \
    "release compilation caches must not fall back to stale weekly snapshots"

  build_step="$(step_section "$job" "Build universal app (Release)")"
  require_contains "$build_step" '-showBuildTimingSummary' \
    "release builds must publish Xcode timing evidence"
  require_contains "$build_step" 'COMPILER_INDEX_STORE_ENABLE=NO' \
    "release builds must not generate an unused source index"
  require_contains "$build_step" 'COMPILATION_CACHE_LIMIT_SIZE=3G' \
    "release builds must bound compiler cache growth during compilation"
  require_contains "$build_step" 'CODE_SIGNING_ALLOWED=NO' \
    "the cached compilation phase must remain unsigned"
done

ci_build_step="$(step_section "$CI_JOB" "Build universal app (Release)")"
require_contains "$ci_build_step" 'COMPILATION_CACHE_ENABLE_CACHING=YES' \
  "trusted CI must generate Xcode compilation cache entries"

require_not_contains "$CI_JOB" '- name: Cache DerivedData' \
  "CI must not cache the full DerivedData tree"

bound_step="$(step_section "$CI_JOB" "Bound release compilation cache size")"
require_contains "$bound_step" 'max_cache_kib=$((3 * 1024 * 1024))' \
  "CI must cap release compilation caches at 3 GiB"
require_contains "$bound_step" 'rm -rf "$cache_path"' \
  "CI must discard oversized release compilation caches"
require_contains "$bound_step" 'save_allowed=$save_allowed' \
  "CI must gate cache saves on the size check"

save_step="$(step_section "$CI_JOB" "Save trusted release compilation cache")"
require_contains "$save_step" "uses: actions/cache/save@$CACHE_ACTION_SHA" \
  "trusted CI must use the pinned cache save action"
require_contains "$save_step" "key: $CACHE_KEY" \
  "trusted CI must save the exact key stable releases restore"
require_contains "$save_step" "github.event_name == 'push' && github.ref == 'refs/heads/main'" \
  "automatic cache writes must be restricted to trusted main pushes"
require_contains "$save_step" "github.event_name == 'workflow_dispatch'" \
  "manual branch dispatches must support scoped dry-run cache proof"
require_contains "$save_step" "steps.restore-release-compilation-cache.outputs.cache-hit != 'true'" \
  "CI must not attempt to overwrite immutable cache hits"

if ! awk '
  /^  release-build:/ { in_job=1; next }
  in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
  in_job && /- name: Validate Release artifact slices/ { saw_validation=1 }
  in_job && /- name: Save trusted release compilation cache/ {
    saw_save=1
    save_after_validation=saw_validation
  }
  END { exit !(saw_validation && saw_save && save_after_validation) }
' "$CI_FILE"; then
  echo "FAIL: CI must validate the unsigned universal artifact before seeding a trusted cache" >&2
  exit 1
fi

reject_step="$(step_section "$RELEASE_JOB" "Reject oversized release compilation cache")"
require_contains "$reject_step" 'max_cache_kib=$((3 * 1024 * 1024))' \
  "stable releases must reject restored caches larger than 3 GiB"
require_contains "$reject_step" 'rm -rf "$cache_path"' \
  "stable releases must fall back cold when a cache is oversized or absent"
require_contains "$reject_step" 'steps.restore-release-compilation-cache.outputs.cache-hit' \
  "stable releases must require an exact cache hit before enabling caching"
require_contains "$reject_step" 'cache_usable=$cache_usable' \
  "stable releases must expose whether the restored cache passed validation"
require_contains "$reject_step" $'          else\n            # A miss must be a cold build' \
  "stable releases must remove stale compiler data after a cache miss"

release_build_step="$(step_section "$RELEASE_JOB" "Build universal app (Release)")"
require_contains "$release_build_step" 'compilation_cache_enabled=NO' \
  "stable releases must default to the existing uncached build path"
require_contains "$release_build_step" 'steps.validate-release-compilation-cache.outputs.cache_usable' \
  "stable releases must enable compiler caching only after validation"
require_contains "$release_build_step" 'COMPILATION_CACHE_ENABLE_CACHING="$compilation_cache_enabled"' \
  "stable releases must pass the validated cache decision to Xcode"

release_cleanup_step="$(step_section "$RELEASE_JOB" "Discard release compilation cache after build")"
require_contains "$release_cleanup_step" 'if: steps.guard_release_assets.outputs.skip_all' \
  "stable release cache cleanup must follow the release guard"
require_contains "$release_cleanup_step" '&& always()' \
  "stable releases must reclaim compiler data even after a failed build"
require_contains "$release_cleanup_step" 'rm -rf "$cache_path"' \
  "stable releases must reclaim compiler data before signing and notarization"
require_not_contains "$RELEASE_JOB" 'actions/cache/save@' \
  "stable tag and dry-run release jobs must never write compilation caches"

if ! awk '
  /^  build-sign-notarize:/ { in_job=1; next }
  in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
  in_job && /- name: Restore release compilation cache/ { restore_order=++order }
  in_job && /- name: Reject oversized release compilation cache/ { reject_order=++order }
  in_job && /- name: Build universal app \(Release\)/ { build_order=++order }
  in_job && /- name: Discard release compilation cache after build/ { cleanup_order=++order }
  END {
    exit !(restore_order > 0 && reject_order > restore_order && build_order > reject_order && cleanup_order > build_order)
  }
' "$RELEASE_FILE"; then
  echo "FAIL: stable releases must validate before building and discard the compiler cache afterward" >&2
  exit 1
fi

echo "PASS: release compilation cache is unsigned, bounded, toolchain-scoped, and restore-only for releases"
