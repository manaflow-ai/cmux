#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/385.
# Ensures paid CI jobs use a paid macOS runner (Blacksmith or WarpBuild, routed
# through the MACOS_RUNNER_15 / MACOS_RUNNER_26 repo variables), never a free
# GitHub-hosted runner. Flip Blacksmith<->Warp by editing those repo variables;
# see docs/ci-runners.md. The one sanctioned free lane is MACOS_RUNNER_BACKGROUND,
# whose fallback is GitHub-hosted macos-15 and whose members must stay off the
# pull request and merge path (check_background_macos_lane).
# Fork execution has a separate portability rule: the normal CI graph routes
# every non-manaflow-ai repository owner to GitHub-hosted runners, because a
# Blacksmith label in a personal fork queues forever. The upstream branch of
# each expression retains the repository-variable routing checked below.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CI_FILE="$ROOT_DIR/.github/workflows/ci.yml"
CI_MACOS_FILE="$ROOT_DIR/.github/workflows/ci-macos.yml"
CI_WEB_FILE="$ROOT_DIR/.github/workflows/ci-web.yml"
GHOSTTYKIT_FILE="$ROOT_DIR/.github/workflows/build-ghosttykit.yml"
COMPAT_FILE="$ROOT_DIR/.github/workflows/ci-macos-compat.yml"
E2E_FILE="$ROOT_DIR/.github/workflows/test-e2e.yml"
TMUX_CORPUS_FILE="$ROOT_DIR/.github/workflows/tmux-corpus.yml"
IOS_FILE="$ROOT_DIR/.github/workflows/test-ios.yml"
CLA_GUARD_FILE="$ROOT_DIR/.github/workflows/cla-policy-guard.yml"

check_cla_guard_runner() {
  if ! grep -Fqx '    runs-on: ubuntu-24.04' "$CLA_GUARD_FILE"; then
    echo "FAIL: cla-policy-guard.yml must use the fixed GitHub-hosted ubuntu-24.04 runner"
    exit 1
  fi

  if grep -Eq '^    runs-on:.*(vars\.LINUX_RUNNER|blacksmith-|self-hosted)' "$CLA_GUARD_FILE"; then
    echo "FAIL: cla-policy-guard.yml must not allow a variable or self-hosted runner override"
    exit 1
  fi

  echo "PASS: CLA policy guard uses the fixed GitHub-hosted runner"
}

check_macos_runner() {
  local file="$1" job="$2"
  if ! awk -v job="$job" '
    $0 ~ "^  "job":" { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && /runs-on:.*(vars\.MACOS_RUNNER|blacksmith-[0-9]+vcpu-macos-|warp-macos-[0-9]+-arm64|depot-macos-)/ { saw=1 }
    # A product consumer inherits the compile admission pool, which this
    # check covers on its own, or on a re-run the Blacksmith pool the pull
    # request picker named for a run on an owned pool (pr_retry_runner).
    in_job && /runs-on:[[:space:]]*\$\{\{ (github\.run_attempt > 1 && inputs\.pr_retry_runner \|\| )?needs\.macos-compile-admission\.outputs\.runner \}\}/ { saw=1 }
    in_job && /os:.*(vars\.MACOS_RUNNER|blacksmith-[0-9]+vcpu-macos-|warp-macos-[0-9]+-arm64|depot-macos-)/ { saw=1 }
    END { exit !(saw) }
  ' "$file"; then
    echo "FAIL: $job in $(basename "$file") must run on a paid macOS runner (vars.MACOS_RUNNER_* or a Blacksmith/Warp/Depot label), not a GitHub-hosted runner"
    exit 1
  fi
  echo "PASS: $job in $(basename "$file") uses a paid macOS runner"
}

check_display_runner_identity_guard() {
  local file="$1" job="$2"
  if ! awk -v job="$job" '
    $0 ~ "^  "job":" { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && /REQUESTED_RUNNER:.*vars\.MACOS_RUNNER_DISPLAY/ { saw_requested=1 }
    in_job && /RUNNER_CONTEXT_NAME:[[:space:]]*\$\{\{ runner\.name \}\}/ { saw_runner_name=1 }
    in_job && /case "\$REQUESTED_RUNNER" in/ { saw_requested_case=1 }
    in_job && /depot-\*\)/ { saw_depot_case=1 }
    in_job && /Display runner is not Depot; skipping Depot identity guard/ { saw_non_depot_skip=1 }
    in_job && /resolved outside Depot/ { saw_error=1 }
    END { exit !(saw_requested && saw_runner_name && saw_requested_case && saw_depot_case && saw_non_depot_skip && saw_error) }
  ' "$file"; then
    echo "FAIL: $job in $(basename "$file") must validate actual Depot identity when MACOS_RUNNER_DISPLAY resolves to a depot-* runner"
    exit 1
  fi

  echo "PASS: $job in $(basename "$file") validates display runner identity"
}

check_release_build_runner_disk_capacity() {
  # Pin the whole expression, not the variable name and the literal as two
  # independent substring matches. Those two can both be satisfied by a line
  # whose effective fallback is a different machine:
  #
  #   vars.MACOS_RUNNER_26 || 'blacksmith-12vcpu-macos-26' || 'blacksmith-6vcpu-macos-26'
  #
  # still contains the name and still contains blacksmith-6vcpu-macos-26, but
  # resolves to the 12vcpu pool. Matching the whole string also catches a
  # paid-overflow gate appearing here, which does not belong: MACOS_RUNNER_26
  # is the free macOS 26 pool and is read ungated everywhere. See
  # docs/ci-runners.md for why the gate must not grow to cover it.
  if ! awk -v release_runner="runs-on: \${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || (github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-6vcpu-macos-26' || vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26') }}" '
    /^  release-build:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && index($0, release_runner) { saw_release_runner=1 }
    END { exit !saw_release_runner }
  ' "$CI_MACOS_FILE"; then
    echo "FAIL: release-build must run the disk-heavy universal build on the macOS 26 runner variable with the exact blacksmith-6vcpu-macos-26 fallback"
    exit 1
  fi

  echo "PASS: release-build uses the macOS 26 runner variable and its exact Blacksmith fallback"
}

check_build_lag_deriveddata_cache_path() {
  # A fresh checkout resets every file time, so a restored DerivedData never
  # spares a rebuild. The job builds into a stable path and caches none of it.
  if ! awk '
    /^  tests-build-and-lag:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }

    in_job && /- name: Prepare isolated DerivedData/ { in_prepare=1; next }
    in_prepare && /^[[:space:]]*- name:/ { in_prepare=0 }
    in_prepare && /DERIVED_DATA_PATH="\$RUNNER_TEMP\/cmux-deriveddata-tests-build-and-lag"/ { saw_prepare_path=1 }
    in_prepare && /GITHUB_RUN_ID|GITHUB_RUN_ATTEMPT/ { saw_dynamic_prepare_path=1 }

    in_job && /key:[[:space:]]*deriveddata-/ { saw_deriveddata_cache=1 }

    END {
      exit !(saw_prepare_path && !saw_dynamic_prepare_path && !saw_deriveddata_cache)
    }
  ' "$CI_MACOS_FILE"; then
    echo "FAIL: tests-build-and-lag must build into the stable RUNNER_TEMP DerivedData path and must not cache DerivedData"
    exit 1
  fi

  echo "PASS: tests-build-and-lag builds into a stable DerivedData path and caches none of it"
}

check_e2e_runner_fallbacks() {
  if ! awk '
    /^on:$/ { in_on=1; next }
    in_on && /^[^[:space:]]/ { in_on=0 }
    in_on && /^  workflow_dispatch:$/ { saw_dispatch=1; next }
    in_on && /^  [A-Za-z0-9_-]+:/ { saw_other_trigger=1 }
    END { exit !(saw_dispatch && !saw_other_trigger) }
  ' "$E2E_FILE"; then
    echo "FAIL: test-e2e.yml must remain workflow_dispatch-only before it may expose the self-hosted Tart canary"
    exit 1
  fi

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

  if ! awk '
    /^      runner:$/ { in_runner=1; next }
    in_runner && /^      [A-Za-z0-9_-]+:/ { in_runner=0; in_options=0 }
    in_runner && /^        options:$/ { in_options=1; next }
    in_options && /^        [A-Za-z0-9_-]+:/ { in_options=0 }
    in_options && /^          - tart-canary$/ { canary_options++ }
    in_options && /^          - tart-dual$/ { dual_options++ }
    in_options && /^          - tart-small$/ { small_options++ }
    END { exit !(canary_options == 1 && dual_options == 1 && small_options == 1) }
  ' "$E2E_FILE"; then
    echo "FAIL: test-e2e.yml must expose tart-canary, tart-dual, and tart-small exactly once under workflow_dispatch.inputs.runner.options"
    exit 1
  fi

  if ! awk '
    /^[[:space:]]*- name: Validate Tart canary identity$/ { in_tart_step=1; next }
    in_tart_step && /^      - / { in_tart_step=0; in_runner_reject=0; in_marker_reject=0 }
    in_tart_step && /startsWith\(needs\.runner\.outputs\.label, '\''tart-'\''\)/ { saw_effective_runner=1 }
    in_tart_step && /REQUESTED_RUNNER: \$\{\{ needs\.runner\.outputs\.label \}\}/ { saw_requested_runner=1 }
    in_tart_step && /RUNNER_CONTEXT_NAME: \$\{\{ runner\.name \}\}/ { saw_runner_context=1 }
    in_tart_step && /tart-cmux-\*/ { saw_runner_pattern=1 }
    in_tart_step && /^[[:space:]]*\*\)$/ { in_runner_reject=1 }
    in_runner_reject && /::error::\$REQUESTED_RUNNER resolved to unexpected runner/ { saw_runner_reject=1 }
    in_runner_reject && /^[[:space:]]*exit 1$/ { saw_runner_exit=1 }
    in_runner_reject && /^[[:space:]]*;;$/ { in_runner_reject=0 }
    in_tart_step && /test -f \/etc\/cmux-tart-ci \|\| \{/ { saw_vm_marker=1; in_marker_reject=1 }
    in_marker_reject && /::error::\$REQUESTED_RUNNER runner is missing the immutable VM identity marker/ { saw_marker_reject=1 }
    in_marker_reject && /^[[:space:]]*exit 1$/ { saw_marker_exit=1 }
    in_marker_reject && /^[[:space:]]*}$/ { in_marker_reject=0 }
    END { exit !(saw_effective_runner && saw_requested_runner && saw_runner_context && saw_runner_pattern && saw_runner_reject && saw_runner_exit && saw_vm_marker && saw_marker_reject && saw_marker_exit) }
  ' "$E2E_FILE"; then
    echo "FAIL: test-e2e.yml must validate the effective Tart runner name and immutable VM marker, failing closed for either mismatch"
    exit 1
  fi

  # Compilation caching is an optional optimization. Its failure must not
  # suppress setup/test failures or make successful tests depend on the cache
  # service. Keep the exception confined to these cache operations.
  python3 - "$E2E_FILE" <<'PYTHON'
import sys
import yaml

document = yaml.safe_load(open(sys.argv[1]))
# Compilation caching, adopted DerivedData and the fast artifact transport are optimizations with
# canonical fallbacks. Everything else must fail the job it runs in.
allowed = {
    ("build", "compilation-cache-restore", "Restore E2E compilation cache", "actions/cache/restore"),
    ("build", None, "Save E2E compilation cache", "actions/cache/save"),
    ("build", "compilation-cache-bound", "Bound E2E compilation cache", ""),
    ("build", "revision-on-main", "Check the selected revision against main", ""),
    ("build", "reuse", "Reuse a compiled product instead of building one", ""),
    ("build", None, "Start the DerivedData seed download", ""),
    ("build", "seed", "Adopt the DerivedData seed", ""),
    ("build", None, "Forget the adopted-build inode override", ""),
    ("test", "parallel-product", "Read the compiled test product over parallel range requests", ""),
}
for job_id, job in document["jobs"].items():
    if "continue-on-error" in job:
        raise SystemExit(f"FAIL: {job_id} must not mask E2E job failures")
    for step in job.get("steps", []):
        if "continue-on-error" not in step:
            continue
        identity = (job_id, step.get("id"), step.get("name"), step.get("uses", "").split("@", 1)[0])
        if identity not in allowed or step["continue-on-error"] is not True:
            raise SystemExit(f"FAIL: {step.get('name')} must not mask E2E setup or test failures")
PYTHON

  # The Tart identity gate, the run name and the SwiftPM cache key all decide
  # things about "the runner this job uses". If any of them reads a different
  # repository variable than runs-on, the gate can be skipped on a Tart VM, or
  # demanded on a runner that is not one.
  runner_vars="$(grep -oE "vars\.MACOS_RUNNER_[A-Z0-9_]+" "$E2E_FILE" | sort -u)"
  if [ "$(printf '%s\n' "$runner_vars" | grep -c .)" -ne 1 ]; then
    echo "FAIL: test-e2e.yml must select its runner from one variable, found:"
    printf '  %s\n' $runner_vars
    exit 1
  fi

  echo "PASS: test-e2e.yml exposes supported Tart runner choices and duplicate-queue cancellation"
}

check_ios_tart_canary() {
  if ! grep -Eq '^[[:space:]]+- tart-ios$' "$IOS_FILE"; then
    echo "FAIL: test-ios.yml must expose the Tart iOS canary runner"
    exit 1
  fi
  if [[ "$(grep -c 'tart-ios resolved to unexpected runner' "$IOS_FILE")" -ne 3 ]] ||
     [[ "$(grep -c 'tart-ios runner is missing the immutable VM identity marker' "$IOS_FILE")" -ne 3 ]]; then
    echo "FAIL: all macOS iOS test jobs must fail closed on Tart identity mismatch"
    exit 1
  fi
  if [[ "$(grep -Fc "runs-on: \${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || ((!inputs.runner || inputs.runner == 'auto') && (vars.MACOS_RUNNER_TESTS || vars.MACOS_RUNNER_IOS || 'blacksmith-6vcpu-macos-26') || inputs.runner) }}" "$IOS_FILE")" -ne 3 ]]; then
    echo "FAIL: all macOS iOS test jobs must honor the dispatch runner override"
    exit 1
  fi
  if [[ "$(grep -Fc "startsWith(github.repository_owner != 'manaflow-ai' && 'macos-26' || ((!inputs.runner || inputs.runner == 'auto') && (vars.MACOS_RUNNER_TESTS || vars.MACOS_RUNNER_IOS || 'blacksmith-6vcpu-macos-26') || inputs.runner), 'tart-')" "$IOS_FILE")" -ne 3 ]]; then
    echo "FAIL: all macOS iOS test jobs must validate Tart identity for explicit and repo-variable routing"
    exit 1
  fi
  echo "PASS: test-ios.yml exposes the guarded Tart iOS canary"
}

check_xcode_selection() {
  if grep -R -n "ls -d /Applications/Xcode" "$ROOT_DIR/.github/workflows"; then
    echo "FAIL: workflow Xcode selection must use find/sort/tail fallback, not ls/glob ordering"
    exit 1
  fi

  echo "PASS: workflow Xcode selection avoids ls/glob ordering"
}

check_release_build_signal() {
  if ! grep -Fq './scripts/ci/verify-binary-archs.sh "$RELEASE_ARCHS" "$APP_BINARY" "$CLI_BINARY" "$CMUX_CUA_BINARY"' "$CI_MACOS_FILE"; then
    echo "FAIL: release-build must verify the Release app, CLI, and cmux-cua contain exactly the resolved architectures"
    exit 1
  fi

  if ! grep -Fq './scripts/ci/verify-binary-archs.sh "$RELEASE_ARCHS" "$APP_BINARY" "$CLI_BINARY" "$CMUX_CUA_BINARY" "$HELPER_BINARY" "$TUI_CLIENT"' "$CI_MACOS_FILE"; then
    echo "FAIL: release-build must verify both bundled helpers contain exactly the producer-selected architectures"
    exit 1
  fi

  echo "PASS: release-build verifies exact artifact architectures"
}

check_release_build_disk_cleanup() {
  if ! awk '
    /^  release-build:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }

    in_job && /- name: Reclaim release runner disk/ { in_step=1; saw_step=1; next }
    in_step && /^[[:space:]]*- name:/ { in_step=0 }
    in_step && /df -h \// { saw_df=1 }
    in_step && /rm -rf build-universal \.spm-cache/ { saw_workspace=1 }
    in_step && /Library\/Developer\/Xcode\/DerivedData/ { saw_direct_derived_data=1 }
    in_step && /cleanup-dev-builds\.sh/ { saw_tag_cleanup=1 }

    END { exit !(saw_step && saw_df && saw_workspace && !saw_direct_derived_data && !saw_tag_cleanup) }
  ' "$CI_MACOS_FILE"; then
    echo "FAIL: release-build cleanup must stay limited to job-owned workspace paths"
    exit 1
  fi

  echo "PASS: release-build reclaims runner disk before large cache restores"
}

check_release_helper_artifact_from_package_lane() {
  if ! awk -v dual_runner="runs-on: \${{ github.repository_owner != 'manaflow-ai' && 'macos-15' || (github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-6vcpu-macos-15' || vars.CI_PAID_MACOS_OVERFLOW == '1' && vars.MACOS_RUNNER_DUAL_XCODE || 'blacksmith-6vcpu-macos-15') }}" '
    /^  swift-package-tests:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }

    in_job && index($0, dual_runner) { saw_dual_runner=1 }
    in_job && /vars\.MACOS_RUNNER_PR/ { saw_pr_lane=1 }
    in_job && /timeout-minutes:[[:space:]]*40/ { saw_timeout=1 }
    in_job && /CMUX_CI_HELPER_XCODE_APP:/ { saw_helper_xcode_env=1 }
    in_job && /- name: Select helper Xcode/ { saw_helper_select=1; next }
    in_job && /CMUX_CI_REQUIRED_MACOS_SDK_MAJOR=15/ { saw_helper_sdk_pin=1 }
    in_job && /- name: Select Xcode/ { saw_select=1; after_select=1; next }
    in_job && /- name: Build Release Ghostty CLI helper/ {
      saw_build_step=1
      if (after_select) {
        saw_build_after_select=1
      }
      next
    }
    in_job && index($0, "./scripts/build-ghostty-cli-helper.sh \"$@\" --output ghostty-cli-helper/ghostty") { saw_build=1 }
    in_job && /\.\/scripts\/ci\/verify-binary-archs\.sh "\$RELEASE_ARCHS" ghostty-cli-helper\/ghostty/ { saw_arch_validation=1 }
    in_job && /- name: Upload Release Ghostty CLI helper/ {
      saw_upload_step=1
      if (after_select) {
        saw_upload_after_select=1
      }
      next
    }
    in_job && /uses: actions\/upload-artifact@/ { saw_upload=1 }
    in_job && /name:[[:space:]]*cmux-ghostty-cli-helper/ { saw_artifact_name=1 }
    in_job && /\[\[ "\$HELPER_SDK_VERSION" == 15\.\* \]\]/ { saw_helper_sdk_validation=1 }

    END {
      exit !(saw_dual_runner && !saw_pr_lane && saw_timeout && saw_helper_xcode_env && saw_helper_select && saw_helper_sdk_pin && saw_build_step && saw_build && saw_arch_validation && saw_helper_sdk_validation && saw_upload_step && saw_upload && saw_artifact_name && saw_select && !saw_build_after_select && !saw_upload_after_select)
    }
  ' "$CI_MACOS_FILE"; then
    echo "FAIL: swift-package-tests must use the dual-Xcode runner on every event, then pin and validate the macOS 15 Ghostty helper before selecting Xcode 26"
    echo "      It builds the Release Ghostty CLI helper against an SDK 15 Xcode, which only the"
    echo "      macos-15 image carries, so it must not resolve through MACOS_RUNNER_PR."
    exit 1
  fi

  if ! awk '
    /^  release-build:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }

    in_job && /- swift-package-tests/ { saw_need=1 }
    in_job && /- name: Download Release Ghostty CLI helper/ { saw_download_step=1; next }
    in_job && /uses: actions\/download-artifact@/ { saw_download=1 }
    in_job && /name:[[:space:]]*cmux-ghostty-cli-helper/ { saw_artifact_name=1 }
    in_job && /- name: Install Release helpers/ { saw_install_step=1; next }
    in_job && /\.\/scripts\/install-prebuilt-ghostty-cli-helper\.sh/ { saw_install=1 }

    END {
      exit !(saw_need && saw_download_step && saw_download && saw_artifact_name && saw_install_step && saw_install)
    }
  ' "$CI_MACOS_FILE"; then
    echo "FAIL: release-build must depend on swift-package-tests, download the helper artifact, and install it into the app"
    exit 1
  fi

  if grep -Fq "release-ghostty-cli-helper:" "$CI_MACOS_FILE"; then
    echo "FAIL: CI must not queue a separate release-ghostty-cli-helper job"
    exit 1
  fi

  echo "PASS: release-build consumes the Ghostty helper artifact built by swift-package-tests"
}

check_runtime_regressions_collapsed() {
  if grep -Fq "ui-regressions:" "$CI_MACOS_FILE"; then
    echo "FAIL: CI must not queue a separate ui-regressions job"
    exit 1
  fi

  if ! awk '
    /^  tests-build-and-lag:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }

    in_job && /restore-app-host-test-product.sh/ { saw_shared_product=1 }
    in_job && /scripts\/ci\/run-display-ui-regressions\.sh/ { saw_ui_script=1 }
    in_job && /kill -9 "\$VDISPLAY_PID"/ { saw_force_kill=1 }
    in_job && /scripts\/ci\/virtual-display-lock\.sh reap-strays/ { saw_reap_strays=1 }
    in_job && /timeout-minutes:[[:space:]]*75/ { saw_timeout=1 }

    END { exit !(saw_shared_product && saw_ui_script && saw_force_kill && saw_reap_strays && saw_timeout) }
  ' "$CI_MACOS_FILE"; then
    echo "FAIL: tests-build-and-lag must restore the shared product, run display UI regressions from that DerivedData, and clean virtual displays before releasing the lock"
    exit 1
  fi

  if ! awk '
    /^run_browser_find_focus\(\) \{/ { in_func=1; next }
    in_func && /^}/ { in_func=0 }
    in_func && /persistent_display_id="\$\(tr -d/ { saw_display_id_read=1 }
    in_func && /CMUX_UI_TEST_TARGET_DISPLAY_ID="\$persistent_display_id"/ { saw_display_env=1 }
    END { exit !(saw_display_id_read && saw_display_env) }
  ' "$ROOT_DIR/scripts/ci/run-display-ui-regressions.sh"; then
    echo "FAIL: browser-find UI regression must target the persistent virtual display"
    exit 1
  fi

  echo "PASS: runtime display regressions are collapsed into tests-build-and-lag"
}

check_signing_intermediate_imports() {
  local helper="$ROOT_DIR/scripts/import-apple-developer-id-intermediates.sh"
  if [[ ! -x "$helper" ]]; then
    echo "FAIL: Apple Developer ID intermediate import helper must exist and be executable"
    exit 1
  fi

  for cert in DeveloperIDCA.cer DeveloperIDG2CA.cer; do
    if ! grep -Fq "https://www.apple.com/certificateauthority/$cert" "$helper"; then
      echo "FAIL: signing helper must import Apple's $cert intermediate"
      exit 1
    fi
    # Both intermediates must be vendored in-repo so signing never depends on a
    # live www.apple.com fetch (a flaky request was producing intermittent
    # "unable to build chain to self-signed root" codesign failures).
    if [[ ! -s "$ROOT_DIR/scripts/apple-developer-id-certs/$cert" ]]; then
      echo "FAIL: signing helper must vendor scripts/apple-developer-id-certs/$cert"
      exit 1
    fi
  done

  if ! grep -Fq 'apple-developer-id-certs' "$helper"; then
    echo "FAIL: signing helper must prefer the vendored apple-developer-id-certs copies before downloading"
    exit 1
  fi

  for curl_flag in "--connect-timeout 20" "--max-time 120"; do
    if ! grep -Fq -- "$curl_flag" "$helper"; then
      echo "FAIL: signing helper must pass curl $curl_flag to avoid hanging signing runners"
      exit 1
    fi
  done

  if ! grep -Fq 'IMPORTED_COUNT="$(' "$helper" || ! grep -Fq 'if [[ "$IMPORTED_COUNT" -lt 2 ]]; then' "$helper"; then
    echo "FAIL: signing helper must verify both Developer ID intermediates were imported"
    exit 1
  fi

  for file in "$ROOT_DIR/.github/workflows/nightly.yml" "$ROOT_DIR/.github/workflows/release.yml"; do
    if ! awk '
      /- name: Import signing cert/ { in_step=1; next }
      in_step && /^[[:space:]]*- name:/ { in_step=0 }
      in_step && /security import \/tmp\/cert\.p12/ { saw_cert_import=1 }
      in_step && /\.\/scripts\/import-apple-developer-id-intermediates\.sh build\.keychain/ { saw_intermediates=1 }
      END { exit !(saw_cert_import && saw_intermediates) }
    ' "$file"; then
      echo "FAIL: $(basename "$file") must import Apple Developer ID intermediates into build.keychain after the signing certificate"
      exit 1
    fi
  done

  echo "PASS: nightly and release signing import Apple Developer ID intermediates"
}

check_signing_intermediate_helper_behavior() {
  local helper="$ROOT_DIR/scripts/import-apple-developer-id-intermediates.sh"
  local tmp_dir bin_dir curl_log security_log keychain
  tmp_dir="$(mktemp -d)"
  bin_dir="$tmp_dir/bin"
  curl_log="$tmp_dir/curl.log"
  security_log="$tmp_dir/security.log"
  keychain="$tmp_dir/build.keychain"
  mkdir -p "$bin_dir"
  touch "$keychain" "$curl_log" "$security_log"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
for ((i = 1; i <= $#; i++)); do
  arg="${!i}"
  if [[ "$arg" == "--output" ]]; then
    next=$((i + 1))
    output="${!next}"
  fi
done
if [[ -z "$output" ]]; then
  echo "curl stub missing --output" >&2
  exit 1
fi
printf '%s\n' "$*" >> "$CMUX_STUB_CURL_LOG"
printf 'fake certificate\n' > "$output"
EOF
  chmod +x "$bin_dir/curl"

  cat > "$bin_dir/security" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  add-certificates)
    printf '%s\n' "$*" >> "$CMUX_STUB_SECURITY_LOG"
    ;;
  find-certificate)
    added_count="$(grep -c '^add-certificates ' "$CMUX_STUB_SECURITY_LOG" 2>/dev/null || true)"
    if [[ "${CMUX_STUB_CERT_COUNT_OVERRIDE:-}" != "" ]]; then
      added_count="$CMUX_STUB_CERT_COUNT_OVERRIDE"
    fi
    for ((i = 0; i < added_count; i++)); do
      printf '%s\n' '-----END CERTIFICATE-----'
    done
    ;;
  *)
    echo "unexpected security command: $*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/security"

  # --- Vendored path (default): the real helper has the certs committed beside
  # it, so it must import both WITHOUT touching the network. ---
  if ! PATH="$bin_dir:/usr/bin:/bin" CMUX_STUB_CURL_LOG="$curl_log" CMUX_STUB_SECURITY_LOG="$security_log" "$helper" "$keychain" >"$tmp_dir/success.out" 2>"$tmp_dir/success.err"; then
    echo "FAIL: signing helper behavior test should import both intermediates from vendored copies"
    cat "$tmp_dir/success.err" >&2 || true
    exit 1
  fi

  if [[ -s "$curl_log" ]]; then
    echo "FAIL: signing helper must not hit the network when vendored intermediates are present"
    cat "$curl_log" >&2 || true
    exit 1
  fi

  if [[ "$(grep -c -- '-k '"$keychain" "$security_log")" -ne 2 ]]; then
    echo "FAIL: signing helper behavior test did not add both vendored certificates to the requested keychain"
    exit 1
  fi

  # --- Fallback path: run a copy of the helper with no vendored certs beside it
  # (VENDOR_DIR resolves next to the script). It must download both intermediates. ---
  local fb_dir fb_helper fb_curl_log fb_security_log fb_keychain
  fb_dir="$tmp_dir/fallback"
  mkdir -p "$fb_dir"
  fb_helper="$fb_dir/import-apple-developer-id-intermediates.sh"
  cp "$helper" "$fb_helper"
  chmod +x "$fb_helper"
  fb_curl_log="$tmp_dir/fb_curl.log"
  fb_security_log="$tmp_dir/fb_security.log"
  fb_keychain="$tmp_dir/fb_build.keychain"
  touch "$fb_curl_log" "$fb_security_log" "$fb_keychain"

  if ! PATH="$bin_dir:/usr/bin:/bin" CMUX_STUB_CURL_LOG="$fb_curl_log" CMUX_STUB_SECURITY_LOG="$fb_security_log" "$fb_helper" "$fb_keychain" >"$tmp_dir/fb.out" 2>"$tmp_dir/fb.err"; then
    echo "FAIL: signing helper fallback should download and import both intermediates"
    cat "$tmp_dir/fb.err" >&2 || true
    exit 1
  fi

  for cert in DeveloperIDCA.cer DeveloperIDG2CA.cer; do
    if ! grep -Fq "https://www.apple.com/certificateauthority/$cert" "$fb_curl_log"; then
      echo "FAIL: signing helper fallback did not download $cert when no vendored copy was present"
      exit 1
    fi
  done

  if [[ "$(grep -c -- '-k '"$fb_keychain" "$fb_security_log")" -ne 2 ]]; then
    echo "FAIL: signing helper fallback did not add both downloaded certificates to the requested keychain"
    exit 1
  fi

  # --- Count guard: helper must fail when fewer than two intermediates land. ---
  if PATH="$bin_dir:/usr/bin:/bin" CMUX_STUB_CURL_LOG="$curl_log" CMUX_STUB_SECURITY_LOG="$security_log" CMUX_STUB_CERT_COUNT_OVERRIDE=1 "$helper" "$keychain" >"$tmp_dir/fail.out" 2>"$tmp_dir/fail.err"; then
    echo "FAIL: signing helper behavior test should fail when fewer than two intermediates are visible"
    exit 1
  fi

  if ! grep -Fq "Expected both Developer ID intermediate certificates" "$tmp_dir/fail.err"; then
    echo "FAIL: signing helper behavior test missing count failure diagnostic"
    exit 1
  fi

  rm -rf "$tmp_dir"
  echo "PASS: signing helper imports vendored intermediates offline, downloads as fallback, and verifies the count"
}

check_sentry_cli_install_portability() {
  local helper="$ROOT_DIR/scripts/ensure-sentry-cli.sh"
  if [[ ! -x "$helper" ]]; then
    echo "FAIL: sentry-cli helper must exist and be executable"
    exit 1
  fi

  for needle in \
    'INSTALL_DIR="${RUNNER_TEMP:-/tmp}/sentry-cli-bin"' \
    'SENTRY_CLI_ASSET="sentry-cli-Darwin-universal"' \
    'SENTRY_CLI_SHA256="dcede3b42632886a32753ad9d763f785d46afd5fa4580b5c979aad2d465d1cf5"' \
    'https://github.com/getsentry/sentry-cli/releases/download/${SENTRY_CLI_VERSION}/${SENTRY_CLI_ASSET}' \
    'SENTRY_CLI_VERSION="3.3.0"' \
    '--connect-timeout 20' \
    '--max-time 120' \
    'ACTUAL_SHA256="$(shasum -a 256 "$DOWNLOAD_PATH" | awk' \
    'install -m 0755 "$DOWNLOAD_PATH" "$INSTALL_DIR/sentry-cli"'; do
    if ! grep -Fq -- "$needle" "$helper"; then
      echo "FAIL: sentry-cli helper must contain $needle"
      exit 1
    fi
  done
  if grep -Fq 'command -v sentry-cli' "$helper"; then
    echo "FAIL: sentry-cli helper must not reuse ambient runner PATH state"
    exit 1
  fi

  for file in "$ROOT_DIR/.github/workflows/nightly.yml" "$ROOT_DIR/.github/workflows/release.yml"; do
    if grep -Fq 'brew install getsentry/tools/sentry-cli' "$file"; then
      echo "FAIL: $(basename "$file") must not require Homebrew for sentry-cli on self-hosted signing runners"
      exit 1
    fi

    if ! awk '
      /- name: Upload dSYMs to Sentry/ { in_step=1; next }
      in_step && /^[[:space:]]*- name:/ { in_step=0 }
      in_step && /SENTRY_CLI="\$\(\.\/scripts\/ensure-sentry-cli\.sh\)"/ { saw_helper=1 }
      in_step && /"\$SENTRY_CLI" debug-files upload --include-sources/ { saw_upload=1 }
      END { exit !(saw_helper && saw_upload) }
    ' "$file"; then
      echo "FAIL: $(basename "$file") must install sentry-cli through scripts/ensure-sentry-cli.sh before dSYM upload"
      exit 1
    fi
  done

  echo "PASS: dSYM upload installs sentry-cli without requiring Homebrew"
}

check_sentry_cli_helper_behavior() {
  local helper="$ROOT_DIR/scripts/ensure-sentry-cli.sh"
  local tmp_dir bin_dir stdout stderr expected_path
  tmp_dir="$(mktemp -d)"
  bin_dir="$tmp_dir/bin"
  stdout="$tmp_dir/stdout"
  stderr="$tmp_dir/stderr"
  expected_path="$tmp_dir/runner/sentry-cli-bin/sentry-cli"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/sentry-cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "ambient sentry-cli should not run" >&2
exit 44
EOF
  chmod +x "$bin_dir/sentry-cli"
  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--output)
			output="$2"
			shift 2
			;;
		*)
			shift
			;;
	esac
done
if [[ -z "$output" ]]; then
	echo "missing --output" >&2
	exit 1
fi
cat > "$output" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
echo "sentry-cli 3.3.0"
SCRIPT
EOF
  chmod +x "$bin_dir/curl"
  cat > "$bin_dir/shasum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
last=""
for arg in "$@"; do
	last="$arg"
done
printf 'dcede3b42632886a32753ad9d763f785d46afd5fa4580b5c979aad2d465d1cf5  %s\n' "$last"
EOF
  chmod +x "$bin_dir/shasum"

  if ! RUNNER_TEMP="$tmp_dir/runner" PATH="$bin_dir:/usr/bin:/bin" "$helper" >"$stdout" 2>"$stderr"; then
    echo "FAIL: sentry-cli helper behavior test should install pinned CLI"
    cat "$stderr" >&2 || true
    exit 1
  fi

  if [[ "$(cat "$stdout")" != "$expected_path" ]]; then
    echo "FAIL: sentry-cli helper must print only the executable path on stdout"
    exit 1
  fi

  if ! grep -Fq 'Installing sentry-cli 3.3.0 into' "$stderr"; then
    echo "FAIL: sentry-cli helper should report pinned install on stderr"
    exit 1
  fi
  if grep -Fq 'ambient sentry-cli should not run' "$stderr"; then
    echo "FAIL: sentry-cli helper must ignore ambient sentry-cli on PATH"
    exit 1
  fi

  rm -rf "$tmp_dir"
  echo "PASS: sentry-cli helper installs the pinned binary without ambient PATH state"
}

check_dmg_signing_uses_build_keychain() {
  local nightly_workflow="$ROOT_DIR/.github/workflows/nightly.yml"
  local nightly_helper="$ROOT_DIR/scripts/ci/notarize-nightly-dmg.sh"
  local release_workflow="$ROOT_DIR/.github/workflows/release.yml"

  if ! grep -Fq './scripts/ci/notarize-nightly-dmg.sh \' "$nightly_workflow"; then
    echo "FAIL: nightly workflow must invoke the guarded notarization helper"
    exit 1
  fi
  for needle in \
    'CODESIGN_TOOL="${CMUX_CODESIGN_TOOL:-/usr/bin/codesign}"' \
    '"$CREATE_DMG_TOOL" --no-code-sign "$APP_PATH" "$DMG_TMP_DIR"' \
    '"$CODESIGN_TOOL" --force --timestamp --keychain build.keychain' \
    '--sign "$APPLE_SIGNING_IDENTITY"' \
    '"$CODESIGN_TOOL" --verify --verbose=2 "$DMG_RELEASE"' \
    '"$XCRUN_TOOL" notarytool submit "$DMG_RELEASE"'; do
    if ! grep -Fq -- "$needle" "$nightly_helper"; then
      echo "FAIL: nightly notarization helper must sign the DMG through build.keychain before submission: $needle"
      exit 1
    fi
  done

  if grep -Eq -- '--identity([=[:space:]]|$)' "$release_workflow"; then
    echo "FAIL: release.yml must not let create-dmg codesign outside build.keychain"
    exit 1
  fi
  if ! awk '
    /create-dmg[[:space:]]*\\/ { in_dmg=1; next }
    in_dmg && /--no-code-sign[[:space:]]*\\/ { saw_no_code_sign=1 }
    in_dmg && /\/usr\/bin\/codesign --force --timestamp --keychain build\.keychain/ { saw_keychain=1 }
    in_dmg && /--sign "\$APPLE_SIGNING_IDENTITY"/ { saw_identity=1 }
    in_dmg && /\/usr\/bin\/codesign --verify --verbose=2 "\$(DMG_RELEASE|dmg_release)"/ { saw_verify=1 }
    in_dmg && /xcrun notarytool submit "\$(DMG_RELEASE|dmg_release)"/ { saw_notary=1 }
    END { exit !(saw_no_code_sign && saw_keychain && saw_identity && saw_verify && saw_notary) }
  ' "$release_workflow"; then
    echo "FAIL: release.yml must sign DMGs explicitly with build.keychain before notarization"
    exit 1
  fi

  echo "PASS: DMG signing uses build.keychain explicitly"
}

check_create_dmg_uses_run_local_npm_prefix() {
  for file in "$ROOT_DIR/.github/workflows/nightly.yml" "$ROOT_DIR/.github/workflows/release.yml"; do
    if ! awk '
      /- name: Install build deps/ { in_step=1; next }
      in_step && /^[[:space:]]*- name:/ { in_step=0 }
      in_step && /CMUX_NODE_BIN="\$\(command -v node\)"/ { saw_node=1 }
      in_step && /export npm_config_prefix="\$RUNNER_TEMP\/npm-global"/ { saw_prefix=1 }
      in_step && /mkdir -p "\$npm_config_prefix"/ { saw_mkdir=1 }
      in_step && /npm install --global "create-dmg@\$\{CREATE_DMG_VERSION\}"/ { saw_install=1 }
      in_step && /wrapper_dir="\$RUNNER_TEMP\/create-dmg-wrapper"/ { saw_wrapper=1 }
      in_step && /exec "\$CMUX_NODE_BIN" "\$npm_config_prefix\/lib\/node_modules\/create-dmg\/cli\.js" "\\\$@"/ { saw_exec=1 }
      in_step && /echo "\$wrapper_dir" >> "\$GITHUB_PATH"/ { saw_path=1 }
      END { exit !(saw_node && saw_prefix && saw_mkdir && saw_install && saw_wrapper && saw_exec && saw_path) }
    ' "$file"; then
      echo "FAIL: $(basename "$file") must run create-dmg from a setup-node-bound wrapper in a run-local npm prefix"
      exit 1
    fi
  done

  echo "PASS: create-dmg uses setup-node-bound wrapper from run-local npm prefix"
}

check_gui_smoke_unsupported_launch_handling() {
  local helper="$ROOT_DIR/scripts/smoke-launch-macos-app.sh"
  for needle in \
    'ALLOW_UNSUPPORTED_GUI="${CMUX_SMOKE_ALLOW_UNSUPPORTED_GUI:-0}"' \
    'DIRECT_EXEC="${CMUX_SMOKE_DIRECT_EXEC:-0}"' \
    'CMUX_UI_TEST_MODE="${CMUX_UI_TEST_MODE:-1}"' \
    'open_log_indicates_unsupported_gui()' \
    "grep -Fq 'OSLaunchdErrorDomain Code=125'" \
    "grep -Fq 'Domain does not support specified action'" \
    'GUI launch smoke unsupported on this runner'; do
    if ! grep -Fq -- "$needle" "$helper"; then
      echo "FAIL: smoke-launch helper must explicitly detect unsupported GUI launch: $needle"
      exit 1
    fi
  done

  if ! awk '
    /scripts\/smoke-launch-macos-app\.sh/ && /CMUX_SMOKE_ALLOW_UNSUPPORTED_GUI=1/ { saw_launchservices=1 }
    /scripts\/smoke-launch-macos-app\.sh/ && /CMUX_SMOKE_DIRECT_EXEC=1/ { saw_direct_exec=1 }
    END { exit !(saw_launchservices && saw_direct_exec) }
  ' "$ROOT_DIR/.github/workflows/release.yml"; then
    echo "FAIL: release signing smoke must run LaunchServices smoke before direct exec CI launch mode"
    exit 1
  fi

  local nightly_workflow="$ROOT_DIR/.github/workflows/nightly.yml"
  local nightly_helper="$ROOT_DIR/scripts/ci/notarize-nightly-dmg.sh"
  if ! grep -Fq './scripts/ci/notarize-nightly-dmg.sh \' "$nightly_workflow"; then
    echo "FAIL: nightly workflow must invoke the helper that owns launch smokes"
    exit 1
  fi
  for needle in \
    'SMOKE_TOOL="${CMUX_SMOKE_TOOL:-$ROOT_DIR/scripts/smoke-launch-macos-app.sh}"' \
    'CMUX_SMOKE_ALLOW_UNSUPPORTED_GUI=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL"' \
    'CMUX_SMOKE_DIRECT_EXEC=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL"'; do
    if ! grep -Fq -- "$needle" "$nightly_helper"; then
      echo "FAIL: nightly notarization helper must preserve both launch smokes: $needle"
      exit 1
    fi
  done

  if ! grep -Fq 'scripts/smoke-launch-macos-app.sh' "$ROOT_DIR/.github/workflows/release.yml"; then
    echo "FAIL: release.yml signing workflow must run launch smoke"
    exit 1
  fi

  echo "PASS: signing smoke handles unsupported GUI launch and release direct exec explicitly"
}

check_no_ci_xctest_skips() {
  if grep -nE '(^|[[:space:]])-skip-testing:' "$CI_MACOS_FILE"; then
    echo "FAIL: ci-macos.yml must not exclude individual XCTest methods with -skip-testing; fix or isolate the flaky test instead"
    exit 1
  fi

  echo "PASS: ci-macos.yml does not exclude XCTest methods"
}

check_no_ci_swift_package_skips() {
  if grep -nE '(^|[[:space:]])swift[[:space:]]+test([[:space:]].*)?[[:space:]]--skip([[:space:]]|$)' "$CI_MACOS_FILE"; then
    echo "FAIL: ci-macos.yml must not exclude Swift package tests with swift test --skip; fix or isolate the failing package test instead"
    exit 1
  fi

  echo "PASS: ci-macos.yml does not exclude Swift package tests"
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
  ' "$CI_WEB_FILE"; then
    echo "FAIL: ci-web.yml must run the DB behavior test discovery runner with CMUX_DB_TEST=1"
    exit 1
  fi

  if ! grep -Fq 'grep -q "process\\.env\\.CMUX_DB_TEST"' "$db_runner"; then
    echo "FAIL: DB behavior runner must discover CMUX_DB_TEST-gated files instead of hard-coding a subset"
    exit 1
  fi

  echo "PASS: web DB behavior tests run through the discovery runner"
}

check_web_test_runner_behavior() {
  local fixture_dir fixture_runner args_log expected_args live_mode
  fixture_dir="$(mktemp -d)"
  trap 'rm -rf -- "$fixture_dir"' EXIT
  fixture_runner="$fixture_dir/web/scripts/run-tests.sh"
  args_log="$fixture_dir/bun-args.log"
  mkdir -p \
    "$fixture_dir/web/.hidden" \
    "$fixture_dir/web/node_modules/fixture" \
    "$fixture_dir/web/scripts" \
    "$fixture_dir/web/tests/nested" \
    "$fixture_dir/bin"
  cp "$ROOT_DIR/web/scripts/run-tests.sh" "$fixture_runner"
  touch \
    "$fixture_dir/web/.hidden/ignored.test.ts" \
    "$fixture_dir/web/node_modules/fixture/ignored.test.ts" \
    "$fixture_dir/web/scripts/alpha_spec.mts" \
    "$fixture_dir/web/tests/beta.test.ts" \
    "$fixture_dir/web/tests/nested/gamma_test.tsx" \
    "$fixture_dir/web/tests/nested/omega.spec.mjs"

  cat > "$fixture_dir/bin/bun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' "${CMUX_WEB_TEST_RUNNER_BUN_VERSION:-1.3.14}"
  exit 0
fi
printf '%s\n' "$@" > "$CMUX_WEB_TEST_RUNNER_ARGS_LOG"
EOF
  chmod +x "$fixture_dir/bin/bun"

  if ! PATH="$fixture_dir/bin:/usr/bin:/bin" \
    CMUX_WEB_TEST_RUNNER_ARGS_LOG="$args_log" \
    /bin/bash "$fixture_runner"; then
    rm -rf "$fixture_dir"
    echo "FAIL: shared web test runner default discovery should execute"
    exit 1
  fi

  expected_args=$'test\n--isolate\n./scripts/alpha_spec.mts\n./tests/beta.test.ts\n./tests/nested/gamma_test.tsx\n./tests/nested/omega.spec.mjs'
  if [[ "$(cat "$args_log")" != "$expected_args" ]]; then
    echo "FAIL: shared web test runner must sort recursive Bun test patterns and exclude hidden dependencies"
    cat "$args_log"
    rm -rf "$fixture_dir"
    exit 1
  fi

  if PATH="$fixture_dir/bin:/usr/bin:/bin" \
    CMUX_WEB_TEST_RUNNER_ARGS_LOG="$args_log" \
    CMUX_WEB_TEST_RUNNER_BUN_VERSION="1.2.14" \
    /bin/bash "$fixture_runner" >/dev/null 2>&1; then
    echo "FAIL: shared web test runner must reject Bun versions with process-global mock leakage"
    rm -rf "$fixture_dir"
    exit 1
  fi

  if PATH="$fixture_dir/bin:/usr/bin:/bin" \
    CMUX_WEB_TEST_RUNNER_ARGS_LOG="$args_log" \
    CMUX_WEB_TEST_RUNNER_BUN_VERSION="1.3.13" \
    /bin/bash "$fixture_runner" >/dev/null 2>&1; then
    echo "FAIL: shared web test runner must enforce the patch-level Bun isolation boundary"
    rm -rf "$fixture_dir"
    exit 1
  fi

  if ! PATH="$fixture_dir/bin:/usr/bin:/bin" \
    CMUX_WEB_TEST_RUNNER_ARGS_LOG="$args_log" \
    /bin/bash "$fixture_runner" \
    --coverage -t "fixture runs" --bail=2 --parallel=2; then
    rm -rf "$fixture_dir"
    echo "FAIL: shared web test runner option-only discovery should execute"
    exit 1
  fi
  expected_args+=$'\n--coverage\n-t\nfixture runs\n--bail=2\n--parallel=2'
  if [[ "$(cat "$args_log")" != "$expected_args" ]]; then
    echo "FAIL: option-only runs must retain sorted discovery before forwarding options"
    cat "$args_log"
    rm -rf "$fixture_dir"
    exit 1
  fi

  if ! PATH="$fixture_dir/bin:/usr/bin:/bin" \
    CMUX_WEB_TEST_RUNNER_ARGS_LOG="$args_log" \
    /bin/bash "$fixture_runner" --changed=main; then
    rm -rf "$fixture_dir"
    echo "FAIL: shared web test runner changed-file discovery should execute"
    exit 1
  fi
  expected_args=$'test\n--isolate\n--changed=main'
  if [[ "$(cat "$args_log")" != "$expected_args" ]]; then
    echo "FAIL: changed-file selection must retain Bun-owned discovery"
    cat "$args_log"
    rm -rf "$fixture_dir"
    exit 1
  fi

  if ! PATH="$fixture_dir/bin:/usr/bin:/bin" \
    CMUX_WEB_TEST_RUNNER_ARGS_LOG="$args_log" \
    /bin/bash "$fixture_runner" tests/beta; then
    rm -rf "$fixture_dir"
    echo "FAIL: shared web test runner explicit filter should execute"
    exit 1
  fi
  expected_args=$'test\n--isolate\ntests/beta'
  if [[ "$(cat "$args_log")" != "$expected_args" ]]; then
    echo "FAIL: explicit test filters must remain scoped instead of expanding to every test"
    cat "$args_log"
    rm -rf "$fixture_dir"
    exit 1
  fi

  if ! PATH="$fixture_dir/bin:/usr/bin:/bin" \
    CMUX_WEB_TEST_RUNNER_ARGS_LOG="$args_log" \
    /bin/bash "$fixture_runner" --bail tests/beta; then
    rm -rf "$fixture_dir"
    echo "FAIL: shared web test runner optional flag plus filter should execute"
    exit 1
  fi
  expected_args=$'test\n--isolate\n--bail\ntests/beta'
  if [[ "$(cat "$args_log")" != "$expected_args" ]]; then
    echo "FAIL: optional-valued flags must not consume a following test filter"
    cat "$args_log"
    rm -rf "$fixture_dir"
    exit 1
  fi

  for live_mode in --watch --hot; do
    if ! PATH="$fixture_dir/bin:/usr/bin:/bin" \
      CMUX_WEB_TEST_RUNNER_ARGS_LOG="$args_log" \
      /bin/bash "$fixture_runner" "$live_mode"; then
      rm -rf "$fixture_dir"
      echo "FAIL: shared web test runner $live_mode mode should execute"
      exit 1
    fi
    expected_args=$'test\n--isolate\n'"$live_mode"
    if [[ "$(cat "$args_log")" != "$expected_args" ]]; then
      echo "FAIL: $live_mode mode must delegate live test discovery to Bun"
      cat "$args_log"
      rm -rf "$fixture_dir"
      exit 1
    fi
  done

  cat > "$fixture_dir/web/bunfig.toml" <<'EOF'
[test]
root = "tests"
EOF
  if ! PATH="$fixture_dir/bin:/usr/bin:/bin" \
    CMUX_WEB_TEST_RUNNER_ARGS_LOG="$args_log" \
    /bin/bash "$fixture_runner"; then
    rm -rf "$fixture_dir"
    echo "FAIL: shared web test runner configured-root discovery should execute"
    exit 1
  fi
  expected_args=$'test\n--isolate'
  if [[ "$(cat "$args_log")" != "$expected_args" ]]; then
    echo "FAIL: default root-bearing Bun config must retain Bun-owned discovery"
    cat "$args_log"
    rm -rf "$fixture_dir"
    exit 1
  fi
  rm -f "$fixture_dir/web/bunfig.toml"

  if ! PATH="$fixture_dir/bin:/usr/bin:/bin" \
    CMUX_WEB_TEST_RUNNER_ARGS_LOG="$args_log" \
    /bin/bash "$fixture_runner" --config=ci.bunfig.toml; then
    rm -rf "$fixture_dir"
    echo "FAIL: shared web test runner alternate-config discovery should execute"
    exit 1
  fi
  expected_args=$'test\n--isolate\n--config=ci.bunfig.toml'
  if [[ "$(cat "$args_log")" != "$expected_args" ]]; then
    echo "FAIL: alternate Bun configs must retain Bun-owned discovery"
    cat "$args_log"
    rm -rf "$fixture_dir"
    exit 1
  fi

  cat > "$fixture_dir/bin/find" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "./tests/beta.test.ts"
exit 1
EOF
  chmod +x "$fixture_dir/bin/find"
  rm -f "$args_log"
  if PATH="$fixture_dir/bin:/usr/bin:/bin" \
    CMUX_WEB_TEST_RUNNER_ARGS_LOG="$args_log" \
    /bin/bash "$fixture_runner" \
    >"$fixture_dir/discovery.stdout" 2>"$fixture_dir/discovery.stderr"; then
    echo "FAIL: shared web test runner must reject partial discovery results"
    rm -rf "$fixture_dir"
    exit 1
  fi
  if ! grep -Fq "Web test discovery failed" "$fixture_dir/discovery.stderr"; then
    echo "FAIL: shared web test runner must explain discovery failures"
    cat "$fixture_dir/discovery.stderr"
    rm -rf "$fixture_dir"
    exit 1
  fi
  if [[ -e "$args_log" ]]; then
    echo "FAIL: shared web test runner must not execute Bun after discovery fails"
    cat "$args_log"
    rm -rf "$fixture_dir"
    exit 1
  fi
  rm -f "$fixture_dir/bin/find"

  mkdir -p "$fixture_dir/empty/scripts"
  cp "$ROOT_DIR/web/scripts/run-tests.sh" "$fixture_dir/empty/scripts/run-tests.sh"
  if ! PATH="$fixture_dir/bin:/usr/bin:/bin" \
    CMUX_WEB_TEST_RUNNER_ARGS_LOG="$args_log" \
    /bin/bash "$fixture_dir/empty/scripts/run-tests.sh" \
    --pass-with-no-tests; then
    rm -rf "$fixture_dir"
    echo "FAIL: shared web test runner must honor --pass-with-no-tests"
    exit 1
  fi
  expected_args=$'test\n--isolate\n--pass-with-no-tests'
  if [[ "$(cat "$args_log")" != "$expected_args" ]]; then
    echo "FAIL: --pass-with-no-tests must retain Bun-owned empty discovery"
    cat "$args_log"
    rm -rf "$fixture_dir"
    exit 1
  fi

  if PATH="$fixture_dir/bin:/usr/bin:/bin" \
    CMUX_WEB_TEST_RUNNER_ARGS_LOG="$args_log" \
    /bin/bash "$fixture_dir/empty/scripts/run-tests.sh" \
    >"$fixture_dir/empty.stdout" 2>"$fixture_dir/empty.stderr"; then
    rm -rf "$fixture_dir"
    echo "FAIL: shared web test runner must fail when no tests exist"
    exit 1
  fi
  if ! grep -Fq "No web test files found" "$fixture_dir/empty.stderr"; then
    echo "FAIL: shared web test runner must explain an empty test suite"
    cat "$fixture_dir/empty.stderr"
    rm -rf "$fixture_dir"
    exit 1
  fi

  rm -rf "$fixture_dir"
  trap - EXIT
  echo "PASS: shared web test runner sorts recursive discovery and fails closed when empty"
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

check_no_bare_github_hosted_runners() {
  # Every product CI job must route its runner through a repo variable (LINUX_RUNNER,
  # MACOS_RUNNER_*) so the Blacksmith<->Warp / Blacksmith<->macos-26 overflow
  # switch is a single repo-variable flip with no PR. A bare GitHub-hosted
  # label (ubuntu-*, macos-NN) cannot be redirected, so it is forbidden. A
  # GitHub-hosted macOS label may appear only as the MACOS_RUNNER_BACKGROUND
  # fallback; check_background_macos_lane enforces that.
  # The CLA policy guard is a separate immutable control-plane job and is
  # intentionally exempted below because it must never honor a repository
  # variable or self-hosted runner override.
  # Bare paid-provider labels (blacksmith-*, warp-*, depot-*) stay allowed for
  # deliberate single-runner pins such as the testmanagerd-wedged
  # `app-host-unit-tests` job.
  local hits
  # cla-policy-guard.yml, web-complexity-trusted.yml and
  # merge-group-policy-checks.yml are control-plane workflows. They
  # deliberately run on GitHub-hosted ephemeral runners so untrusted
  # policy/source bytes cannot redirect execution to a persistent or
  # contributor-controlled machine. Exempt those files here instead.
  hits="$(grep -rnE "runs-on:[[:space:]]*(ubuntu-[a-z0-9.]+|macos-[a-z0-9]+)([[:space:]]*$|[[:space:]]+#)" "$ROOT_DIR/.github/workflows" | grep -v "github-hosted-required" | grep -v "/cla-policy-guard.yml:" | grep -v "/web-complexity-trusted.yml:" | grep -v "/merge-group-policy-checks.yml:" || true)"
  if [[ -n "$hits" ]]; then
    echo "FAIL: these jobs use a bare GitHub-hosted runner; route them through vars.LINUX_RUNNER / vars.MACOS_RUNNER_IOS so Blacksmith<->overflow stays a repo-variable flip:"
    echo "$hits"
    exit 1
  fi
  echo "PASS: no workflow pins a bare GitHub-hosted runner; all route through runner repo variables"
}

check_no_self_hosted_fleet_runners() {
  # Required jobs route through repository variables. Forbid hardcoded fleet
  # labels so Tart cutover and paid-provider fallback remain configuration
  # changes and a physical host label cannot bypass the isolated VM pool.
  # Allowed macOS labels (none carried by any fleet runner):
  #   blacksmith-{6,12}vcpu-macos-{15,26,latest}, warp-macos-15-arm64-6x,
  # NOTE: reload-build.yml is the dev-build offload path (workflow_dispatch,
  # not required CI) and intentionally targets the fleet via a free-form input;
  # this guard only inspects runner-selection lines, not its input description.
  # Owned pool labels (glaeda-std-xcode-26.6) are fleet labels too, so no
  # workflow names one and no MACOS_RUNNER_* variable may hold one. They reach
  # a job only as scripts/ci/pr_runner_pool.py's output for a same-repository
  # pull request run, and only once CI_PR_POOL_OWNED is 1; `owned` is that
  # label shape, which runner_label_policy.py accepts in CI_PR_POOL_ORDER.
  # check_owned_pools_route_through_picker holds the other half.
  local owned='glaeda-(xl|std|light)-xcode-[0-9]+([.][0-9]+)*'
  local fleet='glaeda-|macos-26|warp-macos-26-arm64-6x|cmux-aws-macos|cmux-macos|cmux-local-macos|cmux-persistent-compile|cmux-persistent-macos-compile|macfleet|tart-[a-z0-9-]+|(^|[^a-z0-9-])mac4([^a-z0-9]|$)|(^|[^a-z0-9-])mac-mini([^a-z0-9]|$)|slot-[0-9]|xcode-[0-9]+-[0-9]|(^|[^a-z0-9-])cmux([^a-z0-9-]|$)'
  local allowed='blacksmith-(6|12)vcpu-macos-(15|26|latest)|warp-macos-15-arm64-6x'
  # A fork running CI in its own repository has no fleet, so its hosted
  # branch may name GitHub's macos-26 image. Only this exact short-circuit is
  # exempt: it evaluates solely where the repository owner is not manaflow-ai.
  # Workflow text only; a variable holding macos-26 is still refused.
  local fork_branch="github\\.repository_owner != 'manaflow-ai' && 'macos-26'"

  # Bare self-hosted/macOS/ARM64 targeting (inline array or multi-line list).
  # Case-sensitive: GitHub's auto labels are `macOS`/`ARM64`, distinct from the
  # lowercase `macos`/`arm64` inside cloud labels like warp-macos-15-arm64-6x.
  local selfhosted='(^|[^A-Za-z0-9_-])(self-hosted|macOS|ARM64)([^A-Za-z0-9_-]|$)'
  local forbidden="${fleet}|${selfhosted}"

  # Self-test the matcher so a future edit cannot silently narrow it: every
  # known fleet/self-hosted label must be caught, every allowed cloud label
  # must pass. Probes are raw YAML values (no path:lineno: prefix).
  local probe
  for probe in 'runs-on: macfleet' '- tart-canary' '- tart-dual' '- tart-small' '- tart-macos-26' '- tart-ios' '- mac4' '- mac-mini' '- slot-3' '- xcode-26-3' '- cmux' \
               "runs-on: \${{ vars.X || 'macos-26' }}" '- warp-macos-26-arm64-6x' \
               '- cmux-aws-macos-15' '- cmux-macos-26' '- self-hosted' '- macOS' '- ARM64' \
               'runs-on: [self-hosted, macOS, ARM64]' \
               '      labels: [self-hosted, macOS, ARM64, cmux-persistent-macos-compile]' \
               '      group: cmux-persistent-compile' '- cmux-persistent-macos-compile' \
               '- glaeda-std-xcode-26.6' "runs-on: \${{ vars.X || 'glaeda-light-xcode-26.6' }}" 'runs-on: glaeda-xl-xcode-26' \
               '- GLAEDA-std-xcode-26.6' '- Tart-canary'; do
    if ! printf '%s\n' "$probe" | grep -Eiq "($fleet)" && ! printf '%s\n' "$probe" | grep -Eq "($selfhosted)"; then
      echo "FAIL: fleet-runner guard self-test missed a known fleet/self-hosted label: $probe"
      exit 1
    fi
  done
  for probe in glaeda-std-xcode-26.6 glaeda-light-xcode-26.6 glaeda-xl-xcode-26; do
    if ! [[ "$probe" =~ ^($owned)$ ]] || ! printf '%s\n' "$probe" | grep -Eq "($fleet)"; then
      echo "FAIL: owned pool pattern must match, and the fleet pattern refuse, the owned label: $probe"
      exit 1
    fi
  done
  for probe in glaeda-std-xcode glaeda-mini-xcode-26.6 blacksmith-6vcpu-macos-26; do
    if [[ "$probe" =~ ^($owned)$ ]]; then
      echo "FAIL: owned pool pattern matched a label that is not an owned pool: $probe"
      exit 1
    fi
  done
  for probe in "runs-on: \${{ vars.X || 'blacksmith-6vcpu-macos-26' }}" \
               "runs-on: \${{ vars.X || 'blacksmith-12vcpu-macos-26' }}" \
               "runs-on: \${{ vars.MACOS_RUNNER_15 || 'warp-macos-15-arm64-6x' }}" \
               '- warp-macos-15-arm64-6x' '- blacksmith-6vcpu-macos-15' \
               '- blacksmith-4vcpu-ubuntu-2404'; do
    if printf '%s\n' "$probe" | sed -E "s/($allowed)//g" | grep -Eq "($forbidden)"; then
      echo "FAIL: fleet-runner guard self-test false-positived a cloud label: $probe"
      exit 1
    fi
  done

  probe="runs-on: \${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || vars.MACOS_RUNNER_PR || 'blacksmith-6vcpu-macos-26' }}"
  if printf '%s\n' "$probe" | sed -E "s/$fork_branch//g; s/($allowed)//g" | grep -Eq "($forbidden)"; then
    echo "FAIL: fleet-runner guard self-test refused the hosted fork branch: $probe"
    exit 1
  fi
  for probe in "runs-on: \${{ github.repository_owner == 'manaflow-ai' && 'macos-26' }}" \
               "runs-on: \${{ github.repository_owner != 'manaflow-ai' && 'blacksmith-6vcpu-macos-15' || 'macos-26' }}"; do
    if ! printf '%s\n' "$probe" | sed -E "s/$fork_branch//g; s/($allowed)//g" | grep -Eq "($forbidden)"; then
      echo "FAIL: fleet-runner guard self-test let macos-26 through outside the fork branch: $probe"
      exit 1
    fi
  done

  probe="runs-on: \${{ vars.USE_TART == '1' && 'tart-canary' || 'blacksmith-6vcpu-macos-15' }}"
  if ! printf '%s\n' "$probe" | sed -E "s/($allowed)//g" | grep -Eq "($forbidden)"; then
    echo "FAIL: fleet-runner guard self-test let an allowed fallback mask a forbidden label: $probe"
    exit 1
  fi

  local e2e_tart_option_line e2e_tart_dual_option_line e2e_tart_small_option_line e2e_tart_tahoe_option_line ios_tart_option_line
  e2e_tart_option_line="$(awk '
    /^      runner:$/ { in_runner=1; next }
    in_runner && /^      [A-Za-z0-9_-]+:/ { in_runner=0; in_options=0 }
    in_runner && /^        options:$/ { in_options=1; next }
    in_options && /^        [A-Za-z0-9_-]+:/ { in_options=0 }
    in_options && /^          - tart-canary$/ { print FNR }
  ' "$E2E_FILE")"
  e2e_tart_dual_option_line="$(awk '
    /^      runner:$/ { in_runner=1; next }
    in_runner && /^      [A-Za-z0-9_-]+:/ { in_runner=0; in_options=0 }
    in_runner && /^        options:$/ { in_options=1; next }
    in_options && /^        [A-Za-z0-9_-]+:/ { in_options=0 }
    in_options && /^          - tart-dual$/ { print FNR }
  ' "$E2E_FILE")"
  e2e_tart_small_option_line="$(awk '
    /^      runner:$/ { in_runner=1; next }
    in_runner && /^      [A-Za-z0-9_-]+:/ { in_runner=0; in_options=0 }
    in_runner && /^        options:$/ { in_options=1; next }
    in_options && /^        [A-Za-z0-9_-]+:/ { in_options=0 }
    in_options && /^          - tart-small$/ { print FNR }
  ' "$E2E_FILE")"
  ios_tart_option_line="$(awk '
    /^      runner:$/ { in_runner=1; next }
    in_runner && /^      [A-Za-z0-9_-]+:/ { in_runner=0; in_options=0 }
    in_runner && /^        options:$/ { in_options=1; next }
    in_options && /^        [A-Za-z0-9_-]+:/ { in_options=0 }
    in_options && /^          - tart-ios$/ { print FNR }
  ' "$IOS_FILE")"

  local hits="" line content content_without_allowed
  # Inspect runner-selection lines only: runs-on:, matrix `os:`, and scalar list
  # items (`  - <label>`, which covers dispatch runner dropdowns and multi-line
  # `runs-on:` arrays). `- name:` / `- uses:` step entries have a colon and are
  # excluded. grep matches against file CONTENT; strip the `path:lineno:` prefix
  # before matching the value so the checkout path (which contains "cmux") can
  # never match the bare `cmux` label.
  while IFS= read -r line; do
    content="${line#*:*:}"
    content_without_allowed="$(printf '%s\n' "$content" | sed -E "s/$fork_branch//g; s/($allowed)//g")"
    # GitHub matches runner labels without regard to case, so a fleet label
    # is refused in any case; the bare self-hosted labels stay case-sensitive
    # (see selfhosted above).
    { printf '%s\n' "$content_without_allowed" | grep -Eiq "($fleet)" ||
      printf '%s\n' "$content_without_allowed" | grep -Eq "($selfhosted)"; } || continue
    if [[ -n "$e2e_tart_option_line" ]] && [[ "$line" == "$E2E_FILE:$e2e_tart_option_line:"* ]]; then
      continue
    fi
    if [[ -n "$e2e_tart_dual_option_line" ]] && [[ "$line" == "$E2E_FILE:$e2e_tart_dual_option_line:"* ]]; then
      continue
    fi
    if [[ -n "$e2e_tart_small_option_line" ]] && [[ "$line" == "$E2E_FILE:$e2e_tart_small_option_line:"* ]]; then
      continue
    fi
    if [[ -n "$ios_tart_option_line" ]] && [[ "$line" == "$IOS_FILE:$ios_tart_option_line:"* ]]; then
      continue
    fi
    hits+="$line"$'\n'
  done < <(grep -rnE "(runs-on:|^[[:space:]]+(labels|group):|[[:space:]]os:[[:space:]]|^[[:space:]]*-[[:space:]]+[A-Za-z0-9._-]+[[:space:]]*$)" "$ROOT_DIR/.github/workflows")
  if [[ -n "$hits" ]]; then
    echo "FAIL: workflow references a self-hosted mac fleet label or bare self-hosted runner in a runner-selection position."
    echo "      Use a cloud label so required jobs never land on a mini that can't foreground a GUI app:"
    echo "      blacksmith-{6,12}vcpu-macos-{15,26,latest} / warp-macos-15-arm64-6x / depot-macos-{latest,14}."
    echo "$hits"
    exit 1
  fi
  echo "PASS: required jobs stay on cloud runners; no workflow names a mini directly"
}

check_owned_pools_route_through_picker() {
  # An owned pool label never appears in workflow text (the fleet pattern
  # refuses it), so the only way one reaches runs-on is the value
  # pr_runner_pool.py writes for a pull request run: it hands owned labels
  # only to same-repository heads on a first attempt, and only once
  # CI_PR_POOL_OWNED is 1. This check keeps that the only way. The picker's
  # runner output feeds exactly the macos_pr_runner output and the rescue
  # marker; macos_pr_runner reaches a job only as a `pr_runner` input written
  # exactly one way, or inside a runs-on branch that a pull_request condition
  # guards. Parsed as YAML, so a block scalar or a second output is seen too.
  local violations
  violations="$(python3 - "$ROOT_DIR/.github/workflows" <<'PYTHON'
import re
import sys
from pathlib import Path

import yaml

PICKED = "steps.macos-pool.outputs.runner"
RETRY_PICKED = "steps.macos-pool.outputs.retry_runner"
OUTPUT = "needs.changes.outputs.macos_pr_runner"
RETRY_OUTPUT = "needs.changes.outputs.macos_pr_retry_runner"
PASSED = "${{ needs.changes.outputs.macos_pr_runner }}"
# Each input the picked pools reach a reusable workflow through, and its value.
INPUTS = {"pr_runner": PASSED, "pr_retry_runner": "${{ " + RETRY_OUTPUT + " }}"}
MARKER = ("macos-pool-persistent-${{ github.run_id }}-${{ github.run_attempt }}"
          "-${{ steps.macos-pool.outputs.jobs }}-${{ steps.macos-pool.outputs.runner }}")
# The runs-on branches that may read the picked pool, each behind its
# pull_request condition; a fork head keeps only a Blacksmith pick.
GUARDED = (
    "github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository"
    " && (startsWith(needs.changes.outputs.macos_pr_runner, 'blacksmith-') && needs.changes.outputs.macos_pr_runner"
    " || 'blacksmith-6vcpu-macos-15')",
    "github.event_name == 'pull_request' && (needs.changes.outputs.macos_pr_runner || vars.MACOS_RUNNER_PR"
    " || 'blacksmith-6vcpu-macos-15')",
    # A re-run of failed jobs on an owned-pool run: the Blacksmith pool the
    # picker named for it.
    "github.event_name == 'pull_request' && github.run_attempt > 1 && needs.changes.outputs.macos_pr_retry_runner",
)


def strings(node, path):
    if isinstance(node, dict):
        for key, value in node.items():
            yield from strings(value, path + (str(key),))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from strings(value, path + (str(index),))
    elif isinstance(node, str):
        yield path, node


violations = []
for file in sorted(Path(sys.argv[1]).glob("*.y*ml")):
    workflow = yaml.safe_load(file.read_text(encoding="utf-8")) or {}
    for path, value in strings(workflow, ()):
        where = f"{file.name}:{'.'.join(path)}"
        if PICKED in value:
            allowed = (file.name == "ci.yml" and (
                path == ("jobs", "changes", "outputs", "macos_pr_runner") and value == "${{ " + PICKED + " }}"
                or path[:3] == ("jobs", "changes", "steps") and path[-2:] == ("env", "POOL")
                and value == "${{ " + PICKED + " }}"
                or path[:3] == ("jobs", "changes", "steps") and path[-2:] == ("with", "name") and value == MARKER))
            if not allowed:
                violations.append(f"{where}: reads the picker's runner outside macos_pr_runner and the rescue marker")
        if RETRY_PICKED in value and not (
                file.name == "ci.yml" and path == ("jobs", "changes", "outputs", "macos_pr_retry_runner")
                and value == "${{ " + RETRY_PICKED + " }}"):
            violations.append(f"{where}: reads the picker's retry runner outside macos_pr_retry_runner")
        if len(path) >= 3 and path[-2] == "with" and path[-1] in INPUTS:
            if value != INPUTS[path[-1]] or file.name != "ci.yml":
                violations.append(f"{where}: {path[-1]} must be exactly {INPUTS[path[-1]]}")
            continue
        if OUTPUT not in value and RETRY_OUTPUT not in value:
            continue
        if path[-1:] == ("runs-on",):
            rest = value
            for branch in GUARDED:
                rest = rest.replace(branch, "")
            if OUTPUT not in rest and RETRY_OUTPUT not in rest:
                continue
        violations.append(f"{where}: reads macos_pr_runner outside pr_runner or a pull_request runs-on branch")
print("\n".join(violations))
PYTHON
)"
  if [ -n "$violations" ]; then
    echo "FAIL: the picked pull request pool must reach jobs only through pr_runner_pool.py's checked route"
    echo "$violations"
    exit 1
  fi
  echo "PASS: owned pool labels reach jobs only through the pull request pool picker"
}

check_cla_guard_runner

# ci-macos.yml jobs
check_no_bare_github_hosted_runners
check_no_self_hosted_fleet_runners
check_owned_pools_route_through_picker
check_macos_runner "$CI_MACOS_FILE" "app-host-unit-tests"
check_macos_runner "$CI_MACOS_FILE" "macos-compile-admission"
check_macos_runner "$CI_MACOS_FILE" "tests-build-and-lag"
check_macos_runner "$CI_MACOS_FILE" "release-build"
check_release_build_runner_disk_capacity
check_display_runner_identity_guard "$CI_MACOS_FILE" "tests-build-and-lag"

# build-ghosttykit.yml (routed through the MACOS_RUNNER_BACKGROUND repo var)
check_macos_runner "$GHOSTTYKIT_FILE" "build-ghosttykit"

# ci-macos-compat.yml (matrix.os routed through the MACOS_RUNNER_* repo vars)
check_macos_runner "$COMPAT_FILE" "compat-tests"

# test-e2e.yml is manual, so keep the supported GUI runner choices but cancel
# duplicate queued runs for the same ref/filter/runner.
check_e2e_runner_fallbacks
check_ios_tart_canary

check_xcode_selection
check_release_build_signal
check_release_build_disk_cleanup
check_release_helper_artifact_from_package_lane
check_runtime_regressions_collapsed
check_signing_intermediate_imports
check_signing_intermediate_helper_behavior
check_sentry_cli_install_portability
check_sentry_cli_helper_behavior

pr_workflow_events() {
  # Prints the pull request events a workflow triggers on, for the mapping,
  # list and scalar forms of `on:`.
  awk '
    /^on:/ {
      in_on=1
      line=$0
      sub(/^on:[[:space:]]*/, "", line)
      gsub(/[][,]/, " ", line)
      n=split(line, words, /[[:space:]]+/)
      for (i=1; i<=n; i++) if (words[i] ~ /^pull_request(_target)?$/) print words[i]
      next
    }
    in_on && /^[^[:space:]#]/ { in_on=0 }
    in_on && /^  (- )?pull_request(_target)?:?[[:space:]]*$/ {
      event=$0
      gsub(/[-:[:space:]]/, "", event)
      print event
    }
  ' "$1" | sort -u
}

pr_concurrency_cancels_superseded_runs() {
  # The group must be the same for every push to one pull request, and
  # cancel-in-progress must be true for new source pushes. Label-only events
  # may preserve a running compile so full-ci escalation can reuse it.
  local file="$1" event
  local events group_key
  events="$(pr_workflow_events "$file")"
  [ -n "$events" ] || return 1
  # github.ref is the base branch on pull_request_target, so only the pull
  # request number separates two pull requests there.
  group_key='github\.(event\.pull_request\.number|ref)([^_a-z]|$)'
  if grep -qx 'pull_request_target' <<<"$events"; then
    group_key='github\.event\.pull_request\.number([^_a-z]|$)'
  fi
  GROUP_KEY="$group_key" awk '
    /^concurrency:/ { in_block=1; next }
    in_block && /^[^[:space:]]/ { in_block=0 }
    in_block && /^[[:space:]]+group:/ && $0 ~ ENVIRON["GROUP_KEY"] { group_ok=1 }
    END { exit !group_ok }
  ' "$file" || return 1
  for event in $events; do
    EVENT="$event" awk '
      /^concurrency:/ { in_block=1; next }
      in_block && /^[^[:space:]]/ { in_block=0 }
      in_block && /^[[:space:]]+cancel-in-progress:[[:space:]]*true[[:space:]]*$/ { ok=1 }
      in_block && /^[[:space:]]+cancel-in-progress:/ {
        value=$0
        sub(/^[[:space:]]+cancel-in-progress:[[:space:]]*/, "", value)
        sub(/[[:space:]]+$/, "", value)
        if (value == "${{ github.event_name == \047" ENVIRON["EVENT"] "\047 }}") ok=1
        # Recognize only the CI workflow label exception: synchronize still
        # cancels the old head. Extra clauses could suppress that cancellation.
        if (ENVIRON["EVENT"] == "pull_request" &&
            value == "${{ github.event_name == \047pull_request\047 && github.event.action != \047labeled\047 && github.event.action != \047unlabeled\047 }}") ok=1
      }
      END { exit !ok }
    ' "$file" || return 1
  done
}

check_ios_only_tests_stay_under_ios() {
  # ios/** is explicitly macOS-neutral in detect_ci_change_areas.py. Keep new
  # iOS-only tests there. One historical file predates this rule; freeze it
  # byte-for-byte so editing or deleting it cannot silently select macOS again.
  local legacy_rel="scripts/lib/ios-tagged-device-entitlements.test.mjs"
  local legacy_blob="3d47fca8fa3515d3fd74538a5618e31864dab973"
  local legacy_path="$ROOT_DIR/$legacy_rel"
  local file rel
  local misplaced=""

  if [ ! -f "$legacy_path" ]; then
    echo "FAIL: $legacy_rel is frozen because deleting it triggers macOS compile admission; keep it and put replacements under ios/tests/"
    return 1
  fi
  if [ "$(git -C "$ROOT_DIR" hash-object "$legacy_path")" != "$legacy_blob" ]; then
    echo "FAIL: $legacy_rel is frozen because edits there trigger macOS compile admission; put the replacement under ios/tests/"
    return 1
  fi

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    rel="${file#"$ROOT_DIR/"}"
    [ "$rel" = "$legacy_rel" ] && continue
    misplaced="${misplaced}${misplaced:+$'\n'}$rel"
  done < <(
    find "$ROOT_DIR/scripts/lib" -type f \
      \( -name 'ios-*.test.mjs' -o -name 'iphone-*.test.mjs' -o -name 'ipad-*.test.mjs' -o -path '*/ios/*.test.mjs' \) \
      -print 2>/dev/null || true
  )

  if [ -n "$misplaced" ]; then
    echo "FAIL: iOS-only Node tests under scripts/lib trigger macOS compile admission; move them under ios/tests/"
    printf '%s\n' "$misplaced"
    return 1
  fi
  echo "PASS: iOS-only Node tests stay in the macOS-neutral ios/tests tree"
}

check_pr_macos_workflows_cancel_superseded_runs() {
  # Without a concurrency group a push never cancels the previous run, and on
  # a fixed pool of macOS runners those dead runs queue ahead of live ones.
  local file failed=0 probe case_text
  probe="$(mktemp)"
  # trigger ~ group ~ cancel-in-progress ~ expected
  while IFS='~' read -r trigger group cancel expected; do
    [ -n "$trigger" ] || continue
    printf '%s\nconcurrency:\n  group: %s\n  cancel-in-progress: %s\njobs:\n' \
      "$(printf '%b' "$trigger")" "$group" "$cancel" > "$probe"
    if pr_concurrency_cancels_superseded_runs "$probe"; then case_text=accept; else case_text=reject; fi
    if [ "$case_text" != "$expected" ]; then
      echo "FAIL: superseded-run guard self-test expected $expected for: $trigger | $group | $cancel"
      rm -f "$probe"
      exit 1
    fi
  done <<'CASES'
on:\n  pull_request:~ci-${{ github.ref }}~true~accept
on: pull_request~ci-${{ github.ref }}~${{ github.event_name == 'pull_request' }}~accept
on: pull_request~ci-${{ github.ref }}~${{ github.event_name == 'pull_request' && github.event.action != 'labeled' && github.event.action != 'unlabeled' }}~accept
on: pull_request~ci-${{ github.ref }}~${{ github.event_name == 'pull_request' && github.event.action != 'synchronize' }}~reject
on: pull_request~ci-${{ github.ref }}~${{ github.event_name == 'pull_request' && github.event.action != 'labeled' && github.event.action != 'unlabeled' && false }}~reject
on: pull_request~ci-${{ github.ref }}~${{ github.event_name == 'push' && github.event.action != 'labeled' && github.event.action != 'unlabeled' }}~reject
on: pull_request_target~ci-${{ github.event.pull_request.number }}~${{ github.event_name == 'pull_request' && github.event.action != 'labeled' && github.event.action != 'unlabeled' }}~reject
on: [push, pull_request]~ci-${{ github.event.pull_request.number || github.run_id }}~${{ github.event_name == 'pull_request' }}~accept
on:\n  pull_request_target:~ci-${{ github.event.pull_request.number }}~${{ github.event_name == 'pull_request_target' }}~accept
on:\n  pull_request_target:~ci-${{ github.ref }}~true~reject
on:\n  pull_request:~ci-${{ github.head_ref }}~true~reject
on:\n  pull_request:~ci-${{ github.ref }}~${{ github.event_name == 'pull_request' && false }}~reject
on:\n  pull_request:~ci-${{ github.sha }}~true~reject
on:\n  pull_request:~ci-${{ github.run_id }}~true~reject
on:\n  pull_request:~ci-${{ github.ref }}~${{ false }}~reject
on:\n  pull_request:~ci-${{ github.ref }}~${{ github.event_name == 'push' }}~reject
on:\n  pull_request:~ci-${{ github.ref }}~${{ github.event_name != 'pull_request' }}~reject
on:\n  pull_request:~ci-${{ github.ref }}~${{ github.event_name == 'pull_request_target' }}~reject
on:\n  pull_request:\n  pull_request_target:~ci-${{ github.ref }}~${{ github.event_name == 'pull_request' }}~reject
CASES
  rm -f "$probe"

  for file in "$ROOT_DIR"/.github/workflows/*.yml "$ROOT_DIR"/.github/workflows/*.yaml; do
    [ -f "$file" ] || continue
    grep -qE 'runs-on:.*(macos|MACOS_RUNNER)' "$file" || continue
    if [ -z "$(pr_workflow_events "$file")" ]; then
      # A quoted "on" key, flow mapping or other indentation is not read
      # above. Fail instead of skipping a workflow that may run on pull requests.
      if awk '
        /^["\047]?on["\047]?:/ { in_on=1; print; next }
        in_on && /^[^[:space:]#]/ { in_on=0 }
        in_on { print }
      ' "$file" | grep -q 'pull_request'; then
        echo "FAIL: $(basename "$file") names pull_request in a form this guard cannot read; write on: as a block mapping, a list or a single event"
        failed=1
      fi
      continue
    fi
    if ! pr_concurrency_cancels_superseded_runs "$file"; then
      echo "FAIL: $(basename "$file") runs macOS jobs on pull requests but a new push does not cancel the previous run; key the concurrency group on the pull request and set cancel-in-progress for its pull request events"
      failed=1
    fi
  done
  [ "$failed" -eq 0 ] || exit 1
  echo "PASS: pull request workflows with macOS jobs cancel superseded runs"
}

check_macos_xcode_pin_tracks_pull_request_lane() {
  # A pull-request macOS job picks its pool through MACOS_RUNNER_PR and its
  # toolchain through CMUX_CI_XCODE_APP. The two macOS images carry different
  # Xcodes and scripts/select-ci-xcode.sh exits non-zero on a pinned path that
  # is not installed, so a value naming the macos-15 Xcode in a job whose pool
  # can move is a job that fails at Xcode selection the moment the lane moves.
  #
  # Default-deny rather than an allowlist of covered jobs: every env value under
  # .github/workflows that names the macos-15 Xcode must also read the
  # pull-request variant, unless its exact (file, job, key) is exempted below
  # with a reason. A macOS job added next month inherits the rule for free.
  local violations
  violations="$(python3 - "$ROOT_DIR/.github/workflows" <<'PYTHON'
import sys
from pathlib import Path

import yaml

# (workflow file, job id, env key) -> why this site keeps the macos-15 Xcode
# regardless of where the pull-request lane points.
EXEMPT = {
    ("iroh-release-gate.yml", "tailscale-version-skew", "CMUX_CI_XCODE_APP"):
        "uses the macOS 15 Xcode configuration; runs on MACOS_RUNNER_15 for paid overflow or blacksmith-6vcpu-macos-15 otherwise",
    ("ci-macos.yml", "swift-package-tests", "CMUX_CI_XCODE_APP"):
        "builds the SDK 15 Ghostty helper; stays on MACOS_RUNNER_DUAL_XCODE",
    ("ci-macos.yml", "swift-package-tests", "CMUX_CI_HELPER_XCODE_APP"):
        "same job's SDK 15 release-helper pin",
    ("ci.yml", "changes", "CMUX_CI_XCODE_APP_MACOS_15"):
        "a Linux job; pr_runner_pool.py hands this pin on only to a run it routes to the macOS 15 pool",
}

PINNED = ("CMUX_CI_XCODE_APP_MACOS_15", "CMUX_CI_HELPER_XCODE_APP_MACOS_15")
LANE = ("CMUX_CI_XCODE_APP_PR", "CMUX_CI_HELPER_XCODE_APP_PR")

violations = []
for path in sorted(Path(sys.argv[1]).glob("*.yml")):
    try:
        document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError as error:
        violations.append(f"{path.name}: unparseable ({error})")
        continue
    for job_id, job in (document.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        scopes = [job]
        scopes.extend(step for step in (job.get("steps") or []) if isinstance(step, dict))
        for scope in scopes:
            for key, value in ((scope.get("env") or {})).items():
                if not isinstance(value, str):
                    continue
                if not any(name in value for name in PINNED):
                    continue
                if any(name in value for name in LANE):
                    continue
                if (path.name, job_id, key) in EXEMPT:
                    continue
                violations.append(f"{path.name}::{job_id}: {key}: {value.strip()}")

print("\n".join(violations))
PYTHON
)"
  if [ -n "$violations" ]; then
    echo "FAIL: a macos-15 Xcode pin does not follow the pull-request lane"
    echo "      Route it through CMUX_CI_XCODE_APP_PR, or add its (file, job, key) to"
    echo "      EXEMPT with a reason."
    printf '%s\n' "$violations"
    exit 1
  fi
  echo "PASS: every macos-15 Xcode pin either follows the pull-request lane or is exempt with a reason"
}

check_macos_runner_identity_env_tracks_routing() {
  # A macOS job picks its pool in `runs-on`, and some jobs then restate that
  # pool in an env value: `CMUX_PRODUCT_RUNNER` becomes a field of the compiled
  # product contract, and `REQUESTED_RUNNER` is what the Depot identity guard
  # validates. Those restatements are only meaningful when they name the pool
  # the job is actually on. `runs-on` sends pull requests to MACOS_RUNNER_PR
  # and every other event to the lane variable, so an env value that reads only
  # the lane variable is wrong on every pull request: the product contract
  # stamps a pool the build never ran on, which lets two pools with different
  # workspace layouts share one contract key, and the identity guard validates
  # a runner the job is not on.
  #
  # Require every MACOS_RUNNER-bearing env value in ci-macos.yml to be the same
  # expression as its own job's `runs-on`, so a future routing change cannot
  # move a job without moving what that job reports about itself.
  # Parse YAML so mapping order, quoting, and folded scalars cannot hide an
  # identity value. A parser failure aborts under set -e rather than passing.
  local mismatches
  mismatches="$(python3 - "$CI_MACOS_FILE" <<'PYTHON'
import sys
from pathlib import Path
import yaml


def mismatched_identities(document):
    for job_id, job in document.get("jobs", {}).items():
        runs_on = job.get("runs-on")
        scopes = [("job", job)]
        scopes.extend((f"step {index}", step) for index, step in enumerate(job.get("steps", [])))
        for scope, owner in scopes:
            for key, value in (owner.get("env") or {}).items():
                if isinstance(value, str) and "vars.MACOS_RUNNER" in value and value != runs_on:
                    yield f"{job_id}/{scope}: {key}\n  env value {value}\n  runs-on   {runs_on}"


# Exercise forms the line-based guard missed: env before runs-on, quoted keys
# containing digits, folded scalars, and both job-level and step-level env.
fixture = yaml.safe_load("""
jobs:
  example:
    env:
      'RUNNER2': >-
        ${{ vars.MACOS_RUNNER }}
    steps:
      - env:
          'STEP_RUNNER2': '${{ vars.MACOS_RUNNER }}'
    runs-on: >-
      ${{ vars.MACOS_RUNNER }}
""")
assert not list(mismatched_identities(fixture))
fixture["jobs"]["example"]["runs-on"] = "${{ vars.MACOS_RUNNER_PR }}"
assert len(list(mismatched_identities(fixture))) == 2
fixture["jobs"]["example"].pop("runs-on")
assert len(list(mismatched_identities(fixture))) == 2

print("\n".join(mismatched_identities(yaml.safe_load(Path(sys.argv[1]).read_text()))))
PYTHON
)"
  if [ -n "$mismatches" ]; then
    echo "FAIL: a macOS runner env value in ci-macos.yml does not match its job's runs-on,"
    echo "      so it names the wrong pool on pull requests (see docs/ci-runners.md)"
    echo "$mismatches"
    exit 1
  fi
  echo "PASS: every macOS runner env value in ci-macos.yml matches its job's runs-on"
}

check_no_paid_overflow_fallbacks() {
  # Forks take the explicit GitHub-hosted owner branch before any repository
  # variable is read. The upstream fallback must still avoid Warp: it is the
  # paid overflow provider, allowed as an explicit workflow_dispatch choice,
  # never as an implicit default.
  local hits
  hits="$(grep -rnE "\\|\\|[[:space:]]*'warp-" "$ROOT_DIR/.github/workflows" || true)"
  if [ -n "$hits" ]; then
    echo "FAIL: workflows must not fall back to a Warp runner; use the Blacksmith label the rest of CI falls back to"
    echo "$hits" | sed "s|$ROOT_DIR/||" | cut -c1-160
    exit 1
  fi
  echo "PASS: no workflow falls back to a Warp runner"
}

background_lane_blocking_events() {
  # Prints the triggers that would put a workflow on a merge or pull request
  # critical path, for the mapping, list and scalar forms of `on:`.
  # workflow_call counts because a caller may be a pull request workflow.
  awk '
    /^["\047]?on["\047]?:/ {
      in_on=1
      line=$0
      sub(/^["\047]?on["\047]?:[[:space:]]*/, "", line)
      gsub(/[][,]/, " ", line)
      n=split(line, words, /[[:space:]]+/)
      for (i=1; i<=n; i++) if (words[i] ~ /^(pull_request(_target)?|merge_group|workflow_call)$/) print words[i]
      next
    }
    in_on && /^[^[:space:]#]/ { in_on=0 }
    in_on && /^  (- )?(pull_request(_target)?|merge_group|workflow_call):?[[:space:]]*$/ {
      event=$0
      gsub(/[-:[:space:]]/, "", event)
      print event
    }
  ' "$1" | sort -u
}

strip_background_lane_expr() {
  # Ignore the sanctioned GitHub-hosted macOS forms before looking for a
  # stray hosted label: the non-blocking background lane, and the explicit
  # non-manaflow-ai fork branch used by the normal CI graph (macos-26, or
  # macos-15 for the jobs that need that image).
  awk -v e="vars.MACOS_RUNNER_BACKGROUND || 'macos-15'" \
      -v f="github.repository_owner != 'manaflow-ai' && 'macos-15' || " \
      -v g="github.repository_owner != 'manaflow-ai' && 'macos-26' || " '{
    while ((i = index($0, e)) > 0) $0 = substr($0, 1, i - 1) substr($0, i + length(e))
    while ((i = index($0, f)) > 0) $0 = substr($0, 1, i - 1) substr($0, i + length(f))
    while ((i = index($0, g)) > 0) $0 = substr($0, 1, i - 1) substr($0, i + length(g))
    print
  }'
}

check_background_macos_lane() {
  # MACOS_RUNNER_BACKGROUND is the only place a free GitHub-hosted macOS label
  # may appear: as that variable's in-workflow fallback. The lane moves
  # non-urgent macOS work (dispatch-only, post-merge, on-demand packaging) off
  # the shared macOS pool that pull requests queue on. Unset, the variable
  # resolves to the fallback; an admin can repoint the whole lane with one
  # variable edit. macos-26 is not allowed: the self-hosted fleet carries it.
  local lane_expr="vars.MACOS_RUNNER_BACKGROUND || 'macos-15'"
  local hosted_mac='(^|[^A-Za-z0-9_-])macos-(latest|[0-9]+)(-(intel|large|xlarge|arm64))?([^A-Za-z0-9_-]|$)'
  # Pre-existing OS-version compatibility legs that need a specific hosted
  # image (macOS 14, Intel) that no paid provider offers. Exact lines only.
  local -a hosted_exceptions=(
    "ci-macos-compat.yml:          - os: macos-14"
    "ci-macos-compat.yml:          - os: macos-15-intel"
    "relay-publish-npm.yml:          - os: macos-14"
  )
  local failed=0 probe

  # Self-test: bare or other-variable hosted labels are caught; the lane
  # fallback and paid/fleet labels are not.
  for probe in "runs-on: \${{ vars.X || 'macos-15' }}" 'runs-on: macos-15' '- macos-latest' \
               "macos_runner: \${{ inputs.r || 'macos-26' }}" '      os: macos-15-xlarge' \
               "runs-on: \${{ vars.MACOS_RUNNER_BACKGROUND || 'macos-14' }}"; do
    if ! printf '%s\n' "$probe" | strip_background_lane_expr | grep -Eq "$hosted_mac"; then
      echo "FAIL: background-lane guard self-test missed a GitHub-hosted macOS label: $probe"
      exit 1
    fi
  done
  for probe in "runs-on: \${{ $lane_expr }}" \
               "macos_runner: \${{ inputs.macos_runner || $lane_expr }}" \
               "runs-on: \${{ vars.MACOS_RUNNER_15 || 'blacksmith-6vcpu-macos-15' }}" \
               '- warp-macos-15-arm64-6x' '- tart-macos-15'; do
    if printf '%s\n' "$probe" | strip_background_lane_expr | grep -Eq "$hosted_mac"; then
      echo "FAIL: background-lane guard self-test flagged an allowed runner: $probe"
      exit 1
    fi
  done

  # 1. GitHub-hosted macOS labels in runner-selection positions appear only as
  #    the background lane fallback or an exact compatibility-leg exception.
  local line file content rel exception allowed
  while IFS= read -r line; do
    file="${line%%:*}"
    content="${line#*:*:}"
    rel="$(basename "$file")"
    printf '%s\n' "$content" | strip_background_lane_expr | grep -Eq "$hosted_mac" || continue
    allowed=0
    for exception in "${hosted_exceptions[@]}"; do
      if [[ "$rel:$content" == "$exception" ]]; then allowed=1; break; fi
    done
    [[ "$allowed" -eq 1 ]] && continue
    echo "FAIL: GitHub-hosted macOS label outside the background lane: ${line#"$ROOT_DIR"/}"
    echo "      Use \${{ $lane_expr }} for non-urgent work, or a MACOS_RUNNER_* variable with a Blacksmith fallback."
    failed=1
  done < <(grep -rnE "(runs-on:|[[:space:]](os|runner|macos_runner):[[:space:]]|^[[:space:]]*-[[:space:]]+[A-Za-z0-9._-]+[[:space:]]*$)" "$ROOT_DIR/.github/workflows")

  # 2. Every reference carries exactly the hosted fallback, so an unset
  #    variable (and every fork) lands on free capacity, never Warp.
  # 3. Members stay off the pull request and merge critical path.
  local ref_count expr_count events
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    ref_count="$({ grep -o 'vars\.MACOS_RUNNER_BACKGROUND' "$file" || true; } | wc -l | tr -d ' ')"
    expr_count="$({ grep -oF "$lane_expr" "$file" || true; } | wc -l | tr -d ' ')"
    if [[ "$ref_count" != "$expr_count" ]]; then
      echo "FAIL: $(basename "$file") references vars.MACOS_RUNNER_BACKGROUND without the fallback || 'macos-15'"
      failed=1
    fi
    if ! grep -qE '^["\047]?on["\047]?:' "$file"; then
      echo "FAIL: $(basename "$file") uses the background macOS lane but its on: block is unreadable"
      failed=1
      continue
    fi
    events="$(background_lane_blocking_events "$file" | tr '\n' ' ')"
    if [[ -n "$events" ]]; then
      echo "FAIL: $(basename "$file") uses the background macOS lane but triggers on: $events"
      echo "      The background lane is for dispatch-only, scheduled and post-merge work."
      failed=1
    fi
  done < <(grep -rlF 'vars.MACOS_RUNNER_BACKGROUND' "$ROOT_DIR/.github/workflows" || true)

  [ "$failed" -eq 0 ] || exit 1
  echo "PASS: GitHub-hosted macOS labels appear only as the MACOS_RUNNER_BACKGROUND fallback on non-blocking workflows"
}

check_dmg_signing_uses_build_keychain
check_create_dmg_uses_run_local_npm_prefix
check_gui_smoke_unsupported_launch_handling
check_no_ci_xctest_skips
check_no_ci_swift_package_skips
check_web_db_behavior_tests
check_web_test_runner_behavior
check_tmux_terminal_nightly_isolation
check_pr_macos_workflows_cancel_superseded_runs
check_ios_only_tests_stay_under_ios
check_no_paid_overflow_fallbacks
check_macos_runner_identity_env_tracks_routing
check_macos_xcode_pin_tracks_pull_request_lane
check_background_macos_lane
