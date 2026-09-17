#!/bin/bash
# Run only on a disposable/leased Mac or hosted CI, never the user's shared Mac.
# Compile production identity/migration and atomics; stub only display/tag metadata.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST=${1:?pass an isolated scratch directory}
mkdir -p "$DEST/Sources/IdentityColdStartFixture" "$DEST/Sources/CMUXMobileCore" \
  "$DEST/Sources/CmuxSettings" "$DEST/Sources/CmuxFoundation" \
  "$DEST/Sources/CmuxFoundationAtomicsC/include"
cat > "$DEST/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "IdentityColdStartFixture",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CMUXMobileCore"),
        .target(name: "CmuxSettings"),
        .target(name: "CmuxFoundationAtomicsC", publicHeadersPath: "include"),
        .target(name: "CmuxFoundation", dependencies: ["CmuxFoundationAtomicsC"]),
        .executableTarget(
            name: "IdentityColdStartFixture",
            dependencies: ["CMUXMobileCore", "CmuxSettings", "CmuxFoundation"]
        )
    ],
    swiftLanguageModes: [.v5]
)
SWIFT
cp "$ROOT/Sources/Mobile/MobileHostIdentity.swift" "$DEST/Sources/IdentityColdStartFixture/"
cp "$ROOT/tests/fixtures/mobile-host-identity-cold-start/IdentityColdStartFixture.swift" \
  "$ROOT/tests/fixtures/mobile-host-identity-cold-start/IdentityNotificationProbe.swift" \
  "$DEST/Sources/IdentityColdStartFixture/"
cp "$ROOT/Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxDeviceIDCanonicalization.swift" \
  "$DEST/Sources/CMUXMobileCore/"
cp "$ROOT/tests/fixtures/mobile-host-identity-cold-start/DisplayMetadataDependencies.swift" \
  "$DEST/Sources/CmuxSettings/"
cp "$ROOT/Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/Concurrency/AtomicBooleanGate.swift" \
  "$DEST/Sources/CmuxFoundation/"
cp "$ROOT/Packages/macOS/CmuxFoundation/Sources/CmuxFoundationAtomicsC/CmuxFoundationAtomicsC.c" \
  "$DEST/Sources/CmuxFoundationAtomicsC/"
cp "$ROOT/Packages/macOS/CmuxFoundation/Sources/CmuxFoundationAtomicsC/include/CmuxFoundationAtomicsC.h" \
  "$DEST/Sources/CmuxFoundationAtomicsC/include/"
swift build --package-path "$DEST" -Xswiftc -warnings-as-errors
BIN_DIR=$(swift build --package-path "$DEST" --show-bin-path)
python3 "$ROOT/tests/test_mobile_host_identity_cold_start.py" \
  "$BIN_DIR/IdentityColdStartFixture" "$DEST/results.json"
