#!/bin/bash
# Scheduled, isolated iOS package tests. This does not verify the cmux app UI.
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != "true" || -z "${RUNNER_TEMP:-}" ]]; then
  echo "Run this through the Remote connection package tests workflow." >&2
  exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
evidence="$RUNNER_TEMP/cmux-remote-connections-evidence"
mkdir -p "$evidence"
git -C "$root" rev-parse HEAD > "$evidence/source-sha.txt"
xcodebuild -version > "$evidence/xcode-version.txt"
xcrun simctl list runtimes -j > "$evidence/runtimes.json"

runtime="$(python3 - "$evidence/runtimes.json" <<'PY'
import json, sys
runtimes = [
    row for row in json.load(open(sys.argv[1]))["runtimes"]
    if row.get("isAvailable") and row.get("identifier", "").startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
]
if not runtimes:
    sys.exit("No installed iOS runtime; this job does not allocate another machine.")
runtime = max(runtimes, key=lambda row: tuple(int(v) for v in row["version"].split(".")))
print(runtime["identifier"])
PY
)"
# Xcode 26's iPhone 17 Pro fixture, isolated to this workflow run.
simulator_id="$(xcrun simctl create "cmux-remote-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"   com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$runtime")"
printf '%s\n' "$simulator_id" > "$evidence/simulator-udid.txt"

cleanup() {
  xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
  xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT

xcrun simctl boot "$simulator_id"
xcrun simctl bootstatus "$simulator_id" -b
cd "$root"
xcodebuild test \
  -workspace ios/RemoteConnectionsTests.xcworkspace \
  -scheme CmuxRemoteConnections \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$RUNNER_TEMP/cmux-remote-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}" \
  -resultBundlePath "$evidence/RemoteConnections.xcresult" \
  -parallel-testing-enabled NO \
  CODE_SIGN_ENTITLEMENTS="$root/ios/RemoteConnectionsTests/RemoteConnectionsTests.entitlements" \
  | tee "$evidence/ios-tests.log"

xcrun xcresulttool get test-results summary   --path "$evidence/RemoteConnections.xcresult" > "$evidence/test-summary.json"
xcrun xcresulttool get test-results tests \
  --path "$evidence/RemoteConnections.xcresult" > "$evidence/test-identifiers.json"
python3 - "$evidence/test-summary.json" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1]))
total = summary.get("totalTestCount", 0)
failed = summary.get("failedTests", 0)
passed = summary.get("passedTests", 0)
if not isinstance(total, int) or total <= 0 or failed != 0 or passed <= 0:
    sys.exit("iOS test result does not prove a nonempty passing test run.")
print(f"iOS package: {passed}/{total} passed; native UI/product E2E remains separate.")
PY
python3 - "$evidence/test-identifiers.json" <<'PY'
import json, sys

expected = {
    "MobileRemoteKeychainNativeIntegrationTests.signedDataProtectionKeychainSupportsCrudWithoutPrompt",
    "MobileRemoteKeychainNativeIntegrationTests.signedDataProtectionKeychainKeepsScopesIsolated",
}
payload = json.load(open(sys.argv[1]))
observed = []

def walk(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key in {"identifier", "testIdentifier", "name", "testName"} and isinstance(child, str):
                observed.append(child)
            walk(child)
    elif isinstance(value, list):
        for child in value:
            walk(child)

walk(payload)
missing = sorted(item for item in expected if not any(item in value for value in observed))
if missing:
    sys.exit("iOS result omitted required native Keychain tests: " + ", ".join(missing))
print("iOS native Keychain tests: both signed integration identifiers executed.")
PY
