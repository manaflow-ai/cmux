#!/usr/bin/env bash
# Run the production Feed text renderer's focused UIKit regression suite on
# an isolated simulator. This leaf harness avoids compiling unrelated shell
# features; the tagged iOS app build separately verifies module integration.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d -t cmux-feed-inline-text.XXXXXX)"
simulator_id=""
cleanup() {
  if [ -n "$simulator_id" ]; then
    xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true
  fi
  rm -rf "$test_root"
}
trap cleanup EXIT
mkdir -p "$test_root/Sources/CmuxMobileShellUI/Resources/en.lproj" "$test_root/Tests/CmuxMobileShellUITests"
cp "$repo_root/Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/AgentFeedInlineText.swift" "$test_root/Sources/CmuxMobileShellUI/"
cp "$repo_root/Packages/iOS/CmuxMobileShellUI/Tests/CmuxMobileShellUITests/AgentFeedInlineTextTests.swift" "$test_root/Tests/CmuxMobileShellUITests/"
printf '"mobile.agentFeed.fullText.seeMore" = "See more";\n' > "$test_root/Sources/CmuxMobileShellUI/Resources/en.lproj/Localizable.strings"
cat > "$test_root/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CmuxMobileShellUI", defaultLocalization: "en", platforms: [.iOS(.v17)],
    products: [.library(name: "CmuxMobileShellUI", targets: ["CmuxMobileShellUI"])],
    targets: [
        .target(name: "CmuxMobileShellUI", resources: [.process("Resources")]),
        .testTarget(name: "CmuxMobileShellUITests", dependencies: ["CmuxMobileShellUI"])
    ]
)
SWIFT
runtime_id="$(xcrun simctl list runtimes available -j | python3 -c '
import json,sys
rs=[r for r in json.load(sys.stdin)["runtimes"] if r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]
assert rs, "An installed iOS simulator runtime is required"
print(max(rs,key=lambda r:tuple(map(int,r["version"].split("."))))["identifier"])
')"
device_type="$(xcrun simctl list devicetypes -j | python3 -c '
import json,sys
ds=[d for d in json.load(sys.stdin)["devicetypes"] if d["name"]=="iPhone 16 Pro"]
assert ds, "iPhone 16 Pro simulator device type is required"
print(ds[0]["identifier"])
')"
simulator_id="$(xcrun simctl create "cmux-feed-text-$$" "$device_type" "$runtime_id")"
xcrun simctl boot "$simulator_id"
xcrun simctl bootstatus "$simulator_id" -b
cd "$test_root"
set +e
xcodebuild -scheme CmuxMobileShellUI \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$test_root/DerivedData" -resultBundlePath "$test_root/FeedText.xcresult" \
  -parallel-testing-enabled NO -only-testing:CmuxMobileShellUITests/AgentFeedInlineTextTests \
  CODE_SIGNING_ALLOWED=NO test > "$test_root/tests.log" 2>&1
test_status=$?
set -e
tail -n 100 "$test_root/tests.log"
if [ -d "$test_root/FeedText.xcresult" ]; then
  xcrun xcresulttool get test-results summary --path "$test_root/FeedText.xcresult" --compact
fi
exit "$test_status"
