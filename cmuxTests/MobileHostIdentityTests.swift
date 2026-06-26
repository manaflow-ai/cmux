import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct MobileHostIdentityTests {
    @Test func prefersSharedIDAcrossBundleDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedIDURL = directory.appendingPathComponent("mobile-host-device-id")
        let sharedID = "3D56C547-271C-47D8-84F6-5C79C9394A37"
        try sharedID.lowercased().write(to: sharedIDURL, atomically: true, encoding: .utf8)

        let suiteName = "mobile-host-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("175dff61-cabe-4076-b5ac-f5c1c04b62fa", forKey: "mobileHost.deviceID")

        #expect(MobileHostIdentity.deviceID(defaults: defaults, sharedIDURL: sharedIDURL) == sharedID)
        #expect(defaults.string(forKey: "mobileHost.deviceID") == sharedID)
    }

    @Test func migratesExistingBundleIDToSharedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedIDURL = directory.appendingPathComponent("mobile-host-device-id")

        let suiteName = "mobile-host-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let defaultID = "C2FD4C2D-E0AF-447D-A8A4-D37BF67751EF"
        defaults.set(defaultID.lowercased(), forKey: "mobileHost.deviceID")

        #expect(MobileHostIdentity.deviceID(defaults: defaults, sharedIDURL: sharedIDURL) == defaultID)
        let persisted = try String(contentsOf: sharedIDURL, encoding: .utf8)
        #expect(persisted == defaultID)
    }

    @Test func taggedBuildMigratesStableBundleIDBeforeOwnBundleID() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedIDURL = directory.appendingPathComponent("mobile-host-device-id")

        let taggedSuiteName = "mobile-host-identity-tagged-\(UUID().uuidString)"
        let taggedDefaults = try #require(UserDefaults(suiteName: taggedSuiteName))
        defer { taggedDefaults.removePersistentDomain(forName: taggedSuiteName) }
        let taggedID = "91FD1481-336E-4230-BE5F-2EE6800B6E1A"
        taggedDefaults.set(taggedID, forKey: "mobileHost.deviceID")

        let stableSuiteName = "mobile-host-identity-stable-\(UUID().uuidString)"
        let stableDefaults = try #require(UserDefaults(suiteName: stableSuiteName))
        defer { stableDefaults.removePersistentDomain(forName: stableSuiteName) }
        let stableID = "0BF0E843-17CA-44AF-8B65-FC5C67D1D084"
        stableDefaults.set(stableID.lowercased(), forKey: "mobileHost.deviceID")

        #expect(MobileHostIdentity.deviceID(
            defaults: taggedDefaults,
            sharedIDURL: sharedIDURL,
            stableDefaults: stableDefaults,
            bundleIdentifier: "com.cmuxterm.app.debug.mpick"
        ) == stableID)
        #expect(taggedDefaults.string(forKey: "mobileHost.deviceID") == stableID)
        #expect(try String(contentsOf: sharedIDURL, encoding: .utf8) == stableID)
    }

    @Test func readsExistingSharedIDWithoutDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedIDURL = directory.appendingPathComponent("mobile-host-device-id")
        let sharedID = "4BF9566D-5D67-4C79-8974-B42D5CF39DE9"
        try sharedID.write(to: sharedIDURL, atomically: true, encoding: .utf8)

        let suiteName = "mobile-host-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(MobileHostIdentity.deviceID(defaults: defaults, sharedIDURL: sharedIDURL) == sharedID)
        #expect(defaults.string(forKey: "mobileHost.deviceID") == sharedID)
    }

    @Test func repairsInvalidSharedIDFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedIDURL = directory.appendingPathComponent("mobile-host-device-id")
        try "not-a-uuid".write(to: sharedIDURL, atomically: true, encoding: .utf8)

        let suiteName = "mobile-host-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fallbackID = "08E3578B-195D-486F-B874-023CDA2B647D"
        defaults.set(fallbackID, forKey: "mobileHost.deviceID")

        #expect(MobileHostIdentity.deviceID(defaults: defaults, sharedIDURL: sharedIDURL) == fallbackID)
        #expect(defaults.string(forKey: "mobileHost.deviceID") == fallbackID)
        #expect(try String(contentsOf: sharedIDURL, encoding: .utf8) == fallbackID)
    }
}
