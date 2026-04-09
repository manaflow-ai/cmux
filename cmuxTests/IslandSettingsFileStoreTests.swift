// cmuxTests/IslandSettingsFileStoreTests.swift

import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Verifies that writing `island.enabled` into a settings.json snapshot
/// results in the parser setting the `IslandSettings.enabledKey` managed
/// default — so editing the file is equivalent to flipping the UI toggle.
final class IslandSettingsFileStoreTests: XCTestCase {

    private func snapshot(from json: String) throws -> ResolvedSettingsSnapshot {
        return try CmuxSettingsFileStore.testResolveSnapshot(jsonString: json)
    }

    func testIslandEnabledTrueIsWrittenToManagedDefaults() throws {
        let json = """
        {
          "island": { "enabled": true }
        }
        """
        let snap = try snapshot(from: json)
        XCTAssertEqual(
            snap.managedUserDefaults[IslandSettings.enabledKey],
            .bool(true)
        )
    }

    func testIslandEnabledFalseIsWrittenToManagedDefaults() throws {
        let json = """
        {
          "island": { "enabled": false }
        }
        """
        let snap = try snapshot(from: json)
        XCTAssertEqual(
            snap.managedUserDefaults[IslandSettings.enabledKey],
            .bool(false)
        )
    }

    func testIslandSectionMissingLeavesManagedDefaultsEmpty() throws {
        let json = "{}"
        let snap = try snapshot(from: json)
        XCTAssertNil(snap.managedUserDefaults[IslandSettings.enabledKey])
    }

    func testIslandEnabledPathIsWhitelisted() {
        XCTAssertTrue(
            CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("island.enabled")
        )
    }
}
