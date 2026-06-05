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

check_windows_scope_gate() {
  if ! grep -Fq "ci-scope:" "$CI_FILE"; then
    echo "FAIL: ci.yml must classify PR scope before scheduling paid macOS jobs"
    exit 1
  fi

  if ! grep -Fq "windows/*|README.md|.gitignore|.gitattributes|.github/workflows/windows-app.yml|.github/workflows/windows-release.yml|.github/workflows/ci.yml|.github/workflows/perf-activation.yml|tests/test_ci_self_hosted_guard.sh)" "$CI_FILE"; then
    echo "FAIL: ci.yml must treat Windows-only PRs as not requiring macOS runners"
    exit 1
  fi

  for job in tests tests-build-and-lag release-build ui-regressions; do
    if ! awk -v job="$job" '
      $0 ~ "^  "job":" { in_job=1; saw_needs=0; saw_if=0; next }
      in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ {
        if (!(saw_needs && saw_if)) exit 1
        in_job=0
      }
      in_job && /^[[:space:]]+needs:[[:space:]]*ci-scope[[:space:]]*$/ { saw_needs=1 }
      in_job && /^[[:space:]]+if:[[:space:]]*needs\.ci-scope\.outputs\.requires_macos == '\''true'\''[[:space:]]*$/ { saw_if=1 }
      END {
        if (in_job && !(saw_needs && saw_if)) exit 1
      }
    ' "$CI_FILE"; then
      echo "FAIL: $job must depend on ci-scope and skip for Windows-only PRs"
      exit 1
    fi
  done

  echo "PASS: Windows-only PRs skip paid macOS CI jobs"
}

check_activation_scope_gate() {
  if ! grep -Fq "activation-scope:" "$PERF_FILE"; then
    echo "FAIL: perf-activation.yml must classify PR scope before scheduling paid macOS activation runs"
    exit 1
  fi

  if ! grep -Fq "windows/*|README.md|.gitignore|.gitattributes|.github/workflows/windows-app.yml|.github/workflows/windows-release.yml|.github/workflows/ci.yml|.github/workflows/perf-activation.yml|tests/test_ci_self_hosted_guard.sh)" "$PERF_FILE"; then
    echo "FAIL: perf-activation.yml must treat Windows-only PRs as not requiring activation performance runners"
    exit 1
  fi

  if ! awk '
    /^  activation-session:/ { in_job=1; saw_needs=0; saw_if=0; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ {
      if (!(saw_needs && saw_if)) exit 1
      in_job=0
    }
    in_job && /^[[:space:]]+needs:[[:space:]]*activation-scope[[:space:]]*$/ { saw_needs=1 }
    in_job && /^[[:space:]]+if:[[:space:]]*needs\.activation-scope\.outputs\.requires_activation == '\''true'\''[[:space:]]*$/ { saw_if=1 }
    END {
      if (in_job && !(saw_needs && saw_if)) exit 1
    }
  ' "$PERF_FILE"; then
    echo "FAIL: activation-session must depend on activation-scope and skip for Windows-only PRs"
    exit 1
  fi

  echo "PASS: Windows-only PRs skip activation performance runs"
}

# ci.yml jobs
check_macos_runner "$CI_FILE" "tests"
check_macos_runner "$CI_FILE" "tests-build-and-lag"
check_macos_runner "$CI_FILE" "release-build"
check_macos_runner "$CI_FILE" "ui-regressions"
check_windows_scope_gate
check_macos_runner "$PERF_FILE" "activation-session"
check_activation_scope_gate

# build-ghosttykit.yml
check_macos_runner "$GHOSTTYKIT_FILE" "build-ghosttykit"

# ci-macos-compat.yml (matrix.os routed through the MACOS_RUNNER_* repo vars)
check_macos_runner "$COMPAT_FILE" "compat-tests"

# test-e2e.yml is manual, so keep the Depot GUI runner choices but cancel
# duplicate queued runs for the same ref/filter/runner.
check_e2e_runner_fallbacks

check_xcode_selection
check_release_build_signal
