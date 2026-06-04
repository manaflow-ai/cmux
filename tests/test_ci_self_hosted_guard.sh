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
TEST_DEPOT_FILE="$ROOT_DIR/.github/workflows/test-depot.yml"
TMUX_CORPUS_FILE="$ROOT_DIR/.github/workflows/tmux-corpus.yml"
TERMINAL_CORPUS_NIGHTLY_FILE="$ROOT_DIR/.github/workflows/terminal-corpus-nightly.yml"
CA_REGRESSION_SCRIPT="$ROOT_DIR/scripts/verify-main-thread-ca-transactions.sh"

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

check_e2e_recording_preflight() {
  if ! awk '
    /cmux-screen-capture-preflight\.c/ { saw_source=1 }
    /CGPreflightScreenCaptureAccess/ { saw_preflight=1 }
    /Screen capture permission is unavailable/ { saw_warning=1 }
    /skipping recording to avoid blocking UI tests with a privacy prompt/ { saw_prompt_warning=1 }
    /No AVFoundation screen capture device found; skipping recording/ { saw_no_device=1 }
    /grep -E "AVFoundation\|Capture screen" \|\| true/ { saw_nonfatal_grep=1 }
    /^[[:space:]]*- name: Upload recording artifact$/ { in_upload=1; next }
    in_upload && /^[[:space:]]*- name:/ { in_upload=0 }
    in_upload && /env\.RECORD_PID != '\'''\''/ { saw_conditional_upload=1 }
    in_upload && /if-no-files-found:[[:space:]]*error/ { saw_upload_error=1 }
    in_upload && /if-no-files-found:[[:space:]]*warn/ { saw_upload_warn=1 }
    END { exit(saw_source && saw_preflight && saw_warning && saw_prompt_warning && saw_no_device && saw_nonfatal_grep && saw_conditional_upload && saw_upload_error && !saw_upload_warn ? 0 : 1) }
  ' "$E2E_FILE"; then
    echo "FAIL: test-e2e.yml must preflight recording, skip upload when no recorder starts, and fail when a started recording artifact is missing"
    exit 1
  fi

  echo "PASS: test-e2e.yml preflights screen recording and requires artifacts after recording starts"
}

check_virtual_display_step_waits_for_readiness() {
  local file="$1" job="$2"
  if ! awk -v job="$job" '
    $0 ~ "^  "job":" { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && /^[[:space:]]*- name: Create virtual display$/ { in_step=1; saw_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /--ready-path "\$VDISPLAY_READY"/ { saw_ready_arg=1 }
    in_step && /--display-id-path "\$VDISPLAY_ID_PATH"/ { saw_id_arg=1 }
    in_step && /\[ -s "\$VDISPLAY_READY" \] && \[ -s "\$VDISPLAY_ID_PATH" \]/ { saw_ready_poll=1 }
    in_step && /Virtual display helper exited before readiness/ { saw_exit_message=1 }
    in_step && /Timed out waiting for virtual display readiness/ { saw_timeout_message=1 }
    in_step && /^[[:space:]]*sleep 3$/ { saw_fixed_sleep=1 }
    END { exit(saw_step && saw_ready_arg && saw_id_arg && saw_ready_poll && saw_exit_message && saw_timeout_message && !saw_fixed_sleep ? 0 : 1) }
  ' "$file"; then
    echo "FAIL: $job in $(basename "$file") must wait for virtual display readiness files instead of using a fixed sleep"
    exit 1
  fi

  echo "PASS: $job in $(basename "$file") waits for virtual display readiness"
}

check_test_depot_fails_closed() {
  if ! awk '
    /^[[:space:]]*- name: Validate suite selection$/ { in_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /skip_unit_tests/ { saw_skip_unit=1 }
    in_step && /skip_ui_tests/ { saw_skip_ui=1 }
    in_step && /that would execute no tests/ { saw_message=1 }
    in_step && /^[[:space:]]*exit 1$/ { saw_exit=1 }
    END { exit(saw_skip_unit && saw_skip_ui && saw_message && saw_exit ? 0 : 1) }
  ' "$TEST_DEPOT_FILE"; then
    echo "FAIL: test-depot.yml must reject skip_unit_tests=true with skip_ui_tests=true so the manual workflow cannot succeed without selecting a suite"
    exit 1
  fi

  if ! awk '
    /^[[:space:]]*- name: Create virtual display$/ { in_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /--ready-path "\$VDISPLAY_READY"/ { saw_ready_arg=1 }
    in_step && /--display-id-path "\$VDISPLAY_ID_PATH"/ { saw_id_arg=1 }
    in_step && /\[ -s "\$VDISPLAY_READY" \] && \[ -s "\$VDISPLAY_ID_PATH" \]/ { saw_ready_poll=1 }
    in_step && /Virtual display helper exited before readiness/ { saw_exit_message=1 }
    in_step && /Timed out waiting for virtual display readiness/ { saw_timeout_message=1 }
    in_step && /^[[:space:]]*sleep 3$/ { saw_fixed_sleep=1 }
    END { exit(saw_ready_arg && saw_id_arg && saw_ready_poll && saw_exit_message && saw_timeout_message && !saw_fixed_sleep ? 0 : 1) }
  ' "$TEST_DEPOT_FILE"; then
    echo "FAIL: test-depot.yml must wait for virtual display readiness files instead of using a fixed sleep"
    exit 1
  fi

  if ! awk '
    /^[[:space:]]*- name: Run unit tests$/ { in_unit=1; next }
    in_unit && /^[[:space:]]*- name:/ { in_unit=0 }
    in_unit && /Executed \[1-9\]\[0-9\]\* test,\|Executed \[1-9\]\[0-9\]\* tests\|Test run with \[1-9\]\[0-9\]\* tests/ { saw_unit_guard=1 }
    in_unit && /Unit test workflow completed without executing any tests/ { saw_unit_message=1 }
    /^[[:space:]]*- name: Run UI tests$/ { in_ui=1; next }
    in_ui && /^[[:space:]]*- name:/ { in_ui=0 }
    in_ui && /scripts\/ci\/xcodebuild_noninteractive\.py/ { saw_ui_wrapper=1 }
    in_ui && /Executed \[1-9\]\[0-9\]\* test,\|Executed \[1-9\]\[0-9\]\* tests\|Test run with \[1-9\]\[0-9\]\* tests/ { saw_ui_guard=1 }
    in_ui && /UI test workflow completed without executing any tests/ { saw_ui_message=1 }
    END { exit(saw_unit_guard && saw_unit_message && saw_ui_wrapper && saw_ui_guard && saw_ui_message ? 0 : 1) }
  ' "$TEST_DEPOT_FILE"; then
    echo "FAIL: test-depot.yml must run xcodebuild noninteractively and reject unit or UI runs that execute zero tests"
    exit 1
  fi

  echo "PASS: test-depot.yml fails closed for no-suite selection, display readiness, and zero-test xcodebuild runs"
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
    "$RELEASE_FILE" \
    "$TEST_DEPOT_FILE" \
    "$TMUX_CORPUS_FILE" \
    "$TERMINAL_CORPUS_NIGHTLY_FILE"

  echo "PASS: workflow YAML parses"
}

check_tmux_corpus_pr_jobs_do_not_report_skipped_terminal_tests() {
  if grep -Eq "^[[:space:]]{2}terminal-nightly:" "$TMUX_CORPUS_FILE"; then
    echo "FAIL: tmux-corpus.yml must not include terminal-nightly as a job-level skipped PR check; keep scheduled/manual terminal corpus tests in terminal-corpus-nightly.yml"
    exit 1
  fi

  echo "PASS: tmux-corpus PR workflow does not report skipped terminal-nightly checks"
}

check_activation_artifacts_are_required() {
  if ! awk '
    /^[[:space:]]*- name: Write benchmark summary$/ { in_summary=1; next }
    in_summary && /^[[:space:]]*- name:/ { in_summary=0 }
    in_summary && /No benchmark results were written/ { saw_missing_message=1 }
    in_summary && /^[[:space:]]*exit 1$/ { saw_missing_failure=1 }
    /^[[:space:]]*- name: Upload benchmark results$/ { in_upload=1; next }
    in_upload && /^[[:space:]]*- name:/ { in_upload=0 }
    in_upload && /if-no-files-found:[[:space:]]*error/ { saw_upload_error=1 }
    END { exit(saw_missing_message && saw_missing_failure && saw_upload_error ? 0 : 1) }
  ' "$PERF_FILE"; then
    echo "FAIL: perf-activation.yml must fail when benchmark result files are missing instead of uploading an empty or ignored artifact"
    exit 1
  fi

  echo "PASS: activation benchmark artifacts are required"
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

check_retryable_submodule_checkout() {
  if grep -R -n "submodules: recursive" "$ROOT_DIR/.github/workflows"; then
    echo "FAIL: workflows must not let actions/checkout fetch submodules without the retry wrapper"
    exit 1
  fi

  local file line missing=0
  while IFS=: read -r file line _; do
    if ! sed -n "${line},$((line + 4))p" "$file" | grep -Fq "./scripts/ci/init-submodules-with-retry.sh"; then
      echo "FAIL: $(basename "$file") line $line sets submodules: false without Initialize submodules with retry"
      missing=1
    fi
  done < <(grep -R -n "submodules: false" "$ROOT_DIR/.github/workflows" || true)

  if [ "$missing" -ne 0 ]; then
    exit 1
  fi

  echo "PASS: workflow submodule checkout uses retry wrapper"
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

check_command_palette_nucleo_ffi_coverage() {
  if ! awk '
    /^[[:space:]]*- name: Run command palette nucleo FFI tests$/ { in_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /CMUX_NUCLEO_FFI_DERIVED_DATA=.*\.ci-derived-data\/nucleo-ffi/ { saw_derived_data=1 }
    in_step && /CMUX_NUCLEO_FFI_SOURCE_PACKAGES_DIR=.*\.ci-source-packages/ { saw_source_packages=1 }
    in_step && /\.\/scripts\/test-command-palette-nucleo-ffi\.sh/ { saw_script=1 }
    END { exit(saw_derived_data && saw_source_packages && saw_script ? 0 : 1) }
  ' "$CI_FILE"; then
    echo "FAIL: tests job must run the focused command palette nucleo FFI XCTest lane so FFI-backed assertions do not silently skip under the broad unit-test lane"
    exit 1
  fi

  local script="$ROOT_DIR/scripts/test-command-palette-nucleo-ffi.sh"
  if ! grep -Fq 'CMUX_NUCLEO_FFI_REQUIRE_CARGO=1' "$script"; then
    echo "FAIL: test-command-palette-nucleo-ffi.sh must force the real nucleo FFI build before running FFI-backed assertions"
    exit 1
  fi

  if ! grep -Fq 'CMUX_SKIP_ZIG_BUILD=1' "$script"; then
    echo "FAIL: test-command-palette-nucleo-ffi.sh must skip the unrelated Ghostty helper Zig build so this focused lane cannot fail on Zig dependency network fetches"
    exit 1
  fi

  if ! grep -Fq 'scripts/ci/xcodebuild_noninteractive.py' "$script"; then
    echo "FAIL: test-command-palette-nucleo-ffi.sh must use the noninteractive xcodebuild wrapper when available"
    exit 1
  fi

  for method in \
    testNucleoResolvedSearchMatchesReturnFullFinalResultSetWhenUnbounded \
    testNucleoEmptyResultsFallBackToSwiftSingleEditMatching \
    testNucleoPartialResultsIncludeSwiftSingleEditFallback \
    testNucleoFullPageResultsIncludeSwiftSingleEditFallback \
    testNucleoExactPartialResultsDoNotRunSwiftSingleEditFallback
  do
    if ! grep -Fq "CommandPaletteSearchEngineTests/$method" "$script"; then
      echo "FAIL: test-command-palette-nucleo-ffi.sh must include CommandPaletteSearchEngineTests/$method"
      exit 1
    fi
  done

  echo "PASS: command palette nucleo FFI assertions run in a focused CI lane"
}

check_web_db_behavior_test_coverage() {
  if ! awk '
    /^  web-db-migrations:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && /services:/ { saw_services=1 }
    in_job && /postgres:/ { saw_postgres=1 }
    in_job && /POSTGRES_DB: cmux_test/ { saw_db=1 }
    in_job && /^[[:space:]]*- name: Database behavior tests$/ { in_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /CMUX_DB_TEST: "1"/ { saw_cmux_db_test=1 }
    in_step && /DATABASE_URL: postgres:\/\/cmux:cmux@localhost:5432\/cmux_test/ { saw_database_url=1 }
    in_step && /DIRECT_DATABASE_URL: postgres:\/\/cmux:cmux@localhost:5432\/cmux_test/ { saw_direct_database_url=1 }
    in_step && /run: bun run test:db:behavior/ { saw_command=1 }
    END { exit(saw_services && saw_postgres && saw_db && saw_cmux_db_test && saw_database_url && saw_direct_database_url && saw_command ? 0 : 1) }
  ' "$CI_FILE"; then
    echo "FAIL: web-db-migrations must run CMUX_DB_TEST-gated web behavior tests against the CI Postgres database"
    exit 1
  fi

  local script="$ROOT_DIR/web/scripts/run-db-behavior-tests.sh"
  if ! grep -Fq 'export CMUX_DB_TEST=1' "$script"; then
    echo "FAIL: run-db-behavior-tests.sh must force CMUX_DB_TEST=1 so DB-gated Bun tests execute"
    exit 1
  fi

  if ! grep -Fq 'find tests \( -name "*.test.ts" -o -name "*.test.tsx" \) -print | sort' "$script"; then
    echo "FAIL: run-db-behavior-tests.sh must discover DB-gated .test.ts and .test.tsx files instead of relying on a hand-maintained list"
    exit 1
  fi

  if ! grep -Fq 'grep -q "process\\.env\\.CMUX_DB_TEST" "$test_file"' "$script"; then
    echo "FAIL: run-db-behavior-tests.sh must select every CMUX_DB_TEST-gated web test file"
    exit 1
  fi

  if ! grep -Fq 'No CMUX_DB_TEST-gated test files found' "$script"; then
    echo "FAIL: run-db-behavior-tests.sh must fail closed when DB-gated web test discovery finds no files"
    exit 1
  fi

  if ! grep -Fq 'bun test "$test_file"' "$script"; then
    echo "FAIL: run-db-behavior-tests.sh must execute each discovered DB behavior test file"
    exit 1
  fi
  if ! grep -Fq "Ran [1-9][0-9]* tests? across [1-9][0-9]* files?" "$script"; then
    echo "FAIL: run-db-behavior-tests.sh must reject DB-gated files that execute zero Bun tests"
    exit 1
  fi

  if ! grep -Fq '"test:db:behavior": "bash scripts/run-db-behavior-tests.sh"' "$ROOT_DIR/web/package.json"; then
    echo "FAIL: web package.json must keep test:db:behavior wired to run-db-behavior-tests.sh"
    exit 1
  fi

  echo "PASS: web DB behavior tests run in CI with CMUX_DB_TEST and Postgres"
}

check_swift_package_tests_require_nonzero_execution() {
  if ! awk '
    /^[[:space:]]*- name: Run Swift package unit tests$/ { in_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /swift test --package-path "Packages\/\$pkg"/ { saw_swift_test=1 }
    in_step && /tee "\$output_file"/ { saw_capture=1 }
    in_step && /Executed \[1-9\]\[0-9\]\* test,\|Executed \[1-9\]\[0-9\]\* tests\|Test run with \[1-9\]\[0-9\]\* tests/ { saw_nonzero_guard=1 }
    in_step && /completed without executing any tests/ { saw_failure_message=1 }
    END { exit(saw_swift_test && saw_capture && saw_nonzero_guard && saw_failure_message ? 0 : 1) }
  ' "$CI_FILE"; then
    echo "FAIL: Swift package unit-test lane must fail if a listed package completes without executing any XCTest or Swift Testing tests"
    exit 1
  fi

  echo "PASS: Swift package unit-test lane rejects zero-test package runs"
}

check_xcodebuild_unit_step_requires_nonzero_execution() {
  local file="$1" step="$2" message="$3"
  if ! awk -v step="$step" -v message="$message" '
    index($0, "- name: " step) { in_step=1; saw_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /scripts\/ci\/xcodebuild_noninteractive\.py/ { saw_wrapper=1 }
    in_step && /Executed \[1-9\]\[0-9\]\* test,\|Executed \[1-9\]\[0-9\]\* tests\|Test run with \[1-9\]\[0-9\]\* tests/ { saw_nonzero_guard=1 }
    in_step && index($0, message) { saw_message=1 }
    END { exit(saw_step && saw_wrapper && saw_nonzero_guard && saw_message ? 0 : 1) }
  ' "$file"; then
    echo "FAIL: $step in $(basename "$file") must run xcodebuild noninteractively and reject zero-test success"
    exit 1
  fi

  echo "PASS: $step in $(basename "$file") rejects zero-test xcodebuild runs"
}

check_xcodebuild_unit_step_allows_expected_failures() {
  local file="$1" step="$2"
  if ! awk -v step="$step" '
    index($0, "- name: " step) { in_step=1; saw_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /grep "Executed\.\*tests\.\*with\.\*failures"/ { saw_summary=1 }
    in_step && /\(0 unexpected\)/ { saw_expected_check=1 }
    in_step && /All failures are expected, treating as pass/ { saw_expected_message=1 }
    in_step && /Unexpected unit test failures detected|Unexpected test failures detected/ { saw_unexpected_message=1 }
    END { exit(saw_step && saw_summary && saw_expected_check && saw_expected_message && saw_unexpected_message ? 0 : 1) }
  ' "$file"; then
    echo "FAIL: $step in $(basename "$file") must distinguish expected XCTest failures from unexpected failures"
    exit 1
  fi

  echo "PASS: $step in $(basename "$file") allows only expected XCTest failures"
}

check_e2e_ui_tests_require_nonzero_execution() {
  if ! awk '
    /^[[:space:]]*- name: Run UI tests$/ { in_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /Executed \[1-9\]\[0-9\]\* test,\|Executed \[1-9\]\[0-9\]\* tests\|Test run with \[1-9\]\[0-9\]\* tests/ { saw_nonzero_guard=1 }
    in_step && /UI test workflow completed without executing any tests/ { saw_message=1 }
    in_step && /test_result=failed/ { saw_failure_output=1 }
    END { exit(saw_nonzero_guard && saw_message && saw_failure_output ? 0 : 1) }
  ' "$E2E_FILE"; then
    echo "FAIL: test-e2e.yml must reject successful xcodebuild output that executed zero UI tests"
    exit 1
  fi

  echo "PASS: test-e2e.yml rejects zero-test UI runs"
}

check_tests_deriveddata_cache() {
  if ! awk '
    /^  tests:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && /name: Compute DerivedData cache fingerprint/ { saw_fingerprint_step=1 }
    in_job && /deriveddata-cache-fingerprint\.sh tests/ { saw_fingerprint_mode=1 }
    in_job && /path: \.ci-derived-data\/tests/ { saw_cache_path=1 }
    in_job && /key: deriveddata-tests-\$\{\{ steps\.deriveddata-fingerprint\.outputs\.hash \}\}-\$\{\{ steps\.ghostty-revision\.outputs\.sha \}\}/ { saw_key=1 }
    in_job && /restore-keys:[[:space:]]*\|/ { in_restore=1; next }
    in_job && in_restore && /deriveddata-tests-\$\{\{ steps\.deriveddata-fingerprint\.outputs\.hash \}\}-\$\{\{ steps\.ghostty-revision\.outputs\.sha \}\}-/ { saw_restore=1 }
    in_job && in_restore && /deriveddata-tests-/ && !/steps\.deriveddata-fingerprint\.outputs\.hash/ { saw_broad_restore=1 }
    in_job && in_restore && /^[[:space:]]{10}[^[:space:]-]/ { in_restore=0 }
    in_job && /DERIVED_DATA_PATH="\$PWD\/\.ci-derived-data\/tests"/ { saw_derived_data_env += 1 }
    in_job && /-derivedDataPath "\$DERIVED_DATA_PATH"/ { saw_derived_data += 1 }
    in_job && /CLI_BIN="\$DERIVED_DATA_PATH\/Build\/Products\/Debug\/cmux"/ { saw_cli_path=1 }
    END { exit(saw_fingerprint_step && saw_fingerprint_mode && saw_cache_path && saw_key && saw_restore && !saw_broad_restore && saw_derived_data_env >= 3 && saw_derived_data >= 2 && saw_cli_path ? 0 : 1) }
  ' "$CI_FILE"; then
    echo "FAIL: tests job must cache and reuse a source-fingerprinted explicit DerivedData path across split-theme and unit XCTest steps"
    exit 1
  fi

  echo "PASS: tests job reuses source-fingerprinted explicit cached DerivedData across XCTest steps"
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
    in_job && /name: Compute DerivedData cache fingerprint/ { saw_fingerprint_step=1 }
    in_job && /deriveddata-cache-fingerprint\.sh app/ { saw_fingerprint_mode=1 }
    in_job && /key: deriveddata-ui-regressions-\$\{\{ steps\.deriveddata-fingerprint\.outputs\.hash \}\}-\$\{\{ steps\.ghostty-revision\.outputs\.sha \}\}/ { saw_key=1 }
    in_job && /restore-keys: deriveddata-ui-regressions-\$\{\{ steps\.deriveddata-fingerprint\.outputs\.hash \}\}-\$\{\{ steps\.ghostty-revision\.outputs\.sha \}\}-/ { saw_restore=1 }
    in_job && /restore-keys: deriveddata-ui-regressions-/ && !/steps\.deriveddata-fingerprint\.outputs\.hash/ { saw_broad_restore=1 }
    END { exit(saw_fingerprint_step && saw_fingerprint_mode && saw_key && saw_restore && !saw_broad_restore ? 0 : 1) }
  ' "$CI_FILE"; then
    echo "FAIL: ui-regressions DerivedData cache must be source-fingerprinted and must not use a broad stale restore key"
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

  if ! awk '
    /^[[:space:]]*- name: Run display resolution churn UI regression$/ { in_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /wait_for_pid_exit\(\)/ { saw_wait_pid=1 }
    in_step && /stop_pid\(\)/ { saw_stop_pid=1 }
    in_step && /wait_for_cmux_dev_exit\(\)/ { saw_wait_cmux=1 }
    in_step && /Executed \[1-9\]\[0-9\]\* test,\|Executed \[1-9\]\[0-9\]\* tests\|Test run with \[1-9\]\[0-9\]\* tests/ { saw_nonzero_guard=1 }
    in_step && /Display resolution UI regression completed without executing any tests/ { saw_no_tests_message=1 }
    in_step && /^[[:space:]]*sleep 3$/ { saw_fixed_retry_sleep=1 }
    END { exit(saw_wait_pid && saw_stop_pid && saw_wait_cmux && saw_nonzero_guard && saw_no_tests_message && !saw_fixed_retry_sleep ? 0 : 1) }
  ' "$CI_FILE"; then
    echo "FAIL: ui-regressions must wait for app/helper cleanup and reject zero-test display regression runs"
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
    in_job && /name: Compute DerivedData cache fingerprint/ { saw_fingerprint_step=1 }
    in_job && /deriveddata-cache-fingerprint\.sh app/ { saw_fingerprint_mode=1 }
    in_job && /path: \.ci-derived-data\/build/ { saw_cache_path=1 }
    in_job && /key: deriveddata-build-\$\{\{ steps\.deriveddata-fingerprint\.outputs\.hash \}\}-\$\{\{ steps\.ghostty-revision\.outputs\.sha \}\}/ { saw_key=1 }
    in_job && /restore-keys:[[:space:]]*\|/ { in_restore=1; next }
    in_job && in_restore && /deriveddata-build-\$\{\{ steps\.deriveddata-fingerprint\.outputs\.hash \}\}-\$\{\{ steps\.ghostty-revision\.outputs\.sha \}\}-/ { saw_restore=1 }
    in_job && in_restore && /deriveddata-build-/ && !/steps\.deriveddata-fingerprint\.outputs\.hash/ { saw_broad_restore=1 }
    in_job && in_restore && /^[[:space:]]{10}[^[:space:]-]/ { in_restore=0 }
    in_job && /DERIVED_DATA_PATH="\$PWD\/\.ci-derived-data\/build"/ { saw_derived_data_env += 1 }
    in_job && /-derivedDataPath "\$DERIVED_DATA_PATH"/ { saw_derived_data=1 }
    END { exit(saw_fingerprint_step && saw_fingerprint_mode && saw_cache_path && saw_key && saw_restore && !saw_broad_restore && saw_derived_data_env >= 3 && saw_derived_data ? 0 : 1) }
  ' "$CI_FILE"; then
    echo "FAIL: tests-build-and-lag must restore and use its source-fingerprinted workspace-local DerivedData path so retries are not always cold"
    exit 1
  fi

  check_virtual_display_step_waits_for_readiness "$CI_FILE" "tests-build-and-lag"

  echo "PASS: tests-build-and-lag keeps enough time and restores source-fingerprinted DerivedData for cold builds"
}

check_compat_virtual_display_readiness() {
  check_virtual_display_step_waits_for_readiness "$COMPAT_FILE" "compat-tests"
}

check_ca_regression_launches_in_gui_bootstrap() {
  if ! grep -Fq 'launchctl asuser "$gui_uid"' "$CA_REGRESSION_SCRIPT"; then
    echo "FAIL: verify-main-thread-ca-transactions.sh must launch the app in the console GUI bootstrap when available"
    exit 1
  fi

  if ! grep -Fq 'stat -f %Su /dev/console' "$CA_REGRESSION_SCRIPT"; then
    echo "FAIL: verify-main-thread-ca-transactions.sh must resolve the console GUI user before launching the app"
    exit 1
  fi

  if ! grep -Fq 'CMUX_UI_TEST_SOCKET_SANITY=1' "$CA_REGRESSION_SCRIPT"; then
    echo "FAIL: verify-main-thread-ca-transactions.sh must keep socket sanity diagnostics enabled"
    exit 1
  fi

  echo "PASS: CoreAnimation startup verifier uses the console GUI bootstrap and keeps socket diagnostics"
}

check_zig_helper_build_runner() {
  local file="$1" job="$2"
  if ! awk -v job="$job" '
    $0 ~ "^  "job":" { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && /runs-on:.*vars\.MACOS_RUNNER_15/ { saw_runner=1 }
    in_job && /runs-on:.*warp-macos-15-arm64-6x/ { saw_fallback=1 }
    END { exit !(saw_runner && saw_fallback) }
  ' "$file"; then
    echo "FAIL: $job in $(basename "$file") must build the real Ghostty CLI helper on the macOS 15 lane until Zig 0.15.2 no longer links against the Xcode 26.4 SDK"
    exit 1
  fi

  echo "PASS: $job in $(basename "$file") builds the real Ghostty CLI helper away from the Xcode 26.4 Zig linker failure lane"
}

# ci.yml jobs
check_macos_runner "$CI_FILE" "tests"
check_macos_runner "$CI_FILE" "tests-build-and-lag"
check_macos_runner "$CI_FILE" "release-ghostty-cli-helper"
check_macos_runner "$CI_FILE" "release-build"
check_macos_runner "$CI_FILE" "ui-regressions"
check_self_hosted_workspace_prep "$CI_FILE" "tests"
check_self_hosted_workspace_prep "$CI_FILE" "tests-build-and-lag"
check_self_hosted_workspace_prep "$CI_FILE" "release-ghostty-cli-helper"
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
check_e2e_recording_preflight
check_e2e_ui_tests_require_nonzero_execution
check_self_hosted_workspace_prep "$E2E_FILE" "e2e"

# test-depot.yml is also manual, but it still needs the same self-hosted
# hygiene and fail-closed behavior as other macOS test workflows.
check_macos_runner "$TEST_DEPOT_FILE" "tests"
check_self_hosted_workspace_prep "$TEST_DEPOT_FILE" "tests"
check_test_depot_fails_closed

# perf-activation.yml
check_macos_runner "$PERF_FILE" "activation-session"
check_self_hosted_workspace_prep "$PERF_FILE" "activation-session"

# terminal-corpus-nightly.yml
check_macos_runner "$TERMINAL_CORPUS_NIGHTLY_FILE" "terminal-nightly"
check_self_hosted_workspace_prep "$TERMINAL_CORPUS_NIGHTLY_FILE" "terminal-nightly"

# release lanes
check_self_hosted_workspace_prep "$NIGHTLY_FILE" "build-sign-notarize-nightly"
check_self_hosted_workspace_prep "$RELEASE_FILE" "build-sign-notarize"

check_xcode_selection
check_workflow_yaml_parse
check_release_build_signal
check_no_xctest_quarantines
check_tmux_corpus_pr_jobs_do_not_report_skipped_terminal_tests
check_activation_artifacts_are_required
check_retryable_submodule_checkout
check_split_theme_regression_timeout
check_command_palette_nucleo_ffi_coverage
check_web_db_behavior_test_coverage
check_swift_package_tests_require_nonzero_execution
check_xcodebuild_unit_step_requires_nonzero_execution "$CI_FILE" "Run unit tests" "Unit test workflow completed without executing any tests"
check_xcodebuild_unit_step_requires_nonzero_execution "$COMPAT_FILE" "Run unit tests" "Compatibility unit tests completed without executing any tests"
check_xcodebuild_unit_step_requires_nonzero_execution "$TERMINAL_CORPUS_NIGHTLY_FILE" "Run terminal corpus unit tests" "Terminal corpus unit tests completed without executing any tests"
check_xcodebuild_unit_step_allows_expected_failures "$CI_FILE" "Run unit tests"
check_xcodebuild_unit_step_allows_expected_failures "$COMPAT_FILE" "Run unit tests"
check_tests_deriveddata_cache
check_ui_regression_budget
check_build_and_lag_budget
check_compat_virtual_display_readiness
check_ca_regression_launches_in_gui_bootstrap
check_zig_helper_build_runner "$CI_FILE" "release-ghostty-cli-helper"
check_zig_helper_build_runner "$RELEASE_FILE" "build-ghostty-cli-helper"
