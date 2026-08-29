import CmuxIrohTransport
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
    static func discovery(
        bindings: [[String: Any]]
    ) throws -> CmxIrohDiscoveryResponse {
        let object: [String: Any] = [
            "route_contract_version": 1,
            "bindings": bindings,
            "relay_fleet": ["https://usw1.relay.cmux.dev/"],
            "lan_rendezvous": [
                "generation": 1,
                "key": Data(repeating: 0, count: 32).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: ""),
            ],
            "grant_verification_keys": [
                "version": 1,
                "current_kid": "test-key",
                "keys": [["kid": "test-key", "alg": "EdDSA", "spki_der_base64": "AA=="]],
            ],
        ]
        return try JSONDecoder().decode(
            CmxIrohDiscoveryResponse.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    static func binding(
        bindingID: String,
        deviceID: String,
        platform: String,
        tag: String = "default",
        pairingEnabled: Bool = true,
        endpointFill: Character = "a"
    ) -> [String: Any] {
        [
            "binding_id": bindingID,
            "device_id": deviceID,
            "app_instance_id": "123e4567-e89b-42d3-a456-426614174012",
            "client_namespace": "legacy",
            "tag": tag,
            "platform": platform,
            "display_name": "Fixture \(platform)",
            "endpoint_id": String(repeating: endpointFill, count: 64),
            "identity_generation": 1,
            "pairing_enabled": pairingEnabled,
            "capabilities": ["rpc"],
            "path_hints": [],
            "last_seen_at": ISO8601DateFormatter()
                .string(from: Date(timeIntervalSince1970: 1_800_000_000)),
        ]
    }

    static func provider(
        discovery: CmxIrohDiscoveryResponse?,
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
