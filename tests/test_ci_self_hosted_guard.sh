#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/385.
# Ensures paid CI jobs use a paid macOS runner (Blacksmith or WarpBuild, routed
# through the MACOS_RUNNER_15 / MACOS_RUNNER_26 repo variables), never a free
# GitHub-hosted runner. Flip Blacksmith<->Warp by editing those repo variables;
# see docs/macos-ci-runners.md.
# Fork PRs are gated by GitHub's built-in "Require approval for outside
# collaborators" setting, so workflow-level fork guards are not needed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CI_FILE="$ROOT_DIR/.github/workflows/ci.yml"
GHOSTTYKIT_FILE="$ROOT_DIR/.github/workflows/build-ghosttykit.yml"
COMPAT_FILE="$ROOT_DIR/.github/workflows/ci-macos-compat.yml"
E2E_FILE="$ROOT_DIR/.github/workflows/test-e2e.yml"
PERF_FILE="$ROOT_DIR/.github/workflows/perf-activation.yml"
NIGHTLY_FILE="$ROOT_DIR/.github/workflows/nightly.yml"
RELEASE_FILE="$ROOT_DIR/.github/workflows/release.yml"

check_macos_runner() {
  local file="$1" job="$2"
  if ! awk -v job="$job" '
    $0 ~ "^  "job":" { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && /runs-on:.*(vars\.MACOS_RUNNER|blacksmith-[0-9]+vcpu-macos-|warp-macos-[0-9]+-arm64)/ { saw=1 }
    in_job && /os:.*(vars\.MACOS_RUNNER|blacksmith-[0-9]+vcpu-macos-|warp-macos-[0-9]+-arm64)/ { saw=1 }
    END { exit !(saw) }
  ' "$file"; then
    echo "FAIL: $job in $(basename "$file") must run on a paid macOS runner (vars.MACOS_RUNNER_* or a Blacksmith/Warp label), not a GitHub-hosted runner"
    exit 1
  fi
  echo "PASS: $job in $(basename "$file") uses a paid macOS runner"
}

check_self_hosted_workspace_prep() {
  local file="$1" job="$2"
  if ! awk -v job="$job" '
    $0 ~ "^  "job":" { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && index($0, "- name: Prepare self-hosted workspace") { saw_prep=1; if (!saw_checkout) prep_before_checkout=1 }
    in_job && index($0, "sudo -n chown -R \"$(id -un):$(id -gn)\" \"$GITHUB_WORKSPACE\"") { saw_chown=1 }
    in_job && index($0, "chmod -R u+rwX \"$GITHUB_WORKSPACE\"") { saw_chmod=1 }
    in_job && index($0, "find \"$GITHUB_WORKSPACE\" -mindepth 1 -maxdepth 1 -exec rm -rf {} +") { saw_clean=1 }
    in_job && /uses: actions\/checkout/ { saw_checkout=1 }
    END { exit(saw_prep && prep_before_checkout && saw_chown && saw_chmod && saw_clean ? 0 : 1) }
  ' "$file"; then
    echo "FAIL: $job in $(basename "$file") must normalize and clean GITHUB_WORKSPACE before checkout so root-owned leftovers cannot break self-hosted macOS jobs"
    exit 1
  fi

  echo "PASS: $job in $(basename "$file") normalizes self-hosted workspace before checkout"
}

check_e2e_runner_fallbacks() {
  if ! awk '
    /^run-name:/ {
      saw_run_name=1
      if ($0 ~ /inputs\.test_filter/ && ($0 ~ /inputs\.runner/ || $0 ~ /depot-macos-latest/) && ($0 ~ /inputs\.ref/ || $0 ~ /github\.ref_name/)) {
        saw_run_name_dynamic=1
      }
    }
    /^concurrency:/ { in_concurrency=1; next }
    in_concurrency && /^jobs:/ { in_concurrency=0 }
    in_concurrency && /cancel-in-progress:[[:space:]]*true/ { saw_cancel=1 }
    in_concurrency && (/inputs\.runner/ || /depot-macos-latest/) { saw_runner=1 }
    in_concurrency && /inputs\.test_filter/ { saw_test_filter=1 }
    in_concurrency && /github\.ref_name/ { saw_ref_name=1 }
    END { exit !(saw_run_name && saw_run_name_dynamic && saw_cancel && saw_runner && saw_test_filter && saw_ref_name) }
  ' "$E2E_FILE"; then
    echo "FAIL: test-e2e.yml must dynamically name runs and cancel duplicate queued E2E jobs by runner, normalized ref, and test filter"
    exit 1
  fi

  for label in depot-macos-latest depot-macos-14; do
    if ! grep -Eq "^[[:space:]]+- ${label}$" "$E2E_FILE"; then
      echo "FAIL: test-e2e.yml must expose runner option ${label}"
      exit 1
    fi
  done

  if ! grep -Fq 'RUNNER_CONTEXT_NAME: ${{ runner.name }}' "$E2E_FILE"; then
    echo "FAIL: test-e2e.yml must inspect the actual runner name for Depot runs"
    exit 1
  fi

  if ! grep -Fq "startsWith((!inputs.runner || inputs.runner == 'auto') && (vars.MACOS_RUNNER_15 || 'warp-macos-15-arm64-6x') || inputs.runner, 'depot-macos-')" "$E2E_FILE"; then
    echo "FAIL: test-e2e.yml must validate all Depot macOS runner choices"
    exit 1
  fi

  if ! awk '
    /^[[:space:]]*\*\)$/ {
      in_reject = 1
      saw_error = 0
      saw_exit = 0
      next
    }
    in_reject && /echo "::error::\$REQUESTED_RUNNER resolved outside Depot/ { saw_error = 1 }
    in_reject && /^[[:space:]]*exit 1$/ { saw_exit = 1 }
    in_reject && /^[[:space:]]*;;$/ {
      if (saw_error && saw_exit) {
        found = 1
      }
      in_reject = 0
    }
    END { exit(found ? 0 : 1) }
  ' "$E2E_FILE"; then
    echo "FAIL: test-e2e.yml must fail fast and explain runner label misrouting clearly"
    exit 1
  fi

  if grep -Eq "^[[:space:]]*continue-on-error:" "$E2E_FILE"; then
    echo "FAIL: test-e2e.yml must not mask E2E setup or test failures with continue-on-error"
    exit 1
  fi

  echo "PASS: test-e2e.yml exposes Depot runner choices, identity guard, and duplicate-queue cancellation"
}

check_xcode_selection() {
  if grep -R -n "ls -d /Applications/Xcode" "$ROOT_DIR/.github/workflows"; then
    echo "FAIL: workflow Xcode selection must use find/sort/tail fallback, not ls/glob ordering"
    exit 1
  fi

  echo "PASS: workflow Xcode selection avoids ls/glob ordering"
}

check_workflow_yaml_parse() {
  ruby -e 'require "yaml"; ARGV.each { |path| YAML.load_file(path) }' \
    "$CI_FILE" \
    "$GHOSTTYKIT_FILE" \
    "$COMPAT_FILE" \
    "$E2E_FILE" \
    "$PERF_FILE" \
    "$NIGHTLY_FILE" \
    "$RELEASE_FILE"

  echo "PASS: workflow YAML parses"
}

check_release_build_signal() {
  if ! grep -Fq 'lipo "$APP_BINARY" -verify_arch arm64 x86_64' "$CI_FILE"; then
    echo "FAIL: release-build must verify the Release app binary stays universal"
    exit 1
  fi

  if ! grep -Fq 'lipo "$CLI_BINARY" -verify_arch arm64 x86_64' "$CI_FILE"; then
    echo "FAIL: release-build must verify the bundled CLI stays universal"
    exit 1
  fi

  if ! grep -Fq 'lipo "$HELPER_BINARY" -verify_arch arm64 x86_64' "$CI_FILE"; then
    echo "FAIL: release-build must verify the bundled Ghostty helper stays universal"
    exit 1
  fi

  echo "PASS: release-build keeps universal artifact verification"
}

check_no_xctest_quarantines() {
  if grep -R -n -- "-skip-testing:" "$ROOT_DIR/.github/workflows"; then
    echo "FAIL: workflow XCTest coverage must not be hidden with -skip-testing quarantines"
    exit 1
  fi

  echo "PASS: workflows do not hide XCTest coverage with -skip-testing"
}

check_split_theme_regression_timeout() {
  if ! awk '
    /^[[:space:]]*- name: Run Ghostty split-theme appearance regression$/ { in_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /scripts\/ci\/xcodebuild_noninteractive\.py/ { saw_wrapper=1 }
    in_step && /CMUX_SPLIT_THEME_TEST_TIMEOUT_SECONDS/ { saw_timeout=1 }
    in_step && /xcodebuild split-theme regression timeout/ { saw_timeout_message=1 }
    in_step && /Cargo registry download failed during split-theme build, retrying once/ { saw_cargo_retry=1 }
    in_step && /static\\.crates\\.io/ { saw_static_crates_match=1 }
    END { exit(saw_wrapper && saw_timeout && saw_timeout_message && saw_cargo_retry && saw_static_crates_match ? 0 : 1) }
  ' "$CI_FILE"; then
    echo "FAIL: split-theme XCTest regression must use noninteractive xcodebuild, a step timeout, and a Cargo registry retry"
    exit 1
  fi

  echo "PASS: split-theme XCTest regression uses noninteractive xcodebuild with timeout and Cargo registry retry"
}

check_tests_deriveddata_cache() {
  if ! awk '
    /^  tests:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && /path: \.ci-derived-data\/tests/ { saw_cache_path=1 }
    in_job && /restore-keys:[[:space:]]*\|/ { in_restore=1; next }
    in_job && in_restore && /deriveddata-tests-/ { saw_restore=1 }
    in_job && in_restore && /^[[:space:]]{10}[^[:space:]-]/ { in_restore=0 }
    in_job && /DERIVED_DATA_PATH="\$PWD\/\.ci-derived-data\/tests"/ { saw_derived_data_env += 1 }
    in_job && /-derivedDataPath "\$DERIVED_DATA_PATH"/ { saw_derived_data += 1 }
    in_job && /CLI_BIN="\$DERIVED_DATA_PATH\/Build\/Products\/Debug\/cmux"/ { saw_cli_path=1 }
    END { exit(saw_cache_path && saw_restore && saw_derived_data_env >= 3 && saw_derived_data >= 2 && saw_cli_path ? 0 : 1) }
  ' "$CI_FILE"; then
    echo "FAIL: tests job must cache and reuse an explicit DerivedData path across split-theme and unit XCTest steps"
    exit 1
  fi

  echo "PASS: tests job reuses explicit cached DerivedData across XCTest steps"
}

check_ui_regression_budget() {
  local timeout_minutes
  timeout_minutes="$(
    awk '
      /^  ui-regressions:/ { in_job=1; next }
      in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
      in_job && /timeout-minutes:/ { print $2; exit }
    ' "$CI_FILE"
  )"

  if [ -z "$timeout_minutes" ] || [ "$timeout_minutes" -lt 75 ]; then
    echo "FAIL: ui-regressions must keep enough job time for a cold build-for-testing plus both UI regressions after observed 40m+ cold builds"
    exit 1
  fi

  if ! grep -Fq 'path: .ci-derived-data/ui-regressions' "$CI_FILE"; then
    echo "FAIL: ui-regressions must cache its explicit DerivedData path"
    exit 1
  fi

  if ! awk '
    /^  ui-regressions:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && /-derivedDataPath "\$DERIVED_DATA_PATH"/ { saw += 1 }
    END { exit(saw >= 3 ? 0 : 1) }
  ' "$CI_FILE"; then
    echo "FAIL: ui-regressions must use its explicit DerivedData path for build-for-testing and both test-without-building runs"
    exit 1
  fi

  if grep -Fq 'name: Create persistent virtual display' "$CI_FILE"; then
    echo "FAIL: ui-regressions must reuse the display-churn virtual display instead of creating a second CGVirtualDisplay"
    exit 1
  fi

  if ! grep -Fq 'echo "VDISPLAY_PERSISTENT_PID=$HELPER_PID" >> "$GITHUB_ENV"' "$CI_FILE"; then
    echo "FAIL: ui-regressions must keep the display-churn helper alive for the browser find regression and final cleanup"
    exit 1
  fi

  echo "PASS: ui-regressions keeps enough time and cached DerivedData for both UI regressions"
}

check_build_and_lag_budget() {
  local timeout_minutes
  timeout_minutes="$(
    awk '
      /^  tests-build-and-lag:/ { in_job=1; next }
      in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
      in_job && /timeout-minutes:/ { print $2; exit }
    ' "$CI_FILE"
  )"

  if [ -z "$timeout_minutes" ] || [ "$timeout_minutes" -lt 75 ]; then
    echo "FAIL: tests-build-and-lag must keep enough job time for a cold merged-main build plus lag regressions"
    exit 1
  fi

  if ! awk '
    /^  tests-build-and-lag:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && /path: \.ci-derived-data\/build/ { saw_cache_path=1 }
    in_job && /restore-keys:[[:space:]]*\|/ { in_restore=1; next }
    in_job && in_restore && /deriveddata-build-/ { saw_restore=1 }
    in_job && in_restore && /^[[:space:]]{10}[^[:space:]-]/ { in_restore=0 }
    in_job && /DERIVED_DATA_PATH="\$PWD\/\.ci-derived-data\/build"/ { saw_derived_data_env += 1 }
    in_job && /-derivedDataPath "\$DERIVED_DATA_PATH"/ { saw_derived_data=1 }
    END { exit(saw_cache_path && saw_restore && saw_derived_data_env >= 3 && saw_derived_data ? 0 : 1) }
  ' "$CI_FILE"; then
    echo "FAIL: tests-build-and-lag must restore and use its workspace-local DerivedData path so retries are not always cold"
    exit 1
  fi

  echo "PASS: tests-build-and-lag keeps enough time and restores DerivedData for cold builds"
}

check_zig_release_build_runner() {
  local file="$1" job="$2"
  if ! awk -v job="$job" '
    $0 ~ "^  "job":" { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && /runs-on:.*vars\.MACOS_RUNNER_15/ { saw_runner=1 }
    in_job && /runs-on:.*warp-macos-15-arm64-6x/ { saw_fallback=1 }
    END { exit !(saw_runner && saw_fallback) }
  ' "$file"; then
    echo "FAIL: $job in $(basename "$file") must use the macOS 15 runner lane until Zig 0.15.2 no longer links against the Xcode 26.4 SDK"
    exit 1
  fi

  echo "PASS: $job in $(basename "$file") avoids the Xcode 26.4 Zig linker failure lane"
}

# ci.yml jobs
check_macos_runner "$CI_FILE" "tests"
check_macos_runner "$CI_FILE" "tests-build-and-lag"
check_macos_runner "$CI_FILE" "release-build"
check_macos_runner "$CI_FILE" "ui-regressions"
check_self_hosted_workspace_prep "$CI_FILE" "tests"
check_self_hosted_workspace_prep "$CI_FILE" "tests-build-and-lag"
check_self_hosted_workspace_prep "$CI_FILE" "release-build"
check_self_hosted_workspace_prep "$CI_FILE" "ui-regressions"

# build-ghosttykit.yml
check_macos_runner "$GHOSTTYKIT_FILE" "build-ghosttykit"
check_self_hosted_workspace_prep "$GHOSTTYKIT_FILE" "build-ghosttykit"

# ci-macos-compat.yml (matrix.os routed through the MACOS_RUNNER_* repo vars)
check_macos_runner "$COMPAT_FILE" "compat-tests"
check_self_hosted_workspace_prep "$COMPAT_FILE" "compat-tests"

# test-e2e.yml is manual, so keep the Depot GUI runner choices but cancel
# duplicate queued runs for the same ref/filter/runner.
check_e2e_runner_fallbacks
check_self_hosted_workspace_prep "$E2E_FILE" "e2e"

# perf-activation.yml
check_macos_runner "$PERF_FILE" "activation-session"
check_self_hosted_workspace_prep "$PERF_FILE" "activation-session"

# release lanes
check_self_hosted_workspace_prep "$NIGHTLY_FILE" "build-sign-notarize-nightly"
check_self_hosted_workspace_prep "$RELEASE_FILE" "build-sign-notarize"

check_xcode_selection
check_workflow_yaml_parse
check_release_build_signal
check_no_xctest_quarantines
check_split_theme_regression_timeout
check_tests_deriveddata_cache
check_ui_regression_budget
check_build_and_lag_budget
check_zig_release_build_runner "$CI_FILE" "release-build"
check_zig_release_build_runner "$NIGHTLY_FILE" "build-sign-notarize-nightly"
check_zig_release_build_runner "$RELEASE_FILE" "build-sign-notarize"
