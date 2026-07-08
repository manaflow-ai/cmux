#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/385.
# Ensures paid CI jobs use a paid macOS runner (Blacksmith or WarpBuild, routed
# through the MACOS_RUNNER_15 / MACOS_RUNNER_26 repo variables), never a free
# GitHub-hosted runner. Flip Blacksmith<->Warp by editing those repo variables;
# see docs/ci-runners.md.
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

check_release_build_runner_disk_capacity() {
  if ! awk '
    /^  release-build:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && /runs-on:/ && /vars\.MACOS_RUNNER_26_RELEASE/ && /blacksmith-6vcpu-macos-26/ { saw_release_runner=1 }
    END { exit !saw_release_runner }
  ' "$CI_FILE"; then
    echo "FAIL: release-build must use the release-specific macOS 26 runner var with a cloud (Blacksmith) fallback for disk-heavy universal builds"
    exit 1
  fi

  echo "PASS: release-build uses release-specific macOS 26 runner fallback"
}

check_build_lag_deriveddata_cache_path() {
  if ! awk '
    /^  tests-build-and-lag:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }

    in_job && /- name: Prepare isolated DerivedData/ { in_prepare=1; next }
    in_prepare && /^[[:space:]]*- name:/ { in_prepare=0 }
    in_prepare && /DERIVED_DATA_PATH="\$RUNNER_TEMP\/cmux-deriveddata-tests-build-and-lag"/ { saw_prepare_path=1 }
    in_prepare && /GITHUB_RUN_ID|GITHUB_RUN_ATTEMPT/ { saw_dynamic_prepare_path=1 }

    in_job && /- name: Cache DerivedData/ { in_cache=1; after_cache=1; next }
    in_cache && /^[[:space:]]*- name:/ { in_cache=0 }
    in_cache && /path:[[:space:]]*\$\{\{ runner\.temp \}\}\/cmux-deriveddata-tests-build-and-lag/ { saw_cache_path=1 }
    in_cache && /Library\/Developer\/Xcode\/DerivedData/ { saw_home_cache_path=1 }

    in_job && after_cache && /rm -rf "\$CMUX_DERIVED_DATA_PATH"/ { saw_post_cache_delete=1 }

    END {
      exit !(saw_prepare_path && saw_cache_path && !saw_dynamic_prepare_path && !saw_home_cache_path && !saw_post_cache_delete)
    }
  ' "$CI_FILE"; then
    echo "FAIL: tests-build-and-lag DerivedData cache must restore into the stable RUNNER_TEMP path xcodebuild uses, and must not delete that path after restore"
    exit 1
  fi

  echo "PASS: tests-build-and-lag DerivedData cache path matches xcodebuild path"
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

  if ! grep -Fq "startsWith((!inputs.runner || inputs.runner == 'auto') && (vars.MACOS_RUNNER_15 || 'blacksmith-6vcpu-macos-15') || inputs.runner, 'depot-macos-')" "$E2E_FILE"; then
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
  ' "$CI_FILE"; then
    echo "FAIL: release-build cleanup must stay limited to job-owned workspace paths"
    exit 1
  fi

  echo "PASS: release-build reclaims runner disk before large cache restores"
}

check_release_helper_artifact_from_package_lane() {
  if ! awk '
    /^  swift-package-tests:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }

    in_job && /- name: Select Xcode/ { saw_select=1; after_select=1; next }
    in_job && /- name: Build universal Ghostty CLI helper/ {
      saw_build_step=1
      if (after_select) {
        saw_build_after_select=1
      }
      next
    }
    in_job && /\.\/scripts\/build-ghostty-cli-helper\.sh --universal --output ghostty-cli-helper\/ghostty/ { saw_build=1 }
    in_job && /lipo ghostty-cli-helper\/ghostty -verify_arch arm64 x86_64/ { saw_lipo=1 }
    in_job && /- name: Upload universal Ghostty CLI helper/ {
      saw_upload_step=1
      if (after_select) {
        saw_upload_after_select=1
      }
      next
    }
    in_job && /uses: actions\/upload-artifact@/ { saw_upload=1 }
    in_job && /name:[[:space:]]*cmux-ghostty-cli-helper/ { saw_artifact_name=1 }

    END {
      exit !(saw_build_step && saw_build && saw_lipo && saw_upload_step && saw_upload && saw_artifact_name && saw_select && !saw_build_after_select && !saw_upload_after_select)
    }
  ' "$CI_FILE"; then
    echo "FAIL: swift-package-tests must build and upload the universal Ghostty helper before selecting Xcode 26"
    exit 1
  fi

  if ! awk '
    /^  release-build:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }

    in_job && /- swift-package-tests/ { saw_need=1 }
    in_job && /- name: Download universal Ghostty CLI helper/ { saw_download_step=1; next }
    in_job && /uses: actions\/download-artifact@/ { saw_download=1 }
    in_job && /name:[[:space:]]*cmux-ghostty-cli-helper/ { saw_artifact_name=1 }
    in_job && /- name: Install universal Ghostty CLI helper/ { saw_install_step=1; next }
    in_job && /\.\/scripts\/install-prebuilt-ghostty-cli-helper\.sh/ { saw_install=1 }

    END {
      exit !(saw_need && saw_download_step && saw_download && saw_artifact_name && saw_install_step && saw_install)
    }
  ' "$CI_FILE"; then
    echo "FAIL: release-build must depend on swift-package-tests, download the helper artifact, and install it into the app"
    exit 1
  fi

  if grep -Fq "release-ghostty-cli-helper:" "$CI_FILE"; then
    echo "FAIL: CI must not queue a separate release-ghostty-cli-helper job"
    exit 1
  fi

  echo "PASS: release-build consumes the Ghostty helper artifact built by swift-package-tests"
}

check_runtime_regressions_collapsed() {
  if grep -Fq "ui-regressions:" "$CI_FILE"; then
    echo "FAIL: CI must not queue a separate ui-regressions job"
    exit 1
  fi

  if ! awk '
    /^  tests-build-and-lag:/ { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }

    in_job && /build-for-testing/ { saw_build_for_testing=1 }
    in_job && /scripts\/ci\/run-display-ui-regressions\.sh/ { saw_ui_script=1 }
    in_job && /timeout-minutes:[[:space:]]*75/ { saw_timeout=1 }

    END { exit !(saw_build_for_testing && saw_ui_script && saw_timeout) }
  ' "$CI_FILE"; then
    echo "FAIL: tests-build-and-lag must build once for testing and run the display UI regressions from that DerivedData"
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
  for file in "$ROOT_DIR/.github/workflows/nightly.yml" "$ROOT_DIR/.github/workflows/release.yml"; do
    if grep -Fq -- '--identity="$APPLE_SIGNING_IDENTITY"' "$file"; then
      echo "FAIL: $(basename "$file") must not let create-dmg codesign outside build.keychain"
      exit 1
    fi

    if ! awk '
      /create-dmg[[:space:]]*\\/ { in_dmg=1; next }
      in_dmg && /--no-code-sign[[:space:]]*\\/ { saw_no_code_sign=1 }
      in_dmg && /^[[:space:]]*$/ { in_dmg=0 }
      END { exit !saw_no_code_sign }
    ' "$file"; then
      echo "FAIL: $(basename "$file") must disable create-dmg implicit code signing"
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

  if ! awk '
    /scripts\/smoke-launch-macos-app\.sh/ && /CMUX_SMOKE_ALLOW_UNSUPPORTED_GUI=1/ { saw_launchservices=1 }
    /scripts\/smoke-launch-macos-app\.sh/ && /CMUX_SMOKE_DIRECT_EXEC=1/ { saw_direct_exec=1 }
    END { exit !(saw_launchservices && saw_direct_exec) }
  ' "$ROOT_DIR/.github/workflows/nightly.yml"; then
    echo "FAIL: nightly signing smoke must run direct exec after unsupported-GUI LaunchServices smoke"
    exit 1
  fi

  for file in "$ROOT_DIR/.github/workflows/nightly.yml" "$ROOT_DIR/.github/workflows/release.yml"; do
    if ! grep -Fq 'scripts/smoke-launch-macos-app.sh' "$file"; then
      echo "FAIL: $(basename "$file") signing workflow must run launch smoke"
      exit 1
    fi
  done

  echo "PASS: signing smoke handles unsupported GUI launch and release direct exec explicitly"
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

check_no_bare_github_hosted_runners() {
  # Every job must route its runner through a repo variable (LINUX_RUNNER,
  # MACOS_RUNNER_*) so the Blacksmith<->Warp / Blacksmith<->macos-26 overflow
  # switch is a single repo-variable flip with no PR. A bare GitHub-hosted
  # label (ubuntu-*, macos-NN) cannot be redirected, so it is forbidden.
  # Bare paid-provider labels (blacksmith-*, warp-*, depot-*) stay allowed for
  # deliberate single-runner pins such as the testmanagerd-wedged
  # `app-host-unit-tests` job.
  local hits
  hits="$(grep -rnE "runs-on:[[:space:]]*(ubuntu-[a-z0-9.]+|macos-[a-z0-9]+)[[:space:]]*$" "$ROOT_DIR/.github/workflows" || true)"
  if [[ -n "$hits" ]]; then
    echo "FAIL: these jobs use a bare GitHub-hosted runner; route them through vars.LINUX_RUNNER / vars.MACOS_RUNNER_IOS so Blacksmith<->overflow stays a repo-variable flip:"
    echo "$hits"
    exit 1
  fi
  echo "PASS: no workflow pins a bare GitHub-hosted runner; all route through runner repo variables"
}

check_no_self_hosted_fleet_runners() {
  # We do NOT use our self-hosted mac fleet for required CI. Those runners carry
  # custom labels that collide with cloud labels, and GitHub PREFERS a matching
  # self-hosted runner, so any required job that names such a label can land on
  # a mini that cannot foreground a GUI app. Forbid every real fleet label (see
  # the runner registry) and the bare self-hosted/macOS/ARM64 combos in
  # runner-selection positions, so required jobs only ever use cloud runners.
  # Allowed macOS labels (none carried by any fleet runner):
  #   blacksmith-6vcpu-macos-{15,26,latest}, warp-macos-15-arm64-6x,
  #   depot-macos-{latest,14}.
  # NOTE: reload-build.yml is the dev-build offload path (workflow_dispatch,
  # not required CI) and intentionally targets the fleet via a free-form input;
  # this guard only inspects runner-selection lines, not its input description.
  local fleet='macos-26|warp-macos-26-arm64-6x|cmux-aws-macos|cmux-macos|cmux-local-macos|macfleet|(^|[^a-z0-9-])mac4([^a-z0-9]|$)|(^|[^a-z0-9-])mac-mini([^a-z0-9]|$)|slot-[0-9]|xcode-[0-9]+-[0-9]|(^|[^a-z0-9-])cmux([^a-z0-9-]|$)'
  local allowed='blacksmith-6vcpu-macos-(15|26|latest)|warp-macos-15-arm64-6x|depot-macos-(latest|14)'

  # Bare self-hosted/macOS/ARM64 targeting (inline array or multi-line list).
  # Case-sensitive: GitHub's auto labels are `macOS`/`ARM64`, distinct from the
  # lowercase `macos`/`arm64` inside cloud labels like warp-macos-15-arm64-6x.
  local selfhosted='(^|[^A-Za-z0-9_-])(self-hosted|macOS|ARM64)([^A-Za-z0-9_-]|$)'
  local forbidden="${fleet}|${selfhosted}"

  # Self-test the matcher so a future edit cannot silently narrow it: every
  # known fleet/self-hosted label must be caught, every allowed cloud label
  # must pass. Probes are raw YAML values (no path:lineno: prefix).
  local probe
  for probe in 'runs-on: macfleet' '- mac4' '- mac-mini' '- slot-3' '- xcode-26-3' '- cmux' \
               "runs-on: \${{ vars.X || 'macos-26' }}" '- warp-macos-26-arm64-6x' \
               '- cmux-aws-macos-15' '- cmux-macos-26' '- self-hosted' '- macOS' '- ARM64' \
               'runs-on: [self-hosted, macOS, ARM64]'; do
    if ! printf '%s\n' "$probe" | grep -Eq "($forbidden)"; then
      echo "FAIL: fleet-runner guard self-test missed a known fleet/self-hosted label: $probe"
      exit 1
    fi
  done
  for probe in "runs-on: \${{ vars.X || 'blacksmith-6vcpu-macos-26' }}" \
               "runs-on: \${{ vars.MACOS_RUNNER_15 || 'warp-macos-15-arm64-6x' }}" \
               '- warp-macos-15-arm64-6x' '- depot-macos-latest' '- blacksmith-6vcpu-macos-15' \
               '- blacksmith-4vcpu-ubuntu-2404'; do
    if printf '%s\n' "$probe" | grep -E "($forbidden)" | grep -Eqv "($allowed)"; then
      echo "FAIL: fleet-runner guard self-test false-positived a cloud label: $probe"
      exit 1
    fi
  done

  local hits="" line content
  # Inspect runner-selection lines only: runs-on:, matrix `os:`, and scalar list
  # items (`  - <label>`, which covers dispatch runner dropdowns and multi-line
  # `runs-on:` arrays). `- name:` / `- uses:` step entries have a colon and are
  # excluded. grep matches against file CONTENT; strip the `path:lineno:` prefix
  # before matching the value so the checkout path (which contains "cmux") can
  # never match the bare `cmux` label.
  while IFS= read -r line; do
    content="${line#*:*:}"
    printf '%s\n' "$content" | grep -Eq "($forbidden)" || continue
    printf '%s\n' "$content" | grep -Eq "($allowed)" && continue
    hits+="$line"$'\n'
  done < <(grep -rnE "(runs-on:|[[:space:]]os:[[:space:]]|^[[:space:]]*-[[:space:]]+[A-Za-z0-9._-]+[[:space:]]*$)" "$ROOT_DIR/.github/workflows")
  if [[ -n "$hits" ]]; then
    echo "FAIL: workflow references a self-hosted mac fleet label or bare self-hosted runner in a runner-selection position."
    echo "      Use a cloud label so required jobs never land on a mini that can't foreground a GUI app:"
    echo "      blacksmith-6vcpu-macos-{15,26,latest} / warp-macos-15-arm64-6x / depot-macos-{latest,14}."
    echo "$hits"
    exit 1
  fi
  echo "PASS: no workflow can route a required job to a self-hosted mac fleet runner (cloud only)"
}

# ci.yml jobs
check_no_bare_github_hosted_runners
check_no_self_hosted_fleet_runners
check_macos_runner "$CI_FILE" "app-host-unit-tests"
check_macos_runner "$CI_FILE" "tests-build-and-lag"
check_macos_runner "$CI_FILE" "release-build"
check_release_build_runner_disk_capacity
check_display_runner_identity_guard "$CI_FILE" "tests-build-and-lag"
check_build_lag_deriveddata_cache_path

# build-ghosttykit.yml
check_macos_runner "$GHOSTTYKIT_FILE" "build-ghosttykit"

# ci-macos-compat.yml (matrix.os routed through the MACOS_RUNNER_* repo vars)
check_macos_runner "$COMPAT_FILE" "compat-tests"

# test-e2e.yml is manual, so keep the Depot GUI runner choices but cancel
# duplicate queued runs for the same ref/filter/runner.
check_e2e_runner_fallbacks

check_xcode_selection
check_release_build_signal
check_release_build_disk_cleanup
check_release_helper_artifact_from_package_lane
check_runtime_regressions_collapsed
check_signing_intermediate_imports
check_signing_intermediate_helper_behavior
check_sentry_cli_install_portability
check_sentry_cli_helper_behavior
check_dmg_signing_uses_build_keychain
check_create_dmg_uses_run_local_npm_prefix
check_gui_smoke_unsupported_launch_handling
check_no_ci_xctest_skips
check_no_ci_swift_package_skips
check_web_db_behavior_tests
check_tmux_terminal_nightly_isolation
