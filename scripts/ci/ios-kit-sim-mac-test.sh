#!/usr/bin/env bash
# The CmuxMobileKit iOS simulator tests on this Mac (cmux-next-ios-kit.yml's simulator step and its Mac fallback after
# a fleet pool run with no verdict). Run from cmux-next-ios/CmuxMobileKit; writes udid= to $GITHUB_OUTPUT.
set -euo pipefail
udid="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
found = sorted(
    (runtime, device["udid"])
    for runtime, items in devices.items()
    if ".SimRuntime.iOS-26" in runtime
    for device in items
    if device["name"].startswith("iPhone")
)
print(found[-1][1] if found else "")
')"
if [[ -z "$udid" ]]; then
  echo "::error::no available iOS 26 iPhone simulator on this runner" >&2
  exit 1
fi
echo "simulator $udid"
# Coverage off: its profiler crashes Swift 6.3.3 on an isolated deinit
# (TerminalDevProbe, SILProfiler in emitIsolatingDestructor); the app builds
# without coverage. arm64 only: the xcframework has no x86_64 simulator slice.
echo "udid=$udid" >> "$GITHUB_OUTPUT"
xcodebuild test -scheme CmuxMobileKit-Package -destination "id=$udid,arch=arm64" \
  -enableCodeCoverage NO -derivedDataPath "${CMUX_DERIVED_DATA_SLOT:-$RUNNER_TEMP/dd-ios-sim}" CODE_SIGNING_ALLOWED=NO -quiet \
  -skip-testing:CmuxMobileInstantPerfTests \
  -skip-testing:CmuxMobileDesignCoreTests \
  -skip-testing:CmuxMobileRealtimeTests \
  -skip-testing:CmuxMobileTransportTests \
  -resultBundlePath "$RUNNER_TEMP/ios-sim.xcresult" && status=0 || status=$?
# -quiet drops Swift Testing's output: report from the result bundle (counts,
# suites that did not pass, #23829's banner suite, and every failure).
xcrun xcresulttool get test-results tests --path "$RUNNER_TEMP/ios-sim.xcresult" --compact 2>/dev/null |
  python3 -c '
import json, sys
counts = {}
def walk(node, path):
    kind, result = node.get("nodeType"), node.get("result")
    if kind == "Test Case":
        counts[result] = counts.get(result, 0) + 1
        if result == "Failed":
            print("FAILED:", " / ".join(path))
    if kind == "Test Suite" and (result != "Passed" or node.get("name") == "WaitingBannerTests"):
        print("suite", node.get("name"), result, len(node.get("children", [])), "tests")
    for child in node.get("children", []):
        if child.get("nodeType") == "Failure Message":
            print("   ", child.get("name"))
        else:
            walk(child, path + [child.get("name", "")])
for root in json.load(sys.stdin).get("testNodes", []):
    walk(root, [root.get("name", "")])
print("iOS simulator test cases:", ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
' || echo "::warning::could not read the result bundle"
exit "$status"
