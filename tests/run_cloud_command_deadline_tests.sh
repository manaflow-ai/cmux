#!/bin/bash
# Run only on a disposable/leased Mac or hosted CI, never the user's shared Mac.
# This compiles the real command runner and tests with unrelated link dependencies stubbed.
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
cp "$ROOT/Sources/Cloud/CloudMachineLink.swift" "$ROOT/Sources/Cloud/CloudTuiClientPaths.swift" "$DEST/Sources/CloudCommandFixture/"
for source in "$ROOT"/Sources/Cloud/CloudCommand*.swift; do
    [[ -f "$source" ]] && cp "$source" "$DEST/Sources/CloudCommandFixture/"
done
cp "$ROOT/tests/fixtures/cloud-command-deadlines/StandaloneDependencies.swift" "$DEST/Sources/CloudCommandFixture/"
cp "$ROOT/cmuxTests/CloudCommandDeadlineClock.swift" "$ROOT/cmuxTests/CloudCommandDeadlineTests.swift" "$DEST/Tests/CloudCommandFixtureTests/"
swift test --package-path "$DEST" --filter CloudCommandDeadlineTests -Xswiftc -warnings-as-errors
