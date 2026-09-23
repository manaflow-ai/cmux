#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CI_FILE="$ROOT_DIR/.github/workflows/ci-macos.yml"
RELEASE_FILE="$ROOT_DIR/.github/workflows/release.yml"

# nightly.yml is intentionally not covered here. It has its own helper-build
# model and guards via test_ci_nightly_xcode_selection.sh plus
# test_nightly_universal_build.sh. This lane guards the release artifact-download
# model and the CI package-lane helper handoff model.

job_section() {
  local file="$1" job="$2"
  awk -v job="$job" '
    $0 ~ "^  "job":" { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { exit }
    in_job { print }
  ' "$file"
}

require_job_contains() {
  local file="$1" job="$2" needle="$3" message="$4"
  local section
  section="$(job_section "$file" "$job")"
  if [[ "$section" != *"$needle"* ]]; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

require_job_contains \
  "$RELEASE_FILE" \
  "build-ghostty-cli-helper" \
  'runs-on: ${{ vars.CI_PAID_MACOS_OVERFLOW == '\''1'\'' && vars.MACOS_RUNNER_15 || '\''blacksmith-6vcpu-macos-15'\'' }}' \
  "release must build the real Ghostty CLI helper on macOS 15"

require_job_contains \
  "$RELEASE_FILE" \
  "build-sign-notarize" \
  'runs-on: ${{ vars.MACOS_RUNNER_26 || '\''blacksmith-6vcpu-macos-26'\'' }}' \
  "release must sign+notarize on the macOS 26 runner variable after importing the Developer ID intermediate chain"

require_job_contains \
  "$CI_FILE" \
  "release-build" \
  'runs-on: ${{ vars.CI_PAID_MACOS_OVERFLOW == '\''1'\'' && vars.MACOS_RUNNER_26_RELEASE || '\''blacksmith-6vcpu-macos-26'\'' }}' \
  "CI release-build must compile the app on macOS 26 using the release-specific runner variable"

for workflow in "$CI_FILE" "$RELEASE_FILE"; do
  if ! grep -Fq "CMUX_SKIP_ZIG_BUILD=1 xcodebuild" "$workflow"; then
    echo "FAIL: $(basename "$workflow") must skip the in-build Zig helper on macOS 26" >&2
    exit 1
  fi

  if ! grep -Fq "./scripts/install-prebuilt-ghostty-cli-helper.sh" "$workflow"; then
    echo "FAIL: $(basename "$workflow") must install the prebuilt Ghostty CLI helper into the app" >&2
    exit 1
  fi

  if ! grep -Fq '[[ "$SDK_VERSION" == 26.* ]]' "$workflow"; then
    echo "FAIL: $(basename "$workflow") must verify the app binary was built with a macOS 26 SDK" >&2
    exit 1
  fi
done

if ! grep -Fq "actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131 # v7.0.0" "$RELEASE_FILE"; then
  echo "FAIL: release.yml must download the macOS 15-built helper artifact" >&2
  exit 1
fi

swift_package_section="$(job_section "$CI_FILE" "swift-package-tests")"
# Every event, pull requests included: this job builds the Release Ghostty CLI
# helper against an SDK 15 Xcode, which only the macos-15 image carries, so it
# must not follow MACOS_RUNNER_PR onto whatever pool that lane points at.
if [[ "$swift_package_section" != *'runs-on: ${{ vars.CI_PAID_MACOS_OVERFLOW == '\''1'\'' && vars.MACOS_RUNNER_DUAL_XCODE || '\''blacksmith-6vcpu-macos-15'\'' }}'* ]]; then
  echo "FAIL: CI swift-package-tests must use the dual-Xcode runner lane on every event" >&2
  exit 1
fi

# Comments are stripped first: the job carries a comment naming MACOS_RUNNER_PR
# to explain why it does not use it, and that prose is not a routing decision.
swift_package_directives="$(printf '%s\n' "$swift_package_section" | sed 's/[[:space:]]*#.*$//')"
if [[ "$swift_package_directives" == *MACOS_RUNNER_PR* ]]; then
  echo "FAIL: CI swift-package-tests must not resolve through MACOS_RUNNER_PR" >&2
  echo "      The pull-request lane may point at a macos-26 pool, which has no SDK 15 Xcode." >&2
  exit 1
fi

if [[ "$swift_package_section" != *"timeout-minutes: 40"* ]]; then
  echo "FAIL: CI swift-package-tests must have enough timeout budget for helper build plus package tests" >&2
  exit 1
fi

if [[ "$swift_package_section" != *"CMUX_CI_HELPER_XCODE_APP"* ]]; then
  echo "FAIL: CI swift-package-tests must use a helper-specific Xcode pin" >&2
  exit 1
fi

if [[ "$swift_package_section" == *"/Applications/Xcode_16.4.app"* ]]; then
  echo "FAIL: CI swift-package-tests must scan for a macOS 15 SDK when the helper Xcode override is unset" >&2
  exit 1
fi

if [[ "$swift_package_section" != *'./scripts/build-ghostty-cli-helper.sh "$@" --output ghostty-cli-helper/ghostty'* ]]; then
  echo "FAIL: CI swift-package-tests must build the architecture-selected Ghostty CLI helper on the macOS 15 lane" >&2
  exit 1
fi

if [[ "$swift_package_section" != *"actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1"* ]]; then
  echo "FAIL: CI swift-package-tests must upload the macOS 15-built Ghostty helper artifact" >&2
  exit 1
fi

swift_package_before_xcode="${swift_package_section%%- name: Select Xcode*}"
if [[ "$swift_package_before_xcode" != *"CMUX_CI_REQUIRED_MACOS_SDK_MAJOR=15"* ]]; then
  echo "FAIL: CI swift-package-tests must require a macOS 15 SDK for the helper build" >&2
  exit 1
fi

if [[ "$swift_package_before_xcode" != *'./scripts/build-ghostty-cli-helper.sh "$@" --output ghostty-cli-helper/ghostty'* ]]; then
  echo "FAIL: CI swift-package-tests must build the Ghostty helper before selecting the Xcode 26 SDK" >&2
  exit 1
fi

if [[ "$swift_package_before_xcode" != *"actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1"* ]]; then
  echo "FAIL: CI swift-package-tests must upload the Ghostty helper before selecting the Xcode 26 SDK" >&2
  exit 1
fi

if [[ "$swift_package_section" != *'[[ "$HELPER_SDK_VERSION" == 15.* ]]'* ]]; then
  echo "FAIL: CI swift-package-tests must validate the uploaded Ghostty helper was built with a macOS 15 SDK" >&2
  exit 1
fi

release_build_section="$(job_section "$CI_FILE" "release-build")"
if [[ "$release_build_section" != *"actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131 # v7.0.0"* ]]; then
  echo "FAIL: CI release-build must download the macOS 15-built Ghostty helper artifact" >&2
  exit 1
fi

if [[ "$release_build_section" != *"- swift-package-tests"* ]]; then
  echo "FAIL: CI release-build must wait for the helper-producing swift-package-tests lane" >&2
  exit 1
fi

if [[ "$release_build_section" == *"./scripts/build-ghostty-cli-helper.sh"* ]]; then
  echo "FAIL: CI release-build must not build the Ghostty helper on macOS 26" >&2
  exit 1
fi

if grep -Fq "release-ghostty-cli-helper:" "$CI_FILE"; then
  echo "FAIL: CI must not define a separate release-ghostty-cli-helper job" >&2
  exit 1
fi

echo "PASS: release uses artifact helper handoff; CI release-build downloads the helper from the existing macOS 15 package lane"
