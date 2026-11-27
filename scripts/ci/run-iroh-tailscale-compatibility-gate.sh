#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
result_root="${CMUX_TAILSCALE_COMPAT_RESULT_ROOT:-${RUNNER_TEMP:-/tmp}/cmux-iroh-tailscale-compatibility}"
source_packages="${CMUX_TAILSCALE_COMPAT_SOURCE_PACKAGES:-$repo_root/.ci-source-packages}"
swift_scratch_root="$result_root/swift-build"

mkdir -p "$result_root" "$source_packages"
rm -rf "$swift_scratch_root"
rm -f "$result_root"/*.log

# The Mac half of this gate (cmuxTests/IrohTailscaleVersionSkewMacGateTests,
# run through the deleted cmux-unit scheme) went with the legacy app target.
# The iOS package halves below still pin the released-iOS routing contract.
# The CmuxMobileShell half went with the legacy iOS app (ios/CmuxiOS replaced it).

run_package_gate() {
  local package_path="$1"
  local filter="$2"
  local expected_count="$3"
  shift 3
  local scratch_path="$swift_scratch_root/$(basename "$package_path")"

  local list_output
  list_output="$(
    swift test list \
      --package-path "$repo_root/$package_path" \
      --scratch-path "$scratch_path"
  )"
  local expected_test
  for expected_test in "$@"; do
    if ! grep -Fqx "$expected_test" <<<"$list_output"; then
      echo "Missing compatibility-gate test: $expected_test" >&2
      exit 1
    fi
  done

  local output_file="$result_root/$(basename "$package_path").log"
  swift test \
    --package-path "$repo_root/$package_path" \
    --scratch-path "$scratch_path" \
    --filter "$filter" 2>&1 | tee "$output_file"

  if ! grep -Eq \
    "Test run with ${expected_count} tests? in [0-9]+ suites? passed" \
    "$output_file"; then
    echo "Expected exactly $expected_count passing tests from $package_path" >&2
    exit 1
  fi
}

run_package_gate \
  Packages/iOS/CmuxMobileRPC \
  'MobileCoreRPCClientTests/(admittedIrohRequestCarriesNoStackOrAttachCredential|hostStatusProbeNeverSendsStackTokenOnUntrustedRoute)' \
  2 \
  'CmuxMobileRPCTests.MobileCoreRPCClientTests/admittedIrohRequestCarriesNoStackOrAttachCredential()' \
  'CmuxMobileRPCTests.MobileCoreRPCClientTests/hostStatusProbeNeverSendsStackTokenOnUntrustedRoute()'

run_package_gate \
  Packages/iOS/CmuxMobileShellModel \
  'MobileShellRouteAuthPolicyTests/allowsStackAuthOnlyForLoopbackRoutes' \
  1 \
  'CmuxMobileShellModelTests.MobileShellRouteAuthPolicyTests/allowsStackAuthOnlyForLoopbackRoutes()'

echo "Iroh/Tailscale version-skew compatibility gate passed"
