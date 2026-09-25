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
# CloudTuiTerminalProjectionTarget lives in the CmuxSurfaceCatalogModel package, not in CmuxCloud.
cp "$ROOT/Packages/macOS/CmuxSurfaceCatalogModel/Sources/CmuxSurfaceCatalogModel/CloudTuiTerminalProjectionTarget.swift" \
    "$DEST/Sources/CloudCommandFixture/"
cp "$ROOT/Packages/macOS/CmuxCloud/Sources/CmuxCloud/Link/CloudTuiPersistentResourceConnection.swift" "$DEST/Sources/CloudCommandFixture/"
# The rest of the transport lives in the CmuxCloudTui package.
for name in CloudTuiPersistentRequestBuilder \
    CloudTuiManualIOConnection CloudTuiManualIODescriptorLease CloudTuiManualIOCommand \
    CloudTuiManualIOFrame CloudTuiManualIOFrameDecoder CloudTuiRemoteColors; do
    cp "$ROOT/Packages/macOS/CmuxCloudTui/Sources/CmuxCloudTui/$name.swift" "$DEST/Sources/CloudCommandFixture/"
done
cp "$ROOT/tests/fixtures/cloud-command-deadlines/StandaloneDependencies.swift" "$DEST/Sources/CloudCommandFixture/"
# The fixture stubs the catalog value types it needs (StandaloneDependencies.swift) and
# compiles the transport into one module, so the copied sources and tests must not import
# the real packages.
sed -i.bak -e '/^import CmuxSurfaceCatalogModel$/d' -e '/^import CmuxCloudTui$/d' \
    "$DEST/Sources/CloudCommandFixture/"*.swift
rm -f "$DEST/Sources/CloudCommandFixture/"*.bak
for name in CloudCommandDeadlineClock CloudCommandDeadlineTests CloudTuiManualIOConnectionTests; do
    cp "$ROOT/cmuxTests/$name.swift" "$DEST/Tests/CloudCommandFixtureTests/"
done
sed -i.bak '/^import CmuxCloudTui$/d' "$DEST/Tests/CloudCommandFixtureTests/"*.swift
rm -f "$DEST/Tests/CloudCommandFixtureTests/"*.bak
swift test --package-path "$DEST" -Xswiftc -warnings-as-errors
