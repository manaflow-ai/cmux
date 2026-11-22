#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/385.
# Ensures paid CI jobs use a paid macOS runner (Blacksmith or WarpBuild, routed
# through the MACOS_RUNNER_15 / MACOS_RUNNER_26 repo variables), never a free
# GitHub-hosted runner. Flip Blacksmith<->Warp by editing those repo variables;
# see docs/ci-runners.md. MACOS_RUNNER_BACKGROUND is the non-urgent lane, whose
# fallback is Blacksmith macos-15 and whose members must stay off the pull
# request and merge path (check_background_macos_lane). No job in manaflow-ai
# selects a GitHub-hosted runner (check_no_github_hosted_runners).
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
IOS_FILE="$ROOT_DIR/.github/workflows/test-ios.yml"
CLA_GUARD_FILE="$ROOT_DIR/.github/workflows/cla-policy-guard.yml"

check_cla_guard_runner() {
  # The guard parses attacker-controlled YAML with a trusted token, so only an
  # ephemeral runner may take it: GitHub-hosted ubuntu-24.04, or a one-job
  # Blacksmith VM through the CI_TRUSTED_RUNNER selector. The selector cannot
  # name a persistent machine (its allowlist lives in this base-branch file,
  # and anything else falls back to Blacksmith). validate-cla-policy.rb holds
  # the same exact allowlist and is the authority; this keeps it visible.
  local hosted selector runs_on
  hosted="    runs-on: ubuntu-24.04"
  selector="    runs-on: \${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || contains(fromJSON('[\"ubuntu-24.04\",\"blacksmith-2vcpu-ubuntu-2404\",\"blacksmith-4vcpu-ubuntu-2404\"]'), vars.CI_TRUSTED_RUNNER) && vars.CI_TRUSTED_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"
  runs_on="$(grep -E '^    runs-on:' "$CLA_GUARD_FILE" || true)"
  if [[ "$runs_on" != "$hosted" && "$runs_on" != "$selector" ]]; then
    echo "FAIL: cla-policy-guard.yml must use ubuntu-24.04 or the CI_TRUSTED_RUNNER ephemeral selector"
    exit 1
  fi

  if grep -Eq '^    runs-on:.*(vars\.LINUX_RUNNER|self-hosted|glaeda-)' "$CLA_GUARD_FILE"; then
    echo "FAIL: cla-policy-guard.yml must not allow a persistent or owned runner"
    exit 1
  fi

  # A Blacksmith VM reports runner.environment 'self-hosted', so the selector
  # needs the guard step that also admits Blacksmith scale-set VM names.
  local hosted_guard ephemeral_guard
  hosted_guard="        if: runner.environment != 'github-hosted'"
  ephemeral_guard="        if: (runner.environment != 'github-hosted' && !startsWith(runner.name, 'blacksmith-2vcpu-ubuntu-2404-Runner-') && !startsWith(runner.name, 'blacksmith-4vcpu-ubuntu-2404-Runner-')) || contains(runner.name, 'glaeda')"
  if [[ "$runs_on" == "$hosted" ]] && ! grep -Fqx "$hosted_guard" "$CLA_GUARD_FILE" && ! grep -Fqx "$ephemeral_guard" "$CLA_GUARD_FILE"; then
    echo "FAIL: cla-policy-guard.yml must refuse a runner that is not GitHub-hosted"
    exit 1
  fi
  if [[ "$runs_on" == "$selector" ]] && ! grep -Fqx "$ephemeral_guard" "$CLA_GUARD_FILE"; then
    echo "FAIL: cla-policy-guard.yml must refuse a runner that is neither GitHub-hosted nor Blacksmith"
    exit 1
  fi

  echo "PASS: CLA policy guard uses an ephemeral GitHub-hosted or Blacksmith runner"
}

check_macos_runner() {
  local file="$1" job="$2"
  if ! awk -v job="$job" '
    $0 ~ "^  "job":" { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && /runs-on:.*(vars\.MACOS_RUNNER|blacksmith-[0-9]+vcpu-macos-|warp-macos-[0-9]+-arm64|depot-macos-)/ { saw=1 }
    # A product consumer inherits the compile admission pool, which this
    # check covers on its own, or, on a re-run or when the picker did not
    # place this shard on the owned pool, the Blacksmith pool the pull
    # request picker named for a run on an owned pool (pr_retry_runner), or
    # the owned label on attempts 1 and 2. The
    # gui label (pr_gui_runner) names the GUI runners of that owned pick.
    # It may first take the label late-placement chose in this attempt (an owned
    # root runner found idle once admission finished; late_placement.py).
    in_job && /runs-on:[[:space:]]*\$\{\{ (needs\.late-placement\.outputs\.attempt == github\.run_attempt && fromJSON\(needs\.late-placement\.outputs\.runners \|\| .\{\}.\)\[format\(.shard-\{0\}., matrix\.shard\)\] \|\| )?(\(github\.run_attempt > 2 && \(github\.triggering_actor == .github-actions\[bot\]. \|\| github\.event_name != .pull_request.\) \|\| !contains\(inputs\.pr_owned_jobs, format\(. shard-\{0\} ., matrix\.shard\)\)\) && inputs\.pr_retry_runner \|\| )?(inputs\.pr_shard_runner \|\| )?(inputs\.pr_gui_runner \|\| )?needs\.macos-compile-admission\.outputs\.runner \}\}/ { saw=1 }
    in_job && /os:.*(vars\.MACOS_RUNNER|blacksmith-[0-9]+vcpu-macos-|warp-macos-[0-9]+-arm64|depot-macos-)/ { saw=1 }
    END { exit !(saw) }
  ' "$file"; then
    echo "FAIL: $job in $(basename "$file") must run on a paid macOS runner (vars.MACOS_RUNNER_* or a Blacksmith/Warp/Depot label), not a GitHub-hosted runner"
    exit 1
  fi
  echo "PASS: $job in $(basename "$file") uses a paid macOS runner"
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
  if ! awk -v release_runner="runs-on: \${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || (github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && !contains(fromJSON(inputs.owned_head_repos), github.event.pull_request.head.repo.full_name) && 'blacksmith-6vcpu-macos-26' || (github.event_name == 'pull_request' && contains(fromJSON(inputs.owned_head_repos), github.event.pull_request.head.repo.full_name) && (github.run_attempt <= 2 || github.triggering_actor != 'github-actions[bot]') || github.event_name == 'workflow_dispatch' && github.run_attempt <= 2) && contains(inputs.pr_owned_jobs, ' release-build ') && (inputs.pr_side_runner || inputs.pr_runner) || vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26') }}" '
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

check_ios_runner_routing() {
  # The runner job (scripts/ci/ios_runner_pool.py) resolves the dispatch
  # override, MACOS_RUNNER_TESTS, then MACOS_RUNNER_IOS, and the owned pool;
  # every macOS job reads its answer, and a re-run attempt its retry answer.
  # mobile-core-package needs no simulator, so it reads package_runs_on.
  if [[ "$(grep -Fc "runs-on: \${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || fromJSON(github.run_attempt > 1 && needs.runner.outputs.retry_runs_on || needs.runner.outputs.runs_on) }}" "$IOS_FILE")" -ne 1 ]] ||
     [[ "$(grep -Fc "runs-on: \${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || fromJSON(github.run_attempt > 1 && needs.runner.outputs.retry_runs_on || needs.runner.outputs.package_runs_on) }}" "$IOS_FILE")" -ne 1 ]]; then
    echo "FAIL: all macOS iOS test jobs must take the runner job's pool, which honors the dispatch runner override"
    exit 1
  fi
  if ! grep -Fq 'RUNNER_VARIABLE: ${{ vars.MACOS_RUNNER_TESTS || vars.MACOS_RUNNER_IOS }}' "$IOS_FILE" ||
     ! grep -Fq 'REQUESTED_RUNNER: ${{ inputs.runner }}' "$IOS_FILE"; then
    echo "FAIL: test-ios.yml's runner job must read the runner input, MACOS_RUNNER_TESTS and MACOS_RUNNER_IOS"
    exit 1
  fi
  echo "PASS: test-ios.yml routes every macOS job through the runner job"
}

check_xcode_selection() {
  if grep -R -n "ls -d /Applications/Xcode" "$ROOT_DIR/.github/workflows"; then
    echo "FAIL: workflow Xcode selection must use find/sort/tail fallback, not ls/glob ordering"
    exit 1
  fi

  echo "PASS: workflow Xcode selection avoids ls/glob ordering"
}

check_release_build_signal() {
  if ! grep -Fq './scripts/ci/verify-binary-archs.sh "$RELEASE_ARCHS" "$APP_BINARY" "$CLI_BINARY" "$HELPER_BINARY"' "$CI_MACOS_FILE"; then
    echo "FAIL: release-build must verify the app, CLI and helper contain exactly the producer-selected architectures"
    exit 1
  fi
  # bin/cmux-tui and bin/acpmux are symlinks to bin/cmux, checked by readlink.
  if ! grep -Fq 'for link in cmux-tui acpmux; do' "$CI_MACOS_FILE"; then
    echo "FAIL: release-build must check that bin/cmux-tui and bin/acpmux link to bin/cmux"
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
  # The one arm besides the dual-Xcode pool: the side label, else the owned
  # label, only when the picker placed ' swift-package ' in pr_owned_jobs,
  # which it does only for a run that skips the SDK 15 helper steps (pr_runner_pool.package_lane_owned()).
  # The opt-in build-fleet gateway (hq#794) likewise takes only a run without the helper.
  if ! awk -v dual_runner="runs-on: \${{ github.repository_owner != 'manaflow-ai' && 'macos-15' || (github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && !contains(fromJSON(inputs.owned_head_repos), github.event.pull_request.head.repo.full_name) && 'blacksmith-6vcpu-macos-15' || github.event_name == 'pull_request' && !(inputs.full_suite == 'true' && inputs.release_build == 'true') && vars.CI_SWIFT_PACKAGE_TESTS_STEP_GATEWAY || (github.event_name == 'pull_request' && contains(fromJSON(inputs.owned_head_repos), github.event.pull_request.head.repo.full_name) && (github.run_attempt <= 2 || github.triggering_actor != 'github-actions[bot]') || github.event_name == 'workflow_dispatch' && github.run_attempt <= 2) && contains(inputs.pr_owned_jobs, ' swift-package ') && (inputs.pr_side_runner || inputs.pr_runner) || vars.CI_PAID_MACOS_OVERFLOW == '1' && vars.MACOS_RUNNER_DUAL_XCODE || 'blacksmith-6vcpu-macos-15') }}" '
    /^  swift-package-tests:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }

    in_job && index($0, dual_runner) { saw_dual_runner=1 }
    in_job && /vars\.MACOS_RUNNER_PR/ { saw_pr_lane=1 }
    in_job && /timeout-minutes:[[:space:]]*60/ { saw_timeout=1 }
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

    # nightly.yml uploads through scripts/upload-sentry-dsyms.sh (retried,
    # never fatal), which installs through the same helper.
    if awk '
      /- name: Upload dSYMs to Sentry/ { in_step=1; next }
      in_step && /^[[:space:]]*- name:/ { in_step=0 }
      in_step && /\.\/scripts\/upload-sentry-dsyms\.sh/ { saw=1 }
      END { exit !saw }
    ' "$file"; then
      uploader="$ROOT_DIR/scripts/upload-sentry-dsyms.sh"
      if ! grep -Fq '/ensure-sentry-cli.sh")"' "$uploader" \
        || ! grep -Fq 'debug-files upload --include-sources' "$uploader"; then
        echo "FAIL: scripts/upload-sentry-dsyms.sh must install sentry-cli through scripts/ensure-sentry-cli.sh and upload with --include-sources"
        exit 1
      fi
      continue
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

check_no_github_hosted_runners() {
  # A GitHub billing block or a GitHub-hosted outage must never stop CI, so no
  # job in manaflow-ai may select a GitHub-hosted runner (ubuntu-*, macos-*,
  # windows-*). Jobs run on Blacksmith labels, the CI_TRUSTED_RUNNER selector
  # (Blacksmith by default), or owned pools reached through the pickers.
  # A `# github-hosted-required:` comment is no longer an exemption.
  # Allowed GitHub-hosted forms:
  #   - the fork branch `github.repository_owner != 'manaflow-ai' && '<label>'`
  #     (and `&& matrix.hosted_runner`), which never evaluates in manaflow-ai;
  #   - fork-only `hosted_runner` matrix values;
  #   - the label list inside the exact CI_TRUSTED_RUNNER selector, where
  #     GitHub-hosted is an operator choice and Blacksmith is the default;
  #   - the exact lines in `exceptions` below, each with the reason it cannot move.
  # Runner-selection positions: runs-on, labels/group, matrix os/runner keys,
  # scalar list items, dispatch defaults, and every *RUNNER* key (env mirrors
  # and inputs feed runs-on too).
  local hosted='(^|[^A-Za-z0-9_-])(ubuntu-(latest|slim|[0-9]{2}[.][0-9]{2}(-arm)?)|macos-(latest|[0-9]+(-intel|-large|-xlarge|-arm64)?)|windows-(latest|[0-9]{4}(-arm)?|11-arm))([^A-Za-z0-9_.-]|$)'
  local fork_branch="github[.]repository_owner != 'manaflow-ai' [&][&] ('[A-Za-z0-9._-]+'|matrix[.]hosted_runner)"
  local trusted_list='fromJSON[(]'"'"'[[]"ubuntu-24[.]04","blacksmith-2vcpu-ubuntu-2404","blacksmith-4vcpu-ubuntu-2404"[]]'"'"'[)], vars[.]CI_TRUSTED_RUNNER'
  # "<workflow>:<line content>" -> why it stays GitHub-hosted. Exact lines only.
  local -a exceptions=(
    # npm trusted publishing and --provenance accept only GitHub-hosted runners.
    "sdk-bootstrap-npm.yml:    runs-on: ubuntu-latest # github-hosted-required: npm provenance publishing"
    "sdk-release-cut.yml:    runs-on: ubuntu-latest # github-hosted-required: npm provenance needs a github-hosted runner"
    "sdk-release-cut.yml:    runs-on: ubuntu-latest # github-hosted-required: npm provenance verification"
    "tui-publish-npm.yml:    runs-on: ubuntu-latest # github-hosted-required: npm provenance needs a github-hosted runner"
    "cmux-tui-nightly.yml:    runs-on: ubuntu-latest # github-hosted-required: npm provenance needs a github-hosted runner"
    "relay-publish-npm.yml:    runs-on: ubuntu-latest # github-hosted-required: npm provenance needs a github-hosted runner"
    "cmux-tui-build-package.yml:    runs-on: ubuntu-latest # github-hosted-required: artifact attestations need GitHub OIDC"
    # Detects a Blacksmith outage, so it must run where Blacksmith is not.
    "ci-cloud-overflow-probe.yml:    runs-on: ubuntu-24.04 # github-hosted-required: must run while Blacksmith starts nothing"
    # validate-cla-policy.rb pins these to ubuntu-24.04 until #17453 lands.
    "cla.yml:    runs-on: ubuntu-24.04 # github-hosted-required: write token on fork pull requests"
    "cla-policy-guard.yml:    runs-on: ubuntu-24.04"
    # Dispatch-only Intel compatibility leg; Blacksmith has no Intel macOS image.
    # GitHub retired macos-14, so it is no longer an exception (#17068).
    "ci-macos-compat.yml:          - os: macos-15-intel"
    # Compare-only x86_64 run-time check of the Linux-built macOS binaries
    # (continue-on-error, so a billing block cannot stop CI).
    "cmux-tui-artifacts.yml:    runs-on: macos-15-intel # github-hosted-required: x86_64 run-time check; Blacksmith has no Intel Mac image"
    "macos-cross-parity.yml:    runs-on: macos-15-intel # github-hosted-required: x86_64 run-time check; Blacksmith has no Intel Mac image"
  )
  local probe
  for probe in 'runs-on: ubuntu-24.04' 'runs-on: ubuntu-latest # github-hosted-required: x' \
               "runs-on: \${{ vars.X || 'ubuntu-24.04' }}" '- os: macos-15' '          - windows-latest' \
               "runs-on: \${{ github.event_name == 'pull_request' && 'ubuntu-latest' || 'blacksmith-4vcpu-ubuntu-2404' }}" \
               "LINUX_ARM64_RUNNER: \${{ vars.LINUX_ARM64_RUNNER || 'ubuntu-24.04-arm' }}" \
               "runs-on: \${{ vars.MACOS_RUNNER_BACKGROUND || 'macos-15' }}" 'runs-on: macos-15-intel' 'runs-on: windows-2025'; do
    if ! printf '%s\n' "$probe" | sed -E "s/$fork_branch//g; s/$trusted_list//g" | grep -Eq "$hosted"; then
      echo "FAIL: GitHub-hosted runner guard self-test missed a GitHub-hosted label: $probe"
      exit 1
    fi
  done
  for probe in "runs-on: \${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}" \
               "runs-on: \${{ github.repository_owner != 'manaflow-ai' && 'windows-2025' || 'blacksmith-4vcpu-windows-2025' }}" \
               "runs-on: \${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || contains(fromJSON('[\"ubuntu-24.04\",\"blacksmith-2vcpu-ubuntu-2404\",\"blacksmith-4vcpu-ubuntu-2404\"]'), vars.CI_TRUSTED_RUNNER) && vars.CI_TRUSTED_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}" \
               '- blacksmith-6vcpu-macos-15' 'runs-on: blacksmith-4vcpu-ubuntu-2404-arm' '- warp-macos-15-arm64-6x'; do
    if printf '%s\n' "$probe" | sed -E "s/$fork_branch//g; s/$trusted_list//g" | grep -Eq "$hosted"; then
      echo "FAIL: GitHub-hosted runner guard self-test flagged an allowed runner: $probe"
      exit 1
    fi
  done

  local line file content stripped exception allowed failed=0
  while IFS= read -r line; do
    file="${line%%:*}"
    content="${line#*:*:}"
    [[ "$content" =~ ^[[:space:]]*# ]] && continue
    # Fork-only matrix rows: read only through the fork branch above.
    [[ "$content" =~ (^|[^A-Za-z_])\"?hosted_runner\"?:[[:space:]] ]] && continue
    stripped="$(printf '%s\n' "$content" | sed -E "s/$fork_branch//g; s/$trusted_list//g")"
    printf '%s\n' "$stripped" | grep -Eq "$hosted" || continue
    allowed=0
    for exception in "${exceptions[@]}"; do
      if [[ "$(basename "$file"):$content" == "$exception" ]]; then allowed=1; break; fi
    done
    [[ "$allowed" -eq 1 ]] && continue
    echo "FAIL: GitHub-hosted runner label: ${line#"$ROOT_DIR"/}" | cut -c1-260
    failed=1
  done < <(grep -rnE "(runs-on:|^[[:space:]]+(labels|group):|[[:space:]\"](os|runner|runs_on|runs-on|macos_runner|linux_runner|windows_runner)\"?:[[:space:]]|[A-Za-z_]*RUNNER[A-Za-z_]*:[[:space:]]|^[[:space:]]*-[[:space:]]+[A-Za-z0-9._-]+[[:space:]]*$|^[[:space:]]+default:[[:space:]])" "$ROOT_DIR/.github/workflows")
  # The capability map's manaflow-ai fleet feeds runs-on through resolve-runners.yml.
  local owner_fleet fleet_hits
  owner_fleet="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["owners"]["manaflow-ai"])' "$ROOT_DIR/.github/runners.json")"
  fleet_hits="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); [print(k+" "+v) for k,v in d["fleets"][sys.argv[2]].items()]' "$ROOT_DIR/.github/runners.json" "$owner_fleet" | grep -E "$hosted" || true)"
  if [[ -n "$fleet_hits" ]]; then
    echo "FAIL: .github/runners.json fleet '$owner_fleet' (manaflow-ai) maps a capability to a GitHub-hosted label:"
    echo "$fleet_hits"
    failed=1
  fi
  if [[ "$failed" -ne 0 ]]; then
    echo "      A GitHub billing block must not stop CI. Use a Blacksmith label (behind the"
    echo "      fork branch), a runner variable with a Blacksmith fallback, or the CI_TRUSTED_RUNNER"
    echo "      selector. Add an exception above only for a job that cannot run off GitHub-hosted."
    exit 1
  fi
  echo "PASS: no workflow selects a GitHub-hosted runner outside the fork branch and the listed exceptions"
}

check_no_self_hosted_fleet_runners() {
  # Required jobs route through repository variables. Forbid hardcoded fleet
  # labels so paid-provider fallback remains a configuration change and a
  # physical host label cannot bypass the routing rules. tart-* labels (the
  # retired Tart VM fleet) are refused everywhere, dispatch dropdowns included.
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
  # check_owned_pools_route_through_picker holds the other half. The one
  # exception is test-e2e.yml's dispatch-only runner dropdown, which may offer
  # an owned label exactly: E2E is never a required
  # check, and its runner job hands the label on (e2e_runner_pool.py).
  local owned='glaeda-(aws-)?(xl|std|light)-xcode-[0-9]+([.][0-9]+)*'
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
               '- glaeda-std-xcode-26.6' '- glaeda-aws-std-xcode-26.3' "runs-on: \${{ vars.X || 'glaeda-light-xcode-26.6' }}" 'runs-on: glaeda-xl-xcode-26' \
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
  # pr_runner_pool.py writes for a pull request run or main's full-suite
  # dispatch: it hands owned labels only to same-repository heads (and to a
  # workflow_dispatch on refs/heads/main, which runs main's own code) on a
  # first attempt, and only once CI_PR_POOL_OWNED is 1. ci-macos.yml reads
  # the pick for both through the inputs below. This check keeps that the
  # only way. The picker's
  # runner output feeds exactly the macos_pr_runner output and the rescue
  # marker; macos_pr_runner reaches a job only as a `pr_runner` input written
  # exactly one way, or inside a runs-on branch that a pull_request condition
  # guards. Parsed as YAML, so a block scalar or a second output is seen too.
  local violations violations_file
  violations_file="$(mktemp)"
  python3 - "$ROOT_DIR/.github/workflows" >"$violations_file" <<'PYTHON'
import re
import sys
from pathlib import Path

import yaml

PICKED = "steps.macos-pool.outputs.runner"
RETRY_PICKED = "steps.macos-pool.outputs.retry_runner"
OUTPUT = "needs.changes.outputs.macos_pr_runner"
RETRY_OUTPUT = "needs.changes.outputs.macos_pr_retry_runner"
SHARD_PICKED = "steps.macos-pool.outputs.shard_runner"
SHARD_OUTPUT = "needs.changes.outputs.macos_pr_shard_runner"
ROOT_PICKED = "steps.macos-pool.outputs.root_runner"
ROOT_OUTPUT = "needs.changes.outputs.macos_pr_root_runner"
ADMISSION_PICKED = "steps.macos-pool.outputs.admission_runner"
ADMISSION_OUTPUT = "needs.changes.outputs.macos_pr_admission_runner"
SIDE_PICKED = "steps.macos-pool.outputs.side_runner"
SIDE_OUTPUT = "needs.changes.outputs.macos_pr_side_runner"
LIGHT_SIDE_PICKED = "steps.macos-pool.outputs.light_side_runner"
LIGHT_SIDE_OUTPUT = "needs.changes.outputs.macos_pr_light_side_runner"


def lane_side(key):
    """A side lane's label: the light side label when the picker put this lane there, else the pool's side label."""
    return (f"contains(needs.changes.outputs.macos_pr_light_side_jobs, ' {key} ') && {LIGHT_SIDE_OUTPUT}"
            f" || {SIDE_OUTPUT}")


PASSED = "${{ needs.changes.outputs.macos_pr_runner }}"
# Each input the picked pools reach a reusable workflow through, and its value.
INPUTS = {"pr_runner": PASSED, "pr_retry_runner": "${{ " + RETRY_OUTPUT + " }}",
          "pr_shard_runner": "${{ " + SHARD_OUTPUT + " }}",
          "pr_root_runner": "${{ " + ROOT_OUTPUT + " }}",
          "pr_admission_runner": "${{ " + ADMISSION_OUTPUT + " }}",
          "pr_side_runner": {"remote-daemon": "${{ " + lane_side("remote-daemon") + " }}",
                             "macos": "${{ " + lane_side("swift-package") + " }}"}}
MARKER = ("macos-pool-persistent-${{ github.run_id }}-${{ github.run_attempt }}"
          "-${{ steps.macos-pool.outputs.jobs }}p${{ steps.macos-pool.outputs.placed }}"
          "-${{ steps.macos-pool.outputs.runner }}")
# The runs-on branches that may read the picked pool, each behind its
# pull_request condition; a fork head keeps only a Blacksmith pick.
GUARDED = (
    "github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository"
    " && !contains(fromJSON(needs.changes.outputs.owned_head_repos), github.event.pull_request.head.repo.full_name)"
    " && (startsWith(needs.changes.outputs.macos_pr_runner, 'blacksmith-') && needs.changes.outputs.macos_pr_runner"
    " || 'blacksmith-6vcpu-macos-15')",
    "github.event_name == 'pull_request' && (needs.changes.outputs.macos_pr_runner || vars.MACOS_RUNNER_PR"
    " || 'blacksmith-6vcpu-macos-15')",
    # A side lane: the side label of the pool first, when the picker named one.
    "github.event_name == 'pull_request' && ((" + lane_side("claude-wrapper") + ")"
    " || needs.changes.outputs.macos_pr_runner || vars.MACOS_RUNNER_PR || 'blacksmith-6vcpu-macos-15')",
    # The bot's re-run past attempt 2 on an owned-pool run, or a job the picker did not
    # place on the owned pool: the Blacksmith pool the picker named for it.
    "github.event_name == 'pull_request' && (github.run_attempt > 2 && github.triggering_actor == 'github-actions[bot]' || !contains(needs.changes.outputs.macos_pr_owned_jobs,"
    " ' claude-wrapper ')) && needs.changes.outputs.macos_pr_retry_runner",
    # A trusted manual dispatch (code already in the repository, which
    # pr_runner_pool.py places like a pull request): only the job it placed.
    "github.event_name == 'workflow_dispatch' && github.run_attempt <= 2"
    " && contains(needs.changes.outputs.macos_pr_owned_jobs, ' claude-wrapper ') && (needs.changes.outputs.macos_pr_side_runner"
    " || needs.changes.outputs.macos_pr_runner)",
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
        if SHARD_PICKED in value and not (
                file.name == "ci.yml" and path == ("jobs", "changes", "outputs", "macos_pr_shard_runner")
                and value == "${{ " + SHARD_PICKED + " }}"):
            violations.append(f"{where}: reads the picker's shard runner outside macos_pr_shard_runner")
        if ROOT_PICKED in value and not (
                file.name == "ci.yml" and path == ("jobs", "changes", "outputs", "macos_pr_root_runner")
                and value == "${{ " + ROOT_PICKED + " }}"):
            violations.append(f"{where}: reads the picker's root runner outside macos_pr_root_runner")
        if ADMISSION_PICKED in value and not (
                file.name == "ci.yml" and path == ("jobs", "changes", "outputs", "macos_pr_admission_runner")
                and value == "${{ " + ADMISSION_PICKED + " }}"):
            violations.append(f"{where}: reads the picker's admission runner outside macos_pr_admission_runner")
        if SIDE_PICKED in value and not (
                file.name == "ci.yml" and path == ("jobs", "changes", "outputs", "macos_pr_side_runner")
                and value == "${{ " + SIDE_PICKED + " }}"):
            violations.append(f"{where}: reads the picker's side runner outside macos_pr_side_runner")
        if LIGHT_SIDE_PICKED in value and not (
                file.name == "ci.yml" and path == ("jobs", "changes", "outputs", "macos_pr_light_side_runner")
                and value == "${{ " + LIGHT_SIDE_PICKED + " }}"):
            violations.append(f"{where}: reads the picker's light side runner outside macos_pr_light_side_runner")
        if len(path) >= 3 and path[-2] == "with" and path[-1] in INPUTS:
            expected = INPUTS[path[-1]]
            if isinstance(expected, dict):  # one value per calling job
                expected = expected.get(path[1], "")
            if value != expected or file.name != "ci.yml":
                violations.append(f"{where}: {path[-1]} must be exactly {expected}")
            continue
        if OUTPUT not in value and RETRY_OUTPUT not in value \
                and SHARD_OUTPUT not in value and ROOT_OUTPUT not in value and ADMISSION_OUTPUT not in value \
                and SIDE_OUTPUT not in value and LIGHT_SIDE_OUTPUT not in value:
            continue
        if path[-1:] == ("runs-on",):
            rest = value
            for branch in GUARDED:
                rest = rest.replace(branch, "")
            if OUTPUT not in rest and RETRY_OUTPUT not in rest \
                    and SHARD_OUTPUT not in rest and ROOT_OUTPUT not in rest and ADMISSION_OUTPUT not in rest \
                    and SIDE_OUTPUT not in rest and LIGHT_SIDE_OUTPUT not in rest:
                continue
        violations.append(f"{where}: reads macos_pr_runner outside pr_runner or a pull_request runs-on branch")
print("\n".join(violations))
PYTHON
  violations="$(<"$violations_file")"
  rm -f "$violations_file"
  if [ -n "$violations" ]; then
    echo "FAIL: the picked pull request pool must reach jobs only through pr_runner_pool.py's checked route"
    echo "$violations"
    exit 1
  fi
  echo "PASS: owned pool labels reach jobs only through the pull request pool picker"
}

check_cla_guard_runner

# ci-macos.yml jobs
check_no_github_hosted_runners
check_no_self_hosted_fleet_runners
check_owned_pools_route_through_picker
check_macos_runner "$CI_MACOS_FILE" "macos-compile-admission"
check_macos_runner "$CI_MACOS_FILE" "release-build"
check_release_build_runner_disk_capacity

# build-ghosttykit.yml (routed through the MACOS_RUNNER_BACKGROUND repo var)
check_macos_runner "$GHOSTTYKIT_FILE" "build-ghosttykit"

check_ios_runner_routing

check_xcode_selection
check_release_build_signal
check_release_build_disk_cleanup
check_release_helper_artifact_from_package_lane
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
  local violations violations_file
  violations_file="$(mktemp)"
  python3 - "$ROOT_DIR/.github/workflows" >"$violations_file" <<'PYTHON'
import sys
from pathlib import Path

import yaml

# (workflow file, job id, env key) -> why this site keeps the macos-15 Xcode
# regardless of where the pull-request lane points.
EXEMPT = {
    ("ci-macos.yml", "swift-package-tests", "CMUX_CI_HELPER_XCODE_APP"):
        "same job's SDK 15 release-helper pin",
    ("ci.yml", "changes", "CMUX_CI_XCODE_APP_MACOS_15"):
        "a Linux job; pr_runner_pool.py hands this pin on only to a run it routes to the macOS 15 pool",
    ("seed-derived-data.yml", "decide", "XCODE_APP_MACOS_15"):
        "a Linux job; seed_decide.py fingerprints the macOS 15 pool's seed under the Xcode that pool seeds with",
    ("seed-swiftpm-manifests.yml", "seed", "CMUX_CI_XCODE_APP"):
        "seeds the manifest cache for the Xcode pr_runner_pool.py hands to runs it routes to the macOS 15 pool",
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
  violations="$(<"$violations_file")"
  rm -f "$violations_file"
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
  local mismatches mismatches_file
  mismatches_file="$(mktemp)"
  python3 - "$CI_MACOS_FILE" >"$mismatches_file" <<'PYTHON'
import sys
from pathlib import Path
import yaml


# Compile admission may take the pinned labels of admission-placement (this
# attempt's) or pr_admission_runner (attempt 1's), a JSON array; the env
# restates the first, the root label.
WARM_RUNS_ON = ("fromJSON(needs.admission-placement.outputs.runner)", "fromJSON(inputs.pr_admission_runner)")


def restated(value):
    for pinned in WARM_RUNS_ON:
        value = value.replace(pinned + "[0]", pinned)
    return value


def mismatched_identities(document):
    for job_id, job in document.get("jobs", {}).items():
        runs_on = job.get("runs-on")
        scopes = [("job", job)]
        scopes.extend((f"step {index}", step) for index, step in enumerate(job.get("steps", [])))
        for scope, owner in scopes:
            for key, value in (owner.get("env") or {}).items():
                if isinstance(value, str) and "vars.MACOS_RUNNER" in value and restated(value) != runs_on:
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
  mismatches="$(<"$mismatches_file")"
  rm -f "$mismatches_file"
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
  awk -v e="vars.MACOS_RUNNER_BACKGROUND || 'blacksmith-6vcpu-macos-15'" \
      -v f="github.repository_owner != 'manaflow-ai' && 'macos-15' || " \
      -v g="github.repository_owner != 'manaflow-ai' && 'macos-26' || " '{
    while ((i = index($0, e)) > 0) $0 = substr($0, 1, i - 1) substr($0, i + length(e))
    while ((i = index($0, f)) > 0) $0 = substr($0, 1, i - 1) substr($0, i + length(f))
    while ((i = index($0, g)) > 0) $0 = substr($0, 1, i - 1) substr($0, i + length(g))
    print
  }'
}

check_background_macos_lane() {
  # MACOS_RUNNER_BACKGROUND is the non-urgent macOS lane (dispatch-only,
  # post-merge, on-demand packaging). Its in-workflow fallback is Blacksmith
  # macos-15, behind the fork branch: a GitHub billing block must not stop it
  # (check_no_github_hosted_runners). An admin can repoint the whole lane with
  # one variable edit. GitHub-hosted macOS labels appear only in the fork
  # branch and the exact compatibility-leg exceptions below.
  local lane_expr="vars.MACOS_RUNNER_BACKGROUND || 'blacksmith-6vcpu-macos-15'"
  local hosted_mac='(^|[^A-Za-z0-9_-])macos-(latest|[0-9]+)(-(intel|large|xlarge|arm64))?([^A-Za-z0-9_-]|$)'
  # The Intel compatibility leg needs a hosted image that no paid provider
  # offers. Exact lines only. macos-14 is retired (#17068).
  local -a hosted_exceptions=(
    # Compare-only x86_64 run-time check of the Linux-built Mac binaries.
    "cmux-tui-artifacts.yml:    runs-on: macos-15-intel # github-hosted-required: x86_64 run-time check; Blacksmith has no Intel Mac image"
    "macos-cross-parity.yml:    runs-on: macos-15-intel # github-hosted-required: x86_64 run-time check; Blacksmith has no Intel Mac image"
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
      echo "FAIL: $(basename "$file") references vars.MACOS_RUNNER_BACKGROUND without the fallback || 'blacksmith-6vcpu-macos-15'"
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
  echo "PASS: the MACOS_RUNNER_BACKGROUND lane falls back to Blacksmith on non-blocking workflows; hosted macOS only in fork branches and compat legs"
}

check_dmg_signing_uses_build_keychain
check_create_dmg_uses_run_local_npm_prefix
check_gui_smoke_unsupported_launch_handling
check_no_ci_xctest_skips
check_no_ci_swift_package_skips
check_web_db_behavior_tests
check_web_test_runner_behavior
check_pr_macos_workflows_cancel_superseded_runs
check_ios_only_tests_stay_under_ios
check_no_paid_overflow_fallbacks
check_macos_runner_identity_env_tracks_routing
check_macos_xcode_pin_tracks_pull_request_lane
check_background_macos_lane
