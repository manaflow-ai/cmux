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
TEST_IOS_FILE="$ROOT_DIR/.github/workflows/test-ios.yml"
NIGHTLY_FILE="$ROOT_DIR/.github/workflows/nightly.yml"
RELEASE_FILE="$ROOT_DIR/.github/workflows/release.yml"
TEST_DEPOT_FILE="$ROOT_DIR/.github/workflows/test-depot.yml"
TMUX_CORPUS_FILE="$ROOT_DIR/.github/workflows/tmux-corpus.yml"
TERMINAL_CORPUS_NIGHTLY_FILE="$ROOT_DIR/.github/workflows/terminal-corpus-nightly.yml"
CA_REGRESSION_SCRIPT="$ROOT_DIR/scripts/verify-main-thread-ca-transactions.sh"
CMUX_UNIT_ISOLATED_RUNNER="$ROOT_DIR/scripts/ci/run-cmux-unit-tests-isolated.sh"
E2E_FILTER_VALIDATOR="$ROOT_DIR/scripts/ci/validate-e2e-test-filter.sh"

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

check_ios_change_detection_covers_workflow_trigger() {
  if ! grep -Fq '.github/workflows/test-ios.yml' "$TEST_IOS_FILE"; then
    echo "FAIL: test-ios.yml pull_request paths must trigger when the iOS workflow changes"
    exit 1
  fi

  if ! grep -Fq '\.github/workflows/test-ios\.yml$' "$TEST_IOS_FILE"; then
    echo "FAIL: test-ios.yml change detector must run iOS jobs when the iOS workflow itself changes"
    exit 1
  fi

  echo "PASS: test-ios.yml change detector covers workflow-triggered iOS changes"
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

check_e2e_ui_tests_skip_zig_helper_build() {
  if ! awk '
    /^[[:space:]]*- name: Run UI tests$/ { in_step=1; saw_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /XCODEBUILD_ENV=\(/ { in_env=1; saw_env=1; next }
    in_env && /\)/ { in_env=0 }
    in_env && /CMUX_SKIP_ZIG_BUILD=1/ { saw_skip=1 }
    in_step && /xcodebuild -project cmux\.xcodeproj -scheme cmux -configuration Debug/ { saw_xcodebuild=1 }
    END { exit(saw_step && saw_env && saw_skip && saw_xcodebuild ? 0 : 1) }
  ' "$E2E_FILE"; then
    echo "FAIL: test-e2e.yml must set CMUX_SKIP_ZIG_BUILD=1 for UI-test xcodebuild so manual E2E cannot fail on Ghostty helper Zig dependency fetches"
    exit 1
  fi

  echo "PASS: test-e2e.yml skips the Ghostty helper Zig build during UI-test app builds"
}

check_e2e_test_filter_validation() {
  if [ ! -x "$E2E_FILTER_VALIDATOR" ]; then
    echo "FAIL: validate-e2e-test-filter.sh must be executable"
    exit 1
  fi

  if [ "$("$E2E_FILTER_VALIDATOR" UpdatePillUITests)" != "UpdatePillUITests" ]; then
    echo "FAIL: E2E filter validator must accept macOS UI test classes"
    exit 1
  fi

  if [ "$("$E2E_FILTER_VALIDATOR" cmuxUITests/UpdatePillUITests/testUpdatePillShowsForAvailableUpdate)" != "UpdatePillUITests/testUpdatePillShowsForAvailableUpdate" ]; then
    echo "FAIL: E2E filter validator must normalize explicit macOS target prefixes"
    exit 1
  fi

  local err
  err="$(mktemp)"
  if "$E2E_FILTER_VALIDATOR" cmuxUITests/testWorkspaceToolbarCreatesWorkspaceAndTerminal > /dev/null 2>"$err"; then
    echo "FAIL: E2E filter validator must reject iOS-only UI test filters before xcodebuild"
    rm -f "$err"
    exit 1
  fi
  if ! grep -Fq ".github/workflows/test-ios.yml" "$err"; then
    echo "FAIL: E2E filter validator must point iOS UI test filters to test-ios.yml"
    cat "$err"
    rm -f "$err"
    exit 1
  fi
  rm -f "$err"

  err="$(mktemp)"
  if "$E2E_FILTER_VALIDATOR" UpdatePillUITests/testDoesNotExist > /dev/null 2>"$err"; then
    echo "FAIL: E2E filter validator must reject missing macOS UI test methods"
    rm -f "$err"
    exit 1
  fi
  if ! grep -Fq "available test methods:" "$err"; then
    echo "FAIL: E2E filter validator must list available methods for a missing method"
    cat "$err"
    rm -f "$err"
    exit 1
  fi
  rm -f "$err"

  if ! awk '
    /^[[:space:]]*- name: Validate test filter$/ { saw_validate=1; in_validate=1; next }
    in_validate && /^[[:space:]]*- name:/ { in_validate=0 }
    in_validate && /validate-e2e-test-filter\.sh "\$TEST_FILTER"/ { saw_validator=1 }
    in_validate && /echo "test_filter=\$normalized" >> "\$GITHUB_OUTPUT"/ { saw_output=1 }
    in_validate && /echo "TEST_FILTER=\$normalized" >> "\$GITHUB_ENV"/ { saw_env=1 }
    /^[[:space:]]*- name: Install Bun for Feed sidebar tests$/ { in_bun=1; next }
    in_bun && /^[[:space:]]*- name:/ { in_bun=0 }
    in_bun && /steps\.validate-filter\.outputs\.test_filter == '\''FeedSidebarUITests'\''/ { saw_feed_class=1 }
    in_bun && /startsWith\(steps\.validate-filter\.outputs\.test_filter, '\''FeedSidebarUITests\/'\''\)/ { saw_feed_method=1 }
    /^[[:space:]]*- name: Create virtual display$/ { in_display=1; next }
    in_display && /^[[:space:]]*- name:/ { in_display=0 }
    in_display && /steps\.validate-filter\.outputs\.test_filter != '\''DisplayResolutionRegressionUITests'\''/ { saw_display=1 }
    /^[[:space:]]*- name: Initialize submodules with retry$/ { saw_init=1; if (saw_validate) validate_before_init=1 }
    /^[[:space:]]*- name: Select Xcode$/ { saw_select_xcode=1; if (saw_validate) validate_before_xcode=1 }
    END { exit(saw_validate && saw_validator && saw_output && saw_env && saw_feed_class && saw_feed_method && saw_display && saw_init && saw_select_xcode && validate_before_xcode && !validate_before_init ? 0 : 1) }
  ' "$E2E_FILE"; then
    echo "FAIL: test-e2e.yml must validate manual test filters after checkout/submodules, expose the normalized selector, and use it for selector-specific setup"
    exit 1
  fi

  if ! grep -Fq 'validate-e2e-test-filter.sh" "$TEST_FILTER"' "$ROOT_DIR/scripts/run-e2e.sh"; then
    echo "FAIL: run-e2e.sh must validate test filters before dispatch"
    exit 1
  fi

  echo "PASS: test-e2e.yml validates manual UI test filters before expensive setup"
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
    in_step && /seq 1 900/ { saw_long_poll=1 }
    in_step && /^[[:space:]]*sleep 3$/ { saw_fixed_sleep=1 }
    END { exit(saw_step && saw_ready_arg && saw_id_arg && saw_ready_poll && saw_exit_message && saw_timeout_message && saw_long_poll && !saw_fixed_sleep ? 0 : 1) }
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
    in_step && /seq 1 900/ { saw_long_poll=1 }
    in_step && /^[[:space:]]*sleep 3$/ { saw_fixed_sleep=1 }
    END { exit(saw_ready_arg && saw_id_arg && saw_ready_poll && saw_exit_message && saw_timeout_message && saw_long_poll && !saw_fixed_sleep ? 0 : 1) }
  ' "$TEST_DEPOT_FILE"; then
    echo "FAIL: test-depot.yml must wait for virtual display readiness files instead of using a fixed sleep"
    exit 1
  fi

  if ! awk '
    /^[[:space:]]*- name: Run unit tests$/ { in_unit=1; next }
    in_unit && /^[[:space:]]*- name:/ { in_unit=0 }
    in_unit && /scripts\/ci\/run-cmux-unit-tests-isolated\.sh/ { saw_unit_runner=1 }
    in_unit && /All \[1-9\]\[0-9\]\* selected cmuxTests XCTestCase classes and Swift Testing suites passed in shard-\.\* batches/ { saw_unit_guard=1 }
    in_unit && /Unit test workflow completed without executing any tests/ { saw_unit_message=1 }
    /^[[:space:]]*- name: Run UI tests$/ { in_ui=1; next }
    in_ui && /^[[:space:]]*- name:/ { in_ui=0 }
    in_ui && /scripts\/ci\/xcodebuild_noninteractive\.py/ { saw_ui_wrapper=1 }
    in_ui && /Executed \[1-9\]\[0-9\]\* test,\|Executed \[1-9\]\[0-9\]\* tests\|Test run with \[1-9\]\[0-9\]\* tests/ { saw_ui_guard=1 }
    in_ui && /UI test workflow completed without executing any tests/ { saw_ui_message=1 }
    END { exit(saw_unit_runner && saw_unit_guard && saw_unit_message && saw_ui_wrapper && saw_ui_guard && saw_ui_message ? 0 : 1) }
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

check_no_debug_xctest_self_skips() {
  if grep -R -n -E 'XCTSkip\("([^"]*(DEBUG|Debug|debug)[^"]*)"\)' "$ROOT_DIR/cmuxTests"; then
    echo "FAIL: DEBUG-only XCTest regressions must fail closed, not silently skip"
    exit 1
  fi

  echo "PASS: DEBUG-only XCTest regressions fail closed instead of skipping"
}

check_ui_expected_failures_are_activation_scoped() {
  local failed=0
  while IFS= read -r -d '' file; do
    local option_vars=" "
    local non_strict_vars=" "
    local line line_no=0
    while IFS= read -r line; do
      line_no=$((line_no + 1))
      if [[ "$line" == *"XCTExpectedFailure.Options()"* ]]; then
        local options_var
        options_var="$(printf '%s\n' "$line" | sed -nE 's/.*let[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\1/p')"
        if [ -n "$options_var" ]; then
          option_vars="$option_vars$options_var "
        fi
      fi

      if [[ "$line" == *".isStrict"* && "$line" == *"false"* ]]; then
        local strict_var
        strict_var="$(printf '%s\n' "$line" | sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)\.isStrict[[:space:]]*=[[:space:]]*false.*/\1/p')"
        if [ -n "$strict_var" ]; then
          non_strict_vars="$non_strict_vars$strict_var "
        fi
      fi

      if [[ "$line" == *"XCTExpectFailure("* ]]; then
        local parsed message options_name
        parsed="$(printf '%s\n' "$line" | sed -nE 's/.*XCTExpectFailure\("([^"]+)",[[:space:]]*options:[[:space:]]*([A-Za-z_][A-Za-z0-9_]*).*/\1	\2/p')"
        if [ -z "$parsed" ]; then
          printf '%s:%s: unsupported XCTExpectFailure shape: %s\n' "$file" "$line_no" "$line"
          failed=1
          continue
        fi
        IFS=$'\t' read -r message options_name <<< "$parsed"
        case "$message" in
          "App activation may fail on headless CI runners" | \
          "App activation may fail on headless GUI runners" | \
          "Headless CI may launch the app without foreground activation" | \
          "App could not be foregrounded on this runner")
            ;;
          *)
            printf '%s:%s: unsupported XCTExpectFailure message: %s\n' "$file" "$line_no" "$message"
            failed=1
            ;;
        esac
        if [[ "$option_vars" != *" $options_name "* || "$non_strict_vars" != *" $options_name "* ]]; then
          printf '%s:%s: XCTExpectFailure options must be declared and set isStrict=false: %s\n' "$file" "$line_no" "$line"
          failed=1
        fi
      fi
    done < "$file"
  done < <(find "$ROOT_DIR/cmuxUITests" -name '*.swift' -print0)

  if [ "$failed" -ne 0 ]; then
    echo "FAIL: UI expected failures must stay non-strict and scoped to headless launch/activation only"
    exit 1
  fi

  echo "PASS: UI expected failures stay non-strict and scoped to headless launch/activation"
}

check_port_scanner_fd_regression_fails_closed_on_ci() {
  local file="$ROOT_DIR/cmuxTests/PortScannerTests.swift"
  if ! grep -Fq "hosted CI must exercise PortScanner pipe FD leak coverage" "$file"; then
    echo "FAIL: PortScanner FD leak regression must fail closed on hosted CI when /dev/fd inspection is unavailable"
    exit 1
  fi
  if ! grep -Fq 'environment["CI"] == "true" || environment["GITHUB_ACTIONS"] == "true"' "$file"; then
    echo "FAIL: PortScanner FD leak regression must explicitly distinguish hosted CI from local resource skips"
    exit 1
  fi

  echo "PASS: PortScanner FD leak regression fails closed on hosted CI"
}

check_cmux_config_icon_fixture_fails_closed() {
  local file="$ROOT_DIR/cmuxTests/CmuxConfigContextMenuTests.swift"
  if grep -Fq 'XCTSkip("Could not generate PNG data for icon test.")' "$file"; then
    echo "FAIL: CmuxConfig context-menu icon tests must fail closed when their PNG fixture cannot be generated"
    exit 1
  fi
  if ! grep -Fq 'XCTFail(message)' "$file"; then
    echo "FAIL: CmuxConfig context-menu icon tests must report PNG fixture generation failures"
    exit 1
  fi

  echo "PASS: CmuxConfig context-menu icon fixture failures fail closed"
}

check_ssh_fish_shell_regression_fails_closed_on_ci() {
  local file="$ROOT_DIR/cmuxTests/WorkspaceSSHFishShellTests.swift"
  if ! grep -Fq "hosted CI must exercise SSH bootstrap fish shell coverage" "$file"; then
    echo "FAIL: WorkspaceSSHFishShellTests must fail closed on hosted CI when required tools are missing"
    exit 1
  fi
  if ! grep -Fq 'environment["CI"] == "true" || environment["GITHUB_ACTIONS"] == "true"' "$file"; then
    echo "FAIL: WorkspaceSSHFishShellTests must explicitly distinguish hosted CI from local resource skips"
    exit 1
  fi

  echo "PASS: SSH fish shell regression fails closed on hosted CI"
}

check_ssh_fish_shell_socket_fixture_fails_closed() {
  local file="$ROOT_DIR/cmuxTests/WorkspaceSSHFishShellTests.swift"
  if grep -Fq 'throw XCTSkip("Unix socket path too long for sockaddr_un:' "$file"; then
    echo "FAIL: WorkspaceSSHFishShellTests must fail closed when its generated Unix socket fixture path is invalid"
    exit 1
  fi
  if ! grep -Fq 'XCTFail(message)' "$file"; then
    echo "FAIL: WorkspaceSSHFishShellTests must report generated Unix socket fixture failures"
    exit 1
  fi

  echo "PASS: SSH fish shell generated socket fixture failures fail closed"
}

check_settings_frame_clamping_fails_closed_on_ci() {
  local file="$ROOT_DIR/cmuxTests/SettingsWindowPresenterTests.swift"
  if ! grep -Fq "hosted CI must exercise Settings frame clamping" "$file"; then
    echo "FAIL: Settings frame clamping regression must fail closed on hosted CI when NSScreen is unavailable"
    exit 1
  fi
  if ! grep -Fq 'environment["CI"] == "true" || environment["GITHUB_ACTIONS"] == "true"' "$file"; then
    echo "FAIL: Settings frame clamping regression must explicitly distinguish hosted CI from local screen availability skips"
    exit 1
  fi

  echo "PASS: Settings frame clamping regression fails closed on hosted CI"
}

check_browser_audio_mute_fails_closed_on_ci() {
  local file="$ROOT_DIR/cmuxTests/TabManagerUnitTests.swift"
  if grep -Fq 'throw XCTSkip("WKWebView page-audio mute selector is unavailable")' "$file"; then
    echo "FAIL: browser audio mute regressions must fail closed on hosted CI when WKWebView page-audio mute support is unavailable"
    exit 1
  fi
  if ! grep -Fq "hosted CI must exercise browser audio mute coverage" "$file"; then
    echo "FAIL: browser audio mute regressions must fail closed on hosted CI when WKWebView page-audio mute support is unavailable"
    exit 1
  fi
  if ! grep -Fq 'environment["CI"] == "true" || environment["GITHUB_ACTIONS"] == "true"' "$file"; then
    echo "FAIL: browser audio mute regressions must explicitly distinguish hosted CI from local WebKit capability skips"
    exit 1
  fi

  echo "PASS: browser audio mute regressions fail closed on hosted CI"
}

check_cli_socket_namespace_fails_closed_on_ci() {
  local file="$ROOT_DIR/cmuxTests/CMUXCLIErrorOutputRegressionTests.swift"
  if ! grep -Fq "hosted tests require an isolated runner socket namespace" "$file"; then
    echo "FAIL: CLI socket routing regressions must fail closed on hosted CI when stable socket paths are already occupied"
    exit 1
  fi
  if ! grep -Fq 'environment["CI"] == "true" || environment["GITHUB_ACTIONS"] == "true"' "$file"; then
    echo "FAIL: CLI socket routing regressions must explicitly distinguish hosted CI from local socket namespace skips"
    exit 1
  fi
  if ! grep -Fq 'throw XCTSkip(message)' "$file"; then
    echo "FAIL: CLI socket routing regressions should keep the local socket namespace skip for developer machines"
    exit 1
  fi

  echo "PASS: CLI socket namespace regressions fail closed on hosted CI"
}

check_cmux_top_process_fixture_fails_closed_on_ci() {
  local file="$ROOT_DIR/cmuxTests/CmuxTopSnapshotScopeTests.swift"
  if ! grep -Fq 'hostedProcessFixtureErrorOrSkip' "$file"; then
    echo "FAIL: cmux top process fixture regressions must have a shared hosted-CI fail-closed helper"
    exit 1
  fi
  if ! grep -Fq 'environment["CI"] == "true" || environment["GITHUB_ACTIONS"] == "true"' "$file"; then
    echo "FAIL: cmux top process fixture regressions must explicitly distinguish hosted CI from local fixture skips"
    exit 1
  fi
  if ! grep -Fq 'XCTFail(message, file: file, line: line)' "$file"; then
    echo "FAIL: cmux top process fixture regressions must fail on hosted CI when process fixtures are unavailable"
    exit 1
  fi
  if ! grep -Fq 'return XCTSkip(message)' "$file"; then
    echo "FAIL: cmux top process fixture regressions should keep the local fixture skip for developer machines"
    exit 1
  fi

  echo "PASS: cmux top process fixture regressions fail closed on hosted CI"
}

check_file_explorer_search_fails_closed_on_ci() {
  local file="$ROOT_DIR/cmuxTests/FileExplorerStoreTests.swift"
  if ! grep -Fq "hosted CI must exercise FileExplorer search behavior" "$file"; then
    echo "FAIL: FileExplorer search regressions must fail closed on hosted CI when ripgrep is unavailable"
    exit 1
  fi
  if ! grep -Fq 'environment["CI"] == "true" || environment["GITHUB_ACTIONS"] == "true"' "$file"; then
    echo "FAIL: FileExplorer search regressions must explicitly distinguish hosted CI from local tool skips"
    exit 1
  fi
  if ! grep -Fq 'throw XCTSkip(message)' "$file"; then
    echo "FAIL: FileExplorer search regressions should keep the local ripgrep skip for developer machines"
    exit 1
  fi

  echo "PASS: FileExplorer search regressions fail closed on hosted CI"
}

check_cli_notify_bundled_cli_fails_closed_on_ci() {
  local file="$ROOT_DIR/cmuxTests/CLINotifyProcessTestSupport.swift"
  if ! grep -Fq "Bundled cmux CLI not found" "$file"; then
    echo "FAIL: CLI notify regressions must report missing bundled CLI fixtures"
    exit 1
  fi
  if ! grep -Fq 'environment["CI"] == "true" || environment["GITHUB_ACTIONS"] == "true"' "$file"; then
    echo "FAIL: CLI notify regressions must explicitly distinguish hosted CI from local bundled CLI skips"
    exit 1
  fi
  if ! grep -Fq 'XCTFail(message, file: file, line: line)' "$file"; then
    echo "FAIL: CLI notify regressions must fail on hosted CI when the bundled CLI fixture is missing"
    exit 1
  fi
  if ! grep -Fq 'return XCTSkip(message)' "$file"; then
    echo "FAIL: CLI notify regressions should keep the local bundled CLI skip for developer machines"
    exit 1
  fi

  echo "PASS: CLI notify bundled CLI regressions fail closed on hosted CI"
}

check_no_swift_test_skip_quarantines() {
  if grep -R -n -E "swift[[:space:]]+test([^|;&]*[[:space:]])--skip([[:space:]]|=)" "$ROOT_DIR/.github/workflows"; then
    echo "FAIL: workflow Swift package tests must not hide coverage with swift test --skip quarantines"
    exit 1
  fi

  echo "PASS: workflows do not hide Swift package coverage with swift test --skip"
}

check_vm_socket_tests_do_not_skip_ctrl_interactive() {
  for script in "$ROOT_DIR/scripts/run-tests-v1.sh" "$ROOT_DIR/scripts/run-tests-v2.sh"; do
    if grep -n "test_ctrl_interactive.py" "$script" | grep -Eq "SKIP|continue"; then
      echo "FAIL: $(basename "$script") must run test_ctrl_interactive.py so Ctrl+C/Ctrl+D terminal delivery stays covered"
      exit 1
    fi
  done

  echo "PASS: VM socket runners include Ctrl+C/Ctrl+D terminal delivery regression"
}

check_vm_socket_tests_do_not_self_skip() {
  if grep -R -n --exclude-dir=__pycache__ -E "class[[:space:]]+cmuxSkip|raise[[:space:]]+cmuxSkip" "$ROOT_DIR/tests" "$ROOT_DIR/tests_v2"; then
    echo "FAIL: VM socket tests must not use custom cmuxSkip exceptions to hide app behavior failures"
    exit 1
  fi

  echo "PASS: VM socket tests do not use custom self-skip exceptions"
}

check_vm_socket_runners_fail_closed_without_test_retries() {
  local script
  for script in "$ROOT_DIR/scripts/run-tests-v1.sh" "$ROOT_DIR/scripts/run-tests-v2.sh"; do
    if grep -n -E "run_test_with_retry|attempts=3|relaunching and retrying" "$script"; then
      echo "FAIL: $(basename "$script") must fail closed on the first Python VM socket test failure instead of retrying until green"
      exit 1
    fi
    if ! grep -Fq 'if ! python3 "$f"; then' "$script"; then
      echo "FAIL: $(basename "$script") must execute each Python VM socket test directly so failures are not masked"
      exit 1
    fi
  done

  echo "PASS: VM socket runners fail closed without broad per-test retries"
}

check_retryable_submodule_checkout() {
  if ! grep -Fq 'attempts="${CMUX_SUBMODULE_RETRY_ATTEMPTS:-5}"' "$ROOT_DIR/scripts/ci/init-submodules-with-retry.sh"; then
    echo "FAIL: submodule retry wrapper must default to at least 5 attempts for transient GitHub connectivity outages"
    exit 1
  fi

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
    in_step && /Executed \[1-9\]\[0-9\]\* test,\|Executed \[1-9\]\[0-9\]\* tests\|Test run with \[1-9\]\[0-9\]\* tests/ { saw_nonzero_guard=1 }
    in_step && /Ghostty split-theme appearance regression completed without executing any tests/ { saw_no_tests_message=1 }
    END { exit(saw_wrapper && saw_timeout && saw_timeout_message && saw_cargo_retry && saw_static_crates_match && saw_nonzero_guard && saw_no_tests_message ? 0 : 1) }
  ' "$CI_FILE"; then
    echo "FAIL: split-theme XCTest regression must use noninteractive xcodebuild, a step timeout, a Cargo registry retry, and a nonzero test execution guard"
    exit 1
  fi

  echo "PASS: split-theme XCTest regression uses noninteractive xcodebuild with timeout, Cargo registry retry, and nonzero test execution guard"
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

  if ! grep -Fq "focused nucleo FFI lane skipped selected XCTest coverage" "$script"; then
    echo "FAIL: test-command-palette-nucleo-ffi.sh must fail if selected FFI-backed XCTest coverage skips"
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

check_terminal_corpus_requires_live_ghostty_surface() {
  if ! awk '
    /^[[:space:]]*- name: Run terminal corpus unit tests$/ { in_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /CMUX_REQUIRE_LIVE_GHOSTTY_SURFACE:[[:space:]]*"1"/ { saw_env=1 }
    in_step && /GhosttyCommandShiftForwardingTests.*skipped/ { saw_skip_guard=1 }
    in_step && /Ghostty surface failed to initialize/ { saw_live_surface_guard=1 }
    in_step && /Terminal corpus unit tests skipped GhosttyCommandShiftForwardingTests live-surface coverage/ { saw_message=1 }
    END { exit(saw_env && saw_skip_guard && saw_live_surface_guard && saw_message ? 0 : 1) }
  ' "$TERMINAL_CORPUS_NIGHTLY_FILE"; then
    echo "FAIL: terminal-corpus-nightly.yml must fail if GhosttyCommandShiftForwardingTests skips live Ghostty surface coverage"
    exit 1
  fi

  if ! grep -Fq 'CMUX_REQUIRE_LIVE_GHOSTTY_SURFACE' "$ROOT_DIR/cmuxTests/GhosttyCommandShiftForwardingTests.swift"; then
    echo "FAIL: GhosttyCommandShiftForwardingTests must honor the terminal corpus live-surface requirement"
    exit 1
  fi

  echo "PASS: terminal corpus requires live Ghostty surface coverage"
}

check_web_db_behavior_test_coverage() {
  if ! awk '
    /^  web-db-migrations:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && /services:/ { saw_services=1 }
    in_job && /^[[:space:]]*- name: Start Postgres$/ { in_start=1; saw_start=1; next }
    in_start && /^[[:space:]]*- name:/ { in_start=0 }
    in_start && /docker run -d/ { saw_docker_run=1 }
    in_start && /POSTGRES_DB=cmux_test/ { saw_db=1 }
    in_start && /-p 127\.0\.0\.1:5432:5432/ { saw_local_port=1 }
    in_start && /postgres:16-alpine/ { saw_image=1 }
    in_start && /for attempt in 1 2 3/ { saw_retry=1 }
    in_start && /pg_isready -U cmux -d cmux_test/ { saw_ready=1 }
    in_start && /docker logs "\$container"/ { saw_logs=1 }
    in_job && /^[[:space:]]*- name: Database behavior tests$/ { in_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /CMUX_DB_TEST: "1"/ { saw_cmux_db_test=1 }
    in_step && /DATABASE_URL: postgres:\/\/cmux:cmux@localhost:5432\/cmux_test/ { saw_database_url=1 }
    in_step && /DIRECT_DATABASE_URL: postgres:\/\/cmux:cmux@localhost:5432\/cmux_test/ { saw_direct_database_url=1 }
    in_step && /run: bun run test:db:behavior/ { saw_command=1 }
    in_job && /^[[:space:]]*- name: Stop Postgres$/ { in_stop=1; saw_stop=1; next }
    in_stop && /^[[:space:]]*- name:/ { in_stop=0 }
    in_stop && /if: always\(\)/ { saw_always=1 }
    in_stop && /docker rm -f "\$CMUX_CI_POSTGRES_CONTAINER"/ { saw_cleanup=1 }
    END { exit(!saw_services && saw_start && saw_docker_run && saw_db && saw_local_port && saw_image && saw_retry && saw_ready && saw_logs && saw_cmux_db_test && saw_database_url && saw_direct_database_url && saw_command && saw_stop && saw_always && saw_cleanup ? 0 : 1) }
  ' "$CI_FILE"; then
    echo "FAIL: web-db-migrations must start Postgres with retryable Docker setup, run CMUX_DB_TEST-gated web behavior tests, and clean up the container"
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
  if ! grep -Fq "skipped tests while CMUX_DB_TEST=1" "$script"; then
    echo "FAIL: run-db-behavior-tests.sh must reject skipped DB behavior tests when CMUX_DB_TEST=1"
    exit 1
  fi
  if ! grep -Fq "^[[:space:]]*[1-9][0-9]* skips?$" "$script"; then
    echo "FAIL: run-db-behavior-tests.sh must detect Bun skipped-test summaries"
    exit 1
  fi

  if ! grep -Fq '"test:db:behavior": "bash scripts/run-db-behavior-tests.sh"' "$ROOT_DIR/web/package.json"; then
    echo "FAIL: web package.json must keep test:db:behavior wired to run-db-behavior-tests.sh"
    exit 1
  fi

  echo "PASS: web DB behavior tests run in CI with CMUX_DB_TEST and Postgres"
}

check_bundled_ghostty_helper_regression_coverage() {
  if ! awk '
    /^[[:space:]]*- name: Run bundled Ghostty theme picker helper regression$/ { in_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /CMUX_SKIP_ZIG_BUILD=0/ { saw_real_helper=1 }
    in_step && /\.\/tests\/test_bundled_ghostty_theme_picker_helper\.sh/ { saw_script=1 }
    END { exit(saw_real_helper && saw_script ? 0 : 1) }
  ' "$CI_FILE"; then
    echo "FAIL: ci.yml must run the bundled Ghostty theme picker helper regression with the real Zig-built helper"
    exit 1
  fi

  if ! awk '
    /^[[:space:]]*- name: Run bundled Ghostty theme picker helper regression$/ { in_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /CMUX_APP_PATH="build-universal\/Build\/Products\/Release\/cmux\.app"/ { saw_app_path=1 }
    in_step && /\.\/tests\/test_bundled_ghostty_theme_picker_helper\.sh/ { saw_script=1 }
    END { exit(saw_app_path && saw_script ? 0 : 1) }
  ' "$NIGHTLY_FILE"; then
    echo "FAIL: nightly.yml must run the bundled Ghostty theme picker helper regression against the Release app"
    exit 1
  fi

  if ! awk '
    /^[[:space:]]*- name: Verify bundled Ghostty theme picker helper$/ { in_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /CMUX_APP_PATH="build-universal\/Build\/Products\/Release\/cmux\.app"/ { saw_app_path=1 }
    in_step && /\.\/tests\/test_bundled_ghostty_theme_picker_helper\.sh/ { saw_script=1 }
    END { exit(saw_app_path && saw_script ? 0 : 1) }
  ' "$RELEASE_FILE"; then
    echo "FAIL: release.yml must run the bundled Ghostty theme picker helper regression against the Release app"
    exit 1
  fi

  local script="$ROOT_DIR/tests/test_bundled_ghostty_theme_picker_helper.sh"
  if ! grep -Fq 'bundled Ghostty helper regression cannot skip the real Zig-built helper in CI' "$script"; then
    echo "FAIL: bundled Ghostty helper regression must fail closed instead of skipping when CMUX_SKIP_ZIG_BUILD leaks into CI"
    exit 1
  fi

  echo "PASS: bundled Ghostty theme picker helper regression stays active in CI, nightly, and release"
}

check_swift_package_tests_require_nonzero_execution() {
  if ! awk '
    function reset_step() {
      saw_swift_test=0
      saw_capture=0
      saw_nonzero_guard=0
      saw_failure_message=0
    }
    function finish_step() {
      if (!in_step) {
        return
      }
      steps += 1
      if (!(saw_swift_test && saw_capture && saw_nonzero_guard && saw_failure_message)) {
        bad_step=1
      }
      in_step=0
      reset_step()
    }
    /^[[:space:]]*- name: Run Swift package unit tests$/ { finish_step(); in_step=1; reset_step(); next }
    in_step && /^[[:space:]]*- name:/ { finish_step() }
    in_step && /swift test --package-path "Packages\/\$pkg"/ { saw_swift_test=1 }
    in_step && /tee "\$output_file"/ { saw_capture=1 }
    in_step && /Executed \[1-9\]\[0-9\]\* test,\|Executed \[1-9\]\[0-9\]\* tests\|Test run with \[1-9\]\[0-9\]\* tests/ { saw_nonzero_guard=1 }
    in_step && /completed without executing any tests/ { saw_failure_message=1 }
    END { finish_step(); exit(steps > 0 && !bad_step ? 0 : 1) }
  ' "$CI_FILE"; then
    echo "FAIL: every Swift package unit-test lane must fail if a listed package completes without executing any XCTest or Swift Testing tests"
    exit 1
  fi

  echo "PASS: Swift package unit-test lanes reject zero-test package runs"
}

check_standalone_swift_package_tests_are_wired() {
  local packages=(
    CMUXAgentLaunch
    CMUXAgentVault
    CMUXAuthCore
    CMUXDebugLog
    CMUXPasteboardFidelity
    CMUXProjectModel
    CMUXWorkstream
    CmuxAuthRuntime
    CmuxControlSocket
    CmuxExtensionKit
    CmuxFileWatch
    CmuxFoundation
    CmuxGit
    CmuxProcess
    CmuxSettings
    CmuxSettingsUI
    CmuxSidebarInterpreterService
    CmuxSocketControl
    CmuxSwiftRender
    CmuxSwiftRenderUI
    CmuxTerminalCopyMode
    CmuxUpdater
    CmuxUpdaterUI
  )

  for pkg in "${packages[@]}"; do
    if ! grep -Eq "^[[:space:]]{12}${pkg}$" "$CI_FILE"; then
      echo "FAIL: standalone Swift package tests for $pkg must be wired into the CI package-test lane"
      exit 1
    fi
  done

  echo "PASS: standalone Swift package test targets are wired into CI"
}

check_xcodebuild_unit_step_requires_nonzero_execution() {
  local file="$1" step="$2" message="$3"
  local require_class_sharding="${4:-0}"
  if ! awk -v step="$step" -v message="$message" -v require_class_sharding="$require_class_sharding" '
    index($0, "- name: " step) { in_step=1; saw_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /scripts\/ci\/xcodebuild_noninteractive\.py/ { saw_wrapper=1 }
    in_step && /scripts\/ci\/run-cmux-unit-tests-isolated\.sh/ { saw_sharded_runner=1 }
    in_step && /Executed \[1-9\]\[0-9\]\* test,\|Executed \[1-9\]\[0-9\]\* tests\|Test run with \[1-9\]\[0-9\]\* tests/ { saw_nonzero_guard=1 }
    in_step && /All \[1-9\]\[0-9\]\* selected cmuxTests XCTestCase classes and Swift Testing suites passed in shard-\.\* batches/ { saw_shard_nonzero_guard=1 }
    in_step && index($0, message) { saw_message=1 }
    END {
      if (require_class_sharding) {
        exit(saw_step && saw_sharded_runner && saw_shard_nonzero_guard && saw_message ? 0 : 1)
      }
      exit(saw_step && saw_wrapper && saw_nonzero_guard && saw_message ? 0 : 1)
    }
  ' "$file"; then
    if [ "$require_class_sharding" = "1" ]; then
      echo "FAIL: $step in $(basename "$file") must use the class-sharded app-host runner and reject zero-test success"
    else
      echo "FAIL: $step in $(basename "$file") must run xcodebuild noninteractively and reject zero-test success"
    fi
    exit 1
  fi

  if [ "$require_class_sharding" = "1" ]; then
    echo "PASS: $step in $(basename "$file") uses class-sharded app-host unit tests and rejects zero-test runs"
  else
    echo "PASS: $step in $(basename "$file") rejects zero-test xcodebuild runs"
  fi
}

check_cmux_unit_isolated_runner() {
  for pattern in \
    "build-for-testing" \
    "test-without-building" \
    '-derivedDataPath "$DERIVED_DATA_PATH"' \
    '-only-testing:cmuxTests/$class' \
    '"${ONLY_TESTING_ARGS[@]}"' \
    'env -u SSH_AUTH_SOCK' \
    'CMUX_UNIT_TEST_BATCH_SIZE must be a positive integer' \
    'HOME="$home_path"' \
    'CFFIXED_USER_HOME="$home_path"' \
    'candidate_kind = "xctest"' \
    '\bfunc\s+test[A-Za-z0-9_]*\s*\(' \
    '\@Test\b' \
    '\@Suite\b' \
    'CMUX_UI_TEST_SUPPRESS_SYSTEM_NOTIFICATIONS=1' \
    'RUSTUP_HOME="$ORIGINAL_HOME/.rustup" CARGO_HOME="$ORIGINAL_HOME/.cargo"' \
    'SHARD_INDEX="${CMUX_UNIT_TEST_SHARD_INDEX:-0}"' \
    'SHARD_COUNT="${CMUX_UNIT_TEST_SHARD_COUNT:-1}"' \
    'class_hash="$(printf '\''%s'\'' "$test_identifier" | cksum | awk '\''{print $1}'\'')"' \
    'if [ $((class_hash % SHARD_COUNT)) -eq "$SHARD_INDEX" ]; then' \
    'BATCH_SIZE="${CMUX_UNIT_TEST_BATCH_SIZE:-1}"' \
    'BATCH_TIMEOUT_SECONDS="${CMUX_UNIT_TEST_BATCH_TIMEOUT_SECONDS:-900}"' \
    'Timed out after ${BATCH_TIMEOUT_SECONDS}s running $label; terminating xcodebuild' \
    'FAIL $label timed out after ${BATCH_TIMEOUT_SECONDS}s' \
    'Restarting after unexpected exit, crash, or test timeout' \
    'fix the underlying app-host crash instead of retrying it' \
    'tail -n 1200 "$BATCH_LOG"' \
    'exit 124' \
    "All \${#SELECTED_TEST_IDENTIFIERS[@]} selected cmuxTests XCTestCase classes and Swift Testing suites passed in \$SHARD_LABEL batches"
  do
    if ! grep -Fq -- "$pattern" "$CMUX_UNIT_ISOLATED_RUNNER"; then
      echo "FAIL: run-cmux-unit-tests-isolated.sh missing required isolation pattern: $pattern"
      exit 1
    fi
  done

  if grep -Fq -- "-skip-testing" "$CMUX_UNIT_ISOLATED_RUNNER"; then
    echo "FAIL: run-cmux-unit-tests-isolated.sh must not skip cmuxTests classes"
    exit 1
  fi

  for forbidden_pattern in \
    "crash-retry" \
    "after crash-reported XCTest method retries" \
    "method selector reported zero tests; retrying containing suite"
  do
    if grep -Fq "$forbidden_pattern" "$CMUX_UNIT_ISOLATED_RUNNER"; then
      echo "FAIL: run-cmux-unit-tests-isolated.sh must fail closed on XCTest host crashes, not retry them: $forbidden_pattern"
      exit 1
    fi
  done

  echo "PASS: type-sharded cmux unit-test runner builds once and runs selected XCTestCase classes and Swift Testing suites under an isolated app-host home"
}

check_xcodebuild_unit_step_rejects_expected_failures() {
  local file="$1" step="$2"
  if ! awk -v step="$step" '
    index($0, "- name: " step) { in_step=1; saw_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /if \[ "\$EXIT_CODE" -ne 0 \]; then/ { saw_nonzero_branch=1 }
    in_step && /echo "Unit tests failed"/ { saw_failure_message=1 }
    in_step && /exit "\$EXIT_CODE"/ { saw_exit=1 }
    in_step && /All failures are expected, treating as pass|\(0 unexpected\)/ { saw_mask=1 }
    END { exit(saw_step && saw_nonzero_branch && saw_failure_message && saw_exit && !saw_mask ? 0 : 1) }
  ' "$file"; then
    echo "FAIL: $step in $(basename "$file") must reject broad XCTest expected-failure pass-throughs"
    exit 1
  fi

  echo "PASS: $step in $(basename "$file") rejects broad XCTest expected-failure pass-throughs"
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

check_ios_simulator_tests_require_nonzero_execution() {
  if ! awk '
    /^[[:space:]]*- name: Run iOS simulator tests$/ { in_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /require_executed_tests\(\)/ { saw_function=1 }
    in_step && /Executed \[1-9\]\[0-9\]\* test,\|Executed \[1-9\]\[0-9\]\* tests\|Test run with \[1-9\]\[0-9\]\* tests/ { saw_nonzero_guard=1 }
    in_step && /iOS simulator test workflow completed without executing any tests/ { saw_message=1 }
    in_step && /require_executed_tests "\$LOG_PATH"/ { saw_call=1 }
    END { exit(saw_function && saw_nonzero_guard && saw_message && saw_call ? 0 : 1) }
  ' "$TEST_IOS_FILE"; then
    echo "FAIL: test-ios.yml must reject successful xcodebuild output that executed zero iOS tests"
    exit 1
  fi

  echo "PASS: test-ios.yml rejects zero-test simulator runs"
}

check_ios_simulator_tests_fail_closed_after_xcodebuild_status() {
  if ! awk '
    /^[[:space:]]*- name: Run iOS simulator tests$/ { in_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /selected_tests_passed_despite_xcodebuild_status\(\)/ { saw_mask_function=1 }
    in_step && /treating this as a runner cleanup failure/ { saw_mask_message=1 }
    in_step && /xctest_started\(\)/ { saw_xctest_started_function=1 }
    in_step && /Test Suite .* started|Testing started|Executed \[1-9\]\[0-9\]\* test,\|Executed \[1-9\]\[0-9\]\* tests\|Test run with \[1-9\]\[0-9\]\* tests/ { saw_xctest_started_patterns=1 }
    in_step && /status="\$\{PIPESTATUS\[0\]\}"/ { saw_status=1 }
    in_step && /\[ "\$attempt" -lt 2 \]/ && /! xctest_started "\$LOG_PATH"/ && /grep -Eq/ && /Timed out while launching application via Xcode/ && /Failed to send signal 19/ && /DTXMessage/ { saw_retry_gated_before_xctest=1 }
    in_step && /Detected Xcode simulator launch failure, retrying on a clean simulator/ { saw_prelaunch_retry=1 }
    in_step && /iOS simulator xcodebuild failed; failing instead of treating post-XCTest cleanup as success/ { saw_fail_closed_message=1 }
    in_step && /exit "\$status"/ { saw_exit=1 }
    END { exit(!saw_mask_function && !saw_mask_message && saw_xctest_started_function && saw_xctest_started_patterns && saw_status && saw_retry_gated_before_xctest && saw_prelaunch_retry && saw_fail_closed_message && saw_exit ? 0 : 1) }
  ' "$TEST_IOS_FILE"; then
    echo "FAIL: test-ios.yml must fail closed on nonzero xcodebuild after XCTest starts and only allow clean-simulator retry before XCTest begins"
    exit 1
  fi

  echo "PASS: test-ios.yml fails closed on nonzero xcodebuild after XCTest starts"
}

check_ios_mobile_package_tests_require_nonzero_execution() {
  if ! awk '
    /^[[:space:]]*- name: Run mobile Swift package tests$/ { in_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /swift test --package-path "Packages\/\$pkg"/ { saw_swift_test=1 }
    in_step && /tee "\$output_file"/ { saw_capture=1 }
    in_step && /Executed \[1-9\]\[0-9\]\* test,\|Executed \[1-9\]\[0-9\]\* tests\|Test run with \[1-9\]\[0-9\]\* tests/ { saw_nonzero_guard=1 }
    in_step && /completed without executing any tests/ { saw_message=1 }
    END { exit(saw_swift_test && saw_capture && saw_nonzero_guard && saw_message ? 0 : 1) }
  ' "$TEST_IOS_FILE"; then
    echo "FAIL: test-ios.yml must reject successful mobile package runs that execute zero tests"
    exit 1
  fi

  local packages=(
    CMUXMobileCore
    CmuxMobileCamera
    CmuxMobileDiagnostics
    CmuxMobilePairedMac
    CmuxMobileRPC
    CmuxMobileShell
    CmuxMobileShellModel
    CmuxMobileSupport
    CmuxMobileTerminalKit
    CmuxMobileTransport
    CmuxMobileWorkspace
  )

  for pkg in "${packages[@]}"; do
    if ! grep -Eq "^[[:space:]]{12}${pkg}$" "$TEST_IOS_FILE"; then
      echo "FAIL: standalone mobile Swift package tests for $pkg must be wired into test-ios.yml"
      exit 1
    fi
  done

  echo "PASS: test-ios.yml rejects zero-test mobile package runs and wires standalone mobile package tests"
}

check_tests_deriveddata_cache() {
  if ! awk '
    /^  tests-core:/ { in_job=1; next }
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
    END { exit(saw_fingerprint_step && saw_fingerprint_mode && saw_cache_path && saw_key && saw_restore && !saw_broad_restore && saw_derived_data_env >= 2 && saw_derived_data >= 1 && saw_cli_path ? 0 : 1) }
  ' "$CI_FILE"; then
    echo "FAIL: tests-core job must cache and reuse a source-fingerprinted explicit DerivedData path for XCTest and CLI steps"
    exit 1
  fi

  if ! awk '
    /^  unit-tests:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && /strategy:/ { saw_strategy=1 }
    in_job && /shard_index: \[0, 1, 2, 3\]/ { saw_shards=1 }
    in_job && /path: \.ci-derived-data\/unit-tests/ { saw_cache_path=1 }
    in_job && /key: deriveddata-unit-tests-\$\{\{ steps\.deriveddata-fingerprint\.outputs\.hash \}\}-\$\{\{ steps\.ghostty-revision\.outputs\.sha \}\}/ { saw_key=1 }
    in_job && /DERIVED_DATA_PATH="\$PWD\/\.ci-derived-data\/unit-tests"/ { saw_derived_data_env=1 }
    in_job && /CMUX_UNIT_TEST_SHARD_INDEX="\$\{\{ matrix\.shard_index \}\}"/ { saw_shard_index=1 }
    in_job && /CMUX_UNIT_TEST_SHARD_COUNT="\$\{\{ matrix\.shard_count \}\}"/ { saw_shard_count=1 }
    in_job && /scripts\/ci\/run-cmux-unit-tests-isolated\.sh/ { saw_unit_runner=1 }
    END { exit(saw_strategy && saw_shards && saw_cache_path && saw_key && saw_derived_data_env && saw_shard_index && saw_shard_count && saw_unit_runner ? 0 : 1) }
  ' "$CI_FILE"; then
    echo "FAIL: unit-tests job must shard class-selected app-host tests across cached DerivedData lanes"
    exit 1
  fi

  echo "PASS: tests-core caches explicit DerivedData and unit-tests shards class-selected app-host runs"
}

check_cached_deriveddata_prunes_module_caches() {
  local script="$ROOT_DIR/scripts/ci/prune-deriveddata-module-cache.sh"
  if [ ! -x "$script" ]; then
    echo "FAIL: prune-deriveddata-module-cache.sh must be executable because workflows invoke it directly"
    exit 1
  fi

  for pattern in \
    'ModuleCache.noindex' \
    'SDKStatCaches.noindex' \
    'SwiftExplicitPrecompiledModules' \
    '*-Bridging-header.pch' \
    'find "$derived_data_path"'
  do
    if ! grep -Fq "$pattern" "$script"; then
      echo "FAIL: prune-deriveddata-module-cache.sh missing required cache-prune pattern: $pattern"
      exit 1
    fi
  done

  for path in \
    .ci-derived-data/unit-tests \
    .ci-derived-data/tests \
    .ci-derived-data/build \
    build-universal \
    .ci-derived-data/ui-regressions
  do
    if ! grep -Fq "scripts/ci/prune-deriveddata-module-cache.sh $path" "$CI_FILE"; then
      echo "FAIL: ci.yml must prune restored Xcode module caches for $path after restoring cached DerivedData"
      exit 1
    fi
  done

  if ! grep -Fq 'prune_stale_bridging_header_pch "$DERIVED_DATA"' "$ROOT_DIR/scripts/reload.sh"; then
    echo "FAIL: reload.sh must prune stale bridging-header PCH files before tagged xcodebuild builds"
    exit 1
  fi

  echo "PASS: cached Xcode DerivedData lanes prune restored module caches and stale bridging-header PCH files before xcodebuild"
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
    in_step && /xcode_status=\$\{PIPESTATUS\[0\]\}/ { after_xcode=1 }
    in_step && after_xcode && /Display resolution UI regression xcodebuild failed; not retrying after XCTest started/ { saw_fail_closed_xcode=1 }
    in_step && after_xcode && /exit "\$xcode_status"/ { saw_xcode_exit=1 }
    in_step && after_xcode && /Attempt \$attempt failed, retrying/ { saw_post_xcode_retry=1 }
    in_step && /^[[:space:]]*sleep 3$/ { saw_fixed_retry_sleep=1 }
    END { exit(saw_wait_pid && saw_stop_pid && saw_wait_cmux && saw_nonzero_guard && saw_no_tests_message && saw_fail_closed_xcode && saw_xcode_exit && !saw_post_xcode_retry && !saw_fixed_retry_sleep ? 0 : 1) }
  ' "$CI_FILE"; then
    echo "FAIL: ui-regressions must wait for app/helper cleanup, reject zero-test display regression runs, and fail closed after XCTest starts"
    exit 1
  fi

  if ! awk '
    /^[[:space:]]*- name: Run browser find focus UI regression$/ { in_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /mktemp \/tmp\/cmux-browser-find-xcodebuild/ { saw_output_file=1 }
    in_step && /tee "\$XCODE_OUTPUT"/ { saw_output_capture=1 }
    in_step && /Executed \[1-9\]\[0-9\]\* test,\|Executed \[1-9\]\[0-9\]\* tests\|Test run with \[1-9\]\[0-9\]\* tests/ { saw_nonzero_guard=1 }
    in_step && /Browser find focus UI regression completed without executing any tests/ { saw_no_tests_message=1 }
    END { exit(saw_output_file && saw_output_capture && saw_nonzero_guard && saw_no_tests_message ? 0 : 1) }
  ' "$CI_FILE"; then
    echo "FAIL: browser find focus UI regression must capture xcodebuild output and reject zero-test runs"
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
check_macos_runner "$CI_FILE" "unit-tests"
check_macos_runner "$CI_FILE" "tests-core"
check_macos_runner "$CI_FILE" "tests-build-and-lag"
check_macos_runner "$CI_FILE" "release-ghostty-cli-helper"
check_macos_runner "$CI_FILE" "release-build"
check_macos_runner "$CI_FILE" "ui-regressions"
check_self_hosted_workspace_prep "$CI_FILE" "unit-tests"
check_self_hosted_workspace_prep "$CI_FILE" "tests-core"
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
check_e2e_ui_tests_skip_zig_helper_build
check_e2e_test_filter_validation
check_e2e_ui_tests_require_nonzero_execution
check_self_hosted_workspace_prep "$E2E_FILE" "e2e"

# test-ios.yml runs app and package tests on macOS 26. Keep it on the paid
# runner variable so PR runs do not sit behind the generic GitHub-hosted queue.
check_ios_change_detection_covers_workflow_trigger
check_ios_simulator_tests_require_nonzero_execution
check_macos_runner "$TEST_IOS_FILE" "mobile-core-package"
check_macos_runner "$TEST_IOS_FILE" "ios-simulator"

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
check_no_debug_xctest_self_skips
check_ui_expected_failures_are_activation_scoped
check_port_scanner_fd_regression_fails_closed_on_ci
check_cmux_config_icon_fixture_fails_closed
check_ssh_fish_shell_regression_fails_closed_on_ci
check_ssh_fish_shell_socket_fixture_fails_closed
check_settings_frame_clamping_fails_closed_on_ci
check_browser_audio_mute_fails_closed_on_ci
check_cli_socket_namespace_fails_closed_on_ci
check_cmux_top_process_fixture_fails_closed_on_ci
check_file_explorer_search_fails_closed_on_ci
check_cli_notify_bundled_cli_fails_closed_on_ci
check_no_swift_test_skip_quarantines
check_vm_socket_tests_do_not_skip_ctrl_interactive
check_vm_socket_tests_do_not_self_skip
check_vm_socket_runners_fail_closed_without_test_retries
check_tmux_corpus_pr_jobs_do_not_report_skipped_terminal_tests
check_activation_artifacts_are_required
check_retryable_submodule_checkout
check_split_theme_regression_timeout
check_command_palette_nucleo_ffi_coverage
check_terminal_corpus_requires_live_ghostty_surface
check_web_db_behavior_test_coverage
check_bundled_ghostty_helper_regression_coverage
check_swift_package_tests_require_nonzero_execution
check_standalone_swift_package_tests_are_wired
check_cmux_unit_isolated_runner
check_xcodebuild_unit_step_requires_nonzero_execution "$CI_FILE" "Run unit tests" "Unit test workflow completed without executing any tests" 1
check_xcodebuild_unit_step_requires_nonzero_execution "$COMPAT_FILE" "Run unit tests" "Compatibility unit tests completed without executing any tests" 1
check_xcodebuild_unit_step_requires_nonzero_execution "$TERMINAL_CORPUS_NIGHTLY_FILE" "Run terminal corpus unit tests" "Terminal corpus unit tests completed without executing any tests"
check_xcodebuild_unit_step_rejects_expected_failures "$CI_FILE" "Run unit tests"
check_xcodebuild_unit_step_rejects_expected_failures "$COMPAT_FILE" "Run unit tests"
check_ios_mobile_package_tests_require_nonzero_execution
check_ios_simulator_tests_fail_closed_after_xcodebuild_status
check_tests_deriveddata_cache
check_cached_deriveddata_prunes_module_caches
check_ui_regression_budget
check_build_and_lag_budget
check_compat_virtual_display_readiness
check_ca_regression_launches_in_gui_bootstrap
check_zig_helper_build_runner "$CI_FILE" "release-ghostty-cli-helper"
check_zig_helper_build_runner "$RELEASE_FILE" "build-ghostty-cli-helper"
