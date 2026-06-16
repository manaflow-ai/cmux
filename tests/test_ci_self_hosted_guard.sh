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
    in_job && /runs-on:.*(vars\.MACOS_RUNNER|blacksmith-[0-9]+vcpu-macos-|warp-macos-[0-9]+-arm64|depot-macos-)/ { saw=1 }
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
  done

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

check_sentry_cli_install_portability() {
  local helper="$ROOT_DIR/scripts/ensure-sentry-cli.sh"
  if [[ ! -x "$helper" ]]; then
    echo "FAIL: sentry-cli helper must exist and be executable"
    exit 1
  fi

  for needle in \
    'https://sentry.io/get-cli/' \
    'INSTALL_DIR="${RUNNER_TEMP:-/tmp}/sentry-cli-bin"' \
    'SENTRY_CLI_VERSION="${SENTRY_CLI_VERSION:-3.3.0}"' \
    '--connect-timeout 20' \
    '--max-time 120' \
    'sh >&2'; do
    if ! grep -Fq -- "$needle" "$helper"; then
      echo "FAIL: sentry-cli helper must contain $needle"
      exit 1
    fi
  done

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

check_dmg_signing_uses_build_keychain() {
  for file in "$ROOT_DIR/.github/workflows/nightly.yml" "$ROOT_DIR/.github/workflows/release.yml"; do
    if grep -Fq -- '--identity="$APPLE_SIGNING_IDENTITY"' "$file"; then
      echo "FAIL: $(basename "$file") must not let create-dmg codesign outside build.keychain"
      exit 1
    fi

    if ! awk '
      /create-dmg[[:space:]]*\\/ { in_dmg=1; next }
      in_dmg && /\/usr\/bin\/codesign --force --timestamp --keychain build\.keychain/ { saw_keychain=1 }
      in_dmg && /--sign "\$APPLE_SIGNING_IDENTITY"/ { saw_identity=1 }
      in_dmg && /\/usr\/bin\/codesign --verify --verbose=2 "\$(DMG_RELEASE|dmg_release)"/ { saw_verify=1 }
      in_dmg && /xcrun notarytool submit "\$(DMG_RELEASE|dmg_release)"/ { saw_notary=1 }
      END { exit !(saw_keychain && saw_identity && saw_verify && saw_notary) }
    ' "$file"; then
      echo "FAIL: $(basename "$file") must sign DMGs explicitly with build.keychain before notarization"
      exit 1
    fi
  done

  echo "PASS: DMG signing uses build.keychain explicitly"
}

check_create_dmg_uses_run_local_npm_prefix() {
  for file in "$ROOT_DIR/.github/workflows/nightly.yml" "$ROOT_DIR/.github/workflows/release.yml"; do
    if ! awk '
      /- name: Install build deps/ { in_step=1; next }
      in_step && /^[[:space:]]*- name:/ { in_step=0 }
      in_step && /export npm_config_prefix="\$RUNNER_TEMP\/npm-global"/ { saw_prefix=1 }
      in_step && /mkdir -p "\$npm_config_prefix"/ { saw_mkdir=1 }
      in_step && /echo "\$npm_config_prefix\/bin" >> "\$GITHUB_PATH"/ { saw_path=1 }
      in_step && /npm install --global "create-dmg@\$\{CREATE_DMG_VERSION\}"/ { saw_install=1 }
      END { exit !(saw_prefix && saw_mkdir && saw_path && saw_install) }
    ' "$file"; then
      echo "FAIL: $(basename "$file") must install create-dmg into a run-local npm global prefix"
      exit 1
    fi
  done

  echo "PASS: create-dmg installs into run-local npm global prefix"
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
check_display_runner_identity_guard "$CI_FILE" "tests-build-and-lag"
check_display_runner_identity_guard "$CI_FILE" "ui-regressions"

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
check_signing_intermediate_imports
check_sentry_cli_install_portability
check_dmg_signing_uses_build_keychain
check_create_dmg_uses_run_local_npm_prefix
check_no_ci_xctest_skips
check_no_ci_swift_package_skips
check_web_db_behavior_tests
check_tmux_terminal_nightly_isolation
