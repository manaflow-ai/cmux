#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
result_root="${CMUX_TAILSCALE_COMPAT_RESULT_ROOT:-${RUNNER_TEMP:-/tmp}/cmux-iroh-tailscale-compatibility}"
derived_data="$result_root/app-host-derived"
result_bundle="$result_root/app-host.xcresult"
source_packages="${CMUX_TAILSCALE_COMPAT_SOURCE_PACKAGES:-$repo_root/.ci-source-packages}"
swift_scratch_root="$result_root/swift-build"

mkdir -p "$result_root" "$source_packages"
rm -rf "$result_bundle"
rm -rf "$swift_scratch_root"
rm -f "$result_root"/*.log

# IrohTailscaleVersionSkewMacGateTests must execute exactly this many tests.
# It was 6 until IROH v2 (#12326) retired the Mac's legacy TCP listener and its
# Stack-bearer authorization context, `legacyPrivateNetworkListener`. #12754
# re-retired them after a merge brought them back. Two tests guarded only that
# surface and were retired rather than rewritten:
#   testReleasedIOSWireFrameRemainsAcceptedByLegacyTCPAuthorization
#   testLegacyCompatibilityPolicyCannotBecomeIrohAdmission
# Shipped iOS builds are now served by the `cmux/mobile/1` dialect on the v2
# endpoint, behind Iroh admission. The two Stable listener tests cover that path.
# See https://github.com/manaflow-ai/cmux/issues/13683.
app_host_expected_count=4

run_app_host_gate() {
  rm -rf "$result_bundle"
  (
    cd "$repo_root"
    scripts/ci/xcodebuild_noninteractive.py \
      xcodebuild \
      -project cmux.xcodeproj \
      -scheme cmux-unit \
      -configuration Debug \
      -destination "platform=macOS" \
      -derivedDataPath "$derived_data" \
      -clonedSourcePackagesDirPath "$source_packages" \
      -resultBundlePath "$result_bundle" \
      COMPILER_INDEX_STORE_ENABLE=NO \
      -only-testing:cmuxTests/IrohTailscaleVersionSkewMacGateTests \
      test
  )

  python3 - "$result_bundle" "$app_host_expected_count" <<'PY'
import json
import subprocess
import sys

result_bundle = sys.argv[1]
summary = json.loads(
    subprocess.check_output(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            result_bundle,
            "--compact",
        ]
    )
)
expected = int(sys.argv[2])
observed = int(summary.get("totalTestCount", 0))
passed = int(summary.get("passedTests", 0))
failed = int(summary.get("failedTests", 0))
if summary.get("result") != "Passed" or observed != expected or passed != expected or failed:
    raise SystemExit(
        f"Mac compatibility gate did not execute exactly {expected} passing tests: "
        f"result={summary.get('result')} total={observed} passed={passed} failed={failed}"
    )
print(f"Mac compatibility gate: {expected}/{expected} passed")
PY
}

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

run_app_host_gate

run_package_gate \
  Packages/iOS/CmuxMobileShell \
  'ReconnectRouteSelectionTests/(legacyMacWithoutIrohFailsClosedInsteadOfSendingBearerOverTCP|legacySavedMacWithoutPublishedIrohIsRetainedAndRequestsMacUpdate|preIrohPairingContinuesOverItsExactTailscaleRouteAfterIOSUpgrade|rejectedIrohReconnectNeverDowngradesToRawTailscale|storedReconnectPinsIrohAndExcludesRawFallbacks|switchToLegacySavedMacUpgradesFromRegistryWithoutRescan)' \
  6 \
  'CmuxMobileShellTests.ReconnectRouteSelectionTests/legacyMacWithoutIrohFailsClosedInsteadOfSendingBearerOverTCP()' \
  'CmuxMobileShellTests.ReconnectRouteSelectionTests/legacySavedMacWithoutPublishedIrohIsRetainedAndRequestsMacUpdate()' \
  'CmuxMobileShellTests.ReconnectRouteSelectionTests/preIrohPairingContinuesOverItsExactTailscaleRouteAfterIOSUpgrade()' \
  'CmuxMobileShellTests.ReconnectRouteSelectionTests/rejectedIrohReconnectNeverDowngradesToRawTailscale()' \
  'CmuxMobileShellTests.ReconnectRouteSelectionTests/storedReconnectPinsIrohAndExcludesRawFallbacks()' \
  'CmuxMobileShellTests.ReconnectRouteSelectionTests/switchToLegacySavedMacUpgradesFromRegistryWithoutRescan()'

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
