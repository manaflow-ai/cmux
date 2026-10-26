import CmuxIrxTransport
import Foundation
import Testing

@testable import cmuxFeature

/// The device-list adapter reads the same catalog that live discovery fills.
/// If an account switch races a discovery refresh, the refresh is discarded;
/// that discarded result must also clear the old account's catalog before the
/// device tree asks the adapter for its list.
@MainActor
@Suite("personal Iroh device registry")
struct PersonalIrohDeviceRegistryDecoratorTests {
    @Test("a scope-mismatched discovery cannot leave the previous account visible")
    func mismatchedDiscoveryClearsCatalogBeforeRegistryRead() async throws {
        let directory = Self.directory()
        let scopeIDs = ScopeSequence([
            "account-a:team-a",
            "account-a:team-a",
            "account-b:team-b",
            "account-c:team-c",
        ])
        let provider = MobileIrxDiscoveryProvider(
            preferredTag: "default",
            compatibilityPolicy: nil,
            discover: { directory },
            invalidateSnapshot: {},
            revokeBinding: { _ in },
            authenticatedAccountID: { "account-a" },
            authenticatedScopeID: { await scopeIDs.next() }
        )

        #expect((await provider.discoverLiveMacs()).count == 1)

        // The account/team changes while the second discovery is suspended.
        // The provider must invalidate the old projection even though it drops
        // the new directory as stale.
        #expect((await provider.discoverLiveMacs()).isEmpty)

        let registry = PersonalIrohDeviceRegistryDecorator(
            catalog: provider.routeCatalog,
            knownRoutes: { _, _ in nil }
        )
        switch await registry.listDevices() {
        case .ok(let devices):
            #expect(devices.isEmpty)
        case .authRejected, .transientFailure:
            Issue.record("catalog scope mismatch should produce an empty list, not a registry failure")
        }
    }

    private static func directory() -> V2Directory {
        let device = V2DeviceDescriptor(
            endpointID: String(repeating: "a", count: 64),
            identity: V2Identity(
                appNamespace: "mac:com.cmuxterm.app",
                buildTag: "default",
                deviceID: "123e4567-e89b-42d3-a456-426614174011",
                environment: "production",
                projectID: "project-a",
                teamID: "team-a",
                userID: "account-a"
            ),
            identityGeneration: 1,
            metadata: V2DeviceMetadata(
                appVersion: "1.0",
                capabilities: ["irx-v2"],
                displayName: "Mac mini de Said",
                pairingEnabled: true,
                platform: .mac,
                relayURLs: []
            )
        )
        return V2Directory(
            devices: [V2DeviceRecord(
                descriptor: device,
                deviceRecordID: "record-a",
                revision: 1,
                revoked: false
            )],
            issuedAt: 1_800_000_000,
            permissionExpiresAt: 2_000_000_000,
            relayURLs: [],
            revision: 1,
            teamID: "team-a"
        )
    }
}

private actor ScopeSequence {
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String? {
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}
