import CmuxIrohTransport
import CmuxIrxTransport
import CmuxMobileShell
import Foundation
import Testing

@testable import cmuxFeature

/// Regression for the 08-28 fresh-install incident: the first-pair picker
/// asked the dormant legacy runtime for Macs and rendered zero forever. The
/// irx provider must surface pairable Macs from irx broker discovery with
/// dialable iroh routes, and forget must revoke only under the expected
/// account.
@MainActor
@Suite("irx discovery provider")
struct MobileIrxDiscoveryProviderTests {
    static func discovery(bindings: [V2DeviceRecord]) throws -> V2Directory {
        V2Directory(devices: bindings, issuedAt: 1_800_000_000,
            permissionExpiresAt: 2_000_000_000, relayURLs: ["https://relay.example.com"], revision: 1, teamID: "team-a")
    }

    static func binding(bindingID: String, deviceID: String, platform: String,
                        tag: String = "default", pairingEnabled: Bool = true,
                        endpointFill: Character = "a") -> V2DeviceRecord {
        V2DeviceRecord(descriptor: V2DeviceDescriptor(endpointID: String(repeating: endpointFill, count: 64),
            identity: V2Identity(appNamespace: "dev.cmux.app", buildTag: tag, deviceID: deviceID,
                environment: "development", projectID: "project-a", teamID: "team-a", userID: "account-a"),
            identityGeneration: 1, metadata: V2DeviceMetadata(appVersion: "1.0", capabilities: ["rpc"],
                displayName: "Fixture " + platform, pairingEnabled: pairingEnabled,
                platform: platform == "mac" ? .mac : .ios, relayURLs: [])),
            deviceRecordID: bindingID, revision: 1, revoked: false)
    }

    static func provider(
        discovery: V2Directory?,
        accountID: String? = "account-a",
        onRevoke: (@Sendable (String) -> Void)? = nil
    ) -> MobileIrxDiscoveryProvider {
        MobileIrxDiscoveryProvider(
            preferredTag: "default",
            compatibilityPolicy: nil,
            discover: { discovery },
            invalidateSnapshot: {},
            revokeBinding: { onRevoke?($0) },
            authenticatedAccountID: { accountID }
        )
    }

    @Test("pairable Macs from irx discovery become candidates with iroh routes")
    func discoverySurfacesPairableMacs() async throws {
        let mac = "123e4567-e89b-42d3-a456-426614174011"
        let phone = "123e4567-e89b-42d3-a456-426614174022"
        let response = try Self.discovery(bindings: [
            Self.binding(
                bindingID: "123e4567-e89b-42d3-a456-426614174001",
                deviceID: mac, platform: "mac", endpointFill: "a"),
            Self.binding(
                bindingID: "123e4567-e89b-42d3-a456-426614174002",
                deviceID: phone, platform: "ios", endpointFill: "b"),
        ])
        let candidates = await Self.provider(discovery: response).discoverLiveMacs()
        #expect(candidates.count == 1)
        #expect(candidates.first?.deviceID == mac)
        #expect(candidates.first?.routes.first?.kind == .iroh)
    }

    @Test func directoryKeepsOfflineMacsAndRejectsDuplicateEndpointKeys() async throws {
        let first = Self.binding(bindingID: "first", deviceID: "123e4567-e89b-42d3-a456-426614174011", platform: "mac")
        let duplicate = Self.binding(bindingID: "second", deviceID: "123e4567-e89b-42d3-a456-426614174022", platform: "mac")
        let offline = Self.binding(bindingID: "third", deviceID: "123e4567-e89b-42d3-a456-426614174033", platform: "mac", endpointFill: "b")
        let candidates = await Self.provider(discovery: try Self.discovery(bindings: [first, duplicate, offline])).discoverLiveMacs()
        #expect(candidates.map(\.deviceID) == ["123e4567-e89b-42d3-a456-426614174033"])
    }

    @Test("discovery outage degrades to zero candidates instead of throwing")
    func discoveryOutage() async {
        let candidates = await Self.provider(discovery: nil).discoverLiveMacs()
        #expect(candidates.isEmpty)
    }

    @Test("forget revokes exactly the matching device's bindings")
    func forgetRevokesMatches() async throws {
        let mac = "123e4567-e89b-42d3-a456-426614174011"
        let other = "123e4567-e89b-42d3-a456-426614174033"
        let response = try Self.discovery(bindings: [
            Self.binding(
                bindingID: "123e4567-e89b-42d3-a456-426614174001",
                deviceID: mac, platform: "mac", endpointFill: "a"),
            Self.binding(
                bindingID: "123e4567-e89b-42d3-a456-426614174003",
                deviceID: other, platform: "mac", endpointFill: "c"),
        ])
        let revoked = RevokedBox()
        let provider = Self.provider(discovery: response) { revoked.append($0) }
        try await provider.forgetComputer(
            macDeviceID: mac, instanceTag: nil, expectedAccountID: "account-a")
        #expect(revoked.values == ["123e4567-e89b-42d3-a456-426614174001"])
    }

    @Test("forget refuses when the live account is not the expected owner")
    func forgetAccountGuard() async throws {
        let response = try Self.discovery(bindings: [])
        let provider = Self.provider(discovery: response, accountID: "account-b")
        await #expect(throws: MobileIrxForgetError.accountMismatch) {
            try await provider.forgetComputer(
                macDeviceID: "123e4567-e89b-42d3-a456-426614174011",
                instanceTag: nil,
                expectedAccountID: "account-a"
            )
        }
    }
}

private final class RevokedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }
}
