#!/bin/bash
# Run only on a disposable/leased Mac or hosted CI, never the user's shared Mac.
# This compiles the persistent command transport and tests with app-level value dependencies stubbed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST=${1:?pass an isolated scratch directory}
mkdir -p "$DEST/Sources/CloudCommandFixture" "$DEST/Tests/CloudCommandFixtureTests"
cat > "$DEST/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CloudCommandFixture",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CloudCommandFixture"),
        .testTarget(name: "CloudCommandFixtureTests", dependencies: ["CloudCommandFixture"])
    ],
    swiftLanguageModes: [.v5]
)
SWIFT
for name in CloudTuiPersistentResourceConnection CloudTuiPersistentRequestBuilder CloudTuiTerminalProjectionTarget \
    CloudTuiManualIOConnection CloudTuiManualIODescriptorLease CloudTuiManualIOCommand \
    CloudTuiManualIOFrame CloudTuiManualIOFrameDecoder CloudTuiRemoteColors; do
    cp "$ROOT/Sources/Cloud/$name.swift" "$DEST/Sources/CloudCommandFixture/"
done
cp "$ROOT/tests/fixtures/cloud-command-deadlines/StandaloneDependencies.swift" "$DEST/Sources/CloudCommandFixture/"
for name in CloudCommandDeadlineClock CloudCommandDeadlineTests CloudTuiManualIOConnectionTests; do
    cp "$ROOT/cmuxTests/$name.swift" "$DEST/Tests/CloudCommandFixtureTests/"
done
swift test --package-path "$DEST" -Xswiftc -warnings-as-errors
