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
TMUX_CORPUS_FILE="$ROOT_DIR/.github/workflows/tmux-corpus.yml"

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

check_release_helper_upload_retry() {
  if ! awk '
    /^  release-ghostty-cli-helper:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }

    in_job && /- name: Upload universal Ghostty CLI helper/ { in_upload=1; next }
    in_upload && /^[[:space:]]*- name:/ { in_upload=0 }
    in_upload && /id:[[:space:]]*upload-ghostty-cli-helper/ { upload_id=1 }
    in_upload && /continue-on-error:[[:space:]]*true/ { upload_continue=1 }
    in_upload && /uses: actions\/upload-artifact@/ { upload_action=1 }
    in_upload && /if-no-files-found:[[:space:]]*error/ { upload_required=1 }

    in_job && /- name: Retry universal Ghostty CLI helper upload/ { in_retry=1; retry_step=1; next }
    in_retry && /^[[:space:]]*- name:/ { in_retry=0 }
    in_retry && index($0, "steps.upload-ghostty-cli-helper.outcome == '\''failure'\''") { retry_if=1 }
    in_retry && /uses: actions\/upload-artifact@/ { retry_action=1 }
    in_retry && /if-no-files-found:[[:space:]]*error/ { retry_required=1 }
    in_retry && /overwrite:[[:space:]]*true/ { retry_overwrite=1 }

    END {
      exit !(upload_id && upload_continue && upload_action && upload_required && retry_step && retry_if && retry_action && retry_required && retry_overwrite)
    }
  ' "$CI_FILE"; then
    echo "FAIL: release-ghostty-cli-helper must retry required Ghostty helper artifact uploads instead of failing on a single transient upload error"
    exit 1
  fi

  echo "PASS: release-ghostty-cli-helper retries required Ghostty helper artifact uploads"
}

check_no_ci_xctest_skips() {
  if grep -nE '(^|[[:space:]])-skip-testing:' "$CI_FILE"; then
    echo "FAIL: ci.yml must not exclude individual XCTest methods with -skip-testing; fix or isolate the flaky test instead"
    exit 1
  fi

  echo "PASS: ci.yml does not exclude XCTest methods"
}

check_no_ci_swift_package_skips() {
  if grep -nE '(^|[[:space:]])swift[[:space:]]+test([[:space:]].*)?[[:space:]]--skip([[:space:]]|$)' "$CI_FILE"; then
    echo "FAIL: ci.yml must not exclude Swift package tests with swift test --skip; fix or isolate the failing package test instead"
    exit 1
  fi

  echo "PASS: ci.yml does not exclude Swift package tests"
}

check_web_db_behavior_tests() {
  local db_runner="$ROOT_DIR/web/scripts/run-db-behavior-tests.sh"
  if [[ ! -x "$db_runner" ]]; then
    echo "FAIL: web DB behavior runner must exist and be executable"
    exit 1
  fi

  if ! grep -Fq '"test:db:behavior": "bash scripts/run-db-behavior-tests.sh"' "$ROOT_DIR/web/package.json"; then
    echo "FAIL: web/package.json must expose test:db:behavior for DB-gated web tests"
    exit 1
  fi

  if ! awk '
    /- name: Database behavior tests/ { in_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /CMUX_DB_TEST:[[:space:]]*"1"/ { saw_env=1 }
    in_step && /bun run test:db:behavior/ { saw_runner=1 }
    END { exit !(saw_env && saw_runner) }
  ' "$CI_FILE"; then
    echo "FAIL: ci.yml must run the DB behavior test discovery runner with CMUX_DB_TEST=1"
    exit 1
  fi

  if ! grep -Fq 'grep -q "process\\.env\\.CMUX_DB_TEST"' "$db_runner"; then
    echo "FAIL: DB behavior runner must discover CMUX_DB_TEST-gated files instead of hard-coding a subset"
    exit 1
  fi

  echo "PASS: web DB behavior tests run through the discovery runner"
}

check_tmux_terminal_nightly_isolation() {
  check_macos_runner "$TMUX_CORPUS_FILE" "terminal-nightly"

  if ! awk '
    /^  terminal-nightly:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && /CMUX_DERIVED_DATA_PATH/ { saw_env=1 }
    in_job && /-derivedDataPath "\$CMUX_DERIVED_DATA_PATH"/ { saw_flag=1 }
    in_job && /scripts\/ci\/xcodebuild_noninteractive\.py/ { saw_noninteractive=1 }
    in_job && /SWIFT_BACKTRACE: "interactive=no,timeout=0s,symbolicate=off,color=no"/ { saw_backtrace=1 }
    in_job && /All failures are expected, treating as pass/ { saw_expected_failure_handling=1 }
    END { exit !(saw_env && saw_flag && saw_noninteractive && saw_backtrace && saw_expected_failure_handling) }
  ' "$TMUX_CORPUS_FILE"; then
    echo "FAIL: tmux corpus terminal-nightly must use isolated DerivedData, the noninteractive xcodebuild wrapper, and expected-failure handling"
    exit 1
  fi

  echo "PASS: tmux corpus terminal-nightly uses isolated DerivedData, noninteractive xcodebuild, and expected-failure handling"
}

# ci.yml jobs
check_macos_runner "$CI_FILE" "tests"
check_macos_runner "$CI_FILE" "tests-build-and-lag"
check_macos_runner "$CI_FILE" "release-ghostty-cli-helper"
check_macos_runner "$CI_FILE" "release-build"
check_macos_runner "$CI_FILE" "ui-regressions"

# build-ghosttykit.yml
check_macos_runner "$GHOSTTYKIT_FILE" "build-ghosttykit"

# ci-macos-compat.yml (matrix.os routed through the MACOS_RUNNER_* repo vars)
check_macos_runner "$COMPAT_FILE" "compat-tests"

# test-e2e.yml is manual, so keep the Depot GUI runner choices but cancel
# duplicate queued runs for the same ref/filter/runner.
check_e2e_runner_fallbacks

check_xcode_selection
check_release_build_signal
check_release_helper_upload_retry
check_no_ci_xctest_skips
check_no_ci_swift_package_skips
check_web_db_behavior_tests
check_tmux_terminal_nightly_isolation
