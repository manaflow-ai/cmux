import CMUXMobileCore
import CmuxIrxTransport
import Foundation
import Testing
@testable import cmuxFeature

struct MobileIrohV2LocalPathStoreTests {
    @Test
    func localPathStateIsOwnerOnlyAndExcludedFromBackup() async throws {
        let files = FileManager()
        let root = files.temporaryDirectory.appendingPathComponent(
            "cmux-iroh-local-paths-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? files.removeItem(at: root) }

        let identity = V2Identity(
            appNamespace: "com.cmux.tests",
            buildTag: "test",
            deviceID: "device",
            environment: "test",
            projectID: "project",
            teamID: "team",
            userID: "user"
        )
        let store = MobileIrohV2LocalPathStore(root: root)
        try await store.upsert(
            CmxIrohCustomPrivatePathDraft(
                macDeviceID: "123e4567-e89b-42d3-a456-426614174000",
                instanceTag: "test",
                macDisplayName: "Test Mac",
                addresses: ["10.0.0.8:9410"],
                isEnabled: true
            ),
            identity: identity
        )

        let directory = root.appendingPathComponent(
            "cmux-iroh-v2/local-paths",
            isDirectory: true
        )
        let entries = try files.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isExcludedFromBackupKey]
        )
        #expect(entries.count == 1)
        let directoryAttributes = try files.attributesOfItem(atPath: directory.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let fileAttributes = try files.attributesOfItem(atPath: entries[0].path)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryValues = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(directoryValues.isExcludedFromBackup == true)
        let fileValues = try entries[0].resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(fileValues.isExcludedFromBackup == true)

        // A pre-hardening file is repaired on the next read as well.
        try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: entries[0].path)
        let reopened = MobileIrohV2LocalPathStore(root: root)
        let restored = try await reopened.load(identity: identity)
        #expect(restored.count == 1)
        let repaired = try files.attributesOfItem(atPath: entries[0].path)
        #expect((repaired[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
