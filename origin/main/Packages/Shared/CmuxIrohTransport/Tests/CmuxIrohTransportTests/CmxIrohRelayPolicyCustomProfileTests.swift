import Foundation
import Testing
@testable import CmuxIrohTransport

extension CmxIrohRelayPolicyTests {
    @Test
    func customProfileAllowsPrivateProviderPortWithoutManagedFallback() throws {
        let first = try CmxIrohCustomRelay(
            url: "https://relay.example.net:8443/",
            authenticationToken: "private-token"
        )
        let second = try CmxIrohCustomRelay(url: "https://backup.example.net/")
        let profile = try CmxIrohCustomRelayProfile(relays: [first, second])

        #expect(profile.relays.map(\.url) == [
            "https://relay.example.net:8443/",
            "https://backup.example.net/",
        ])
        #expect(profile.relays[0].authenticationToken == "private-token")
        #expect(profile.relays[1].authenticationToken == nil)

        #expect(throws: CmxIrohRelayPolicyError.invalidSelection) {
            try CmxIrohCustomRelayProfile(relays: [first, first])
        }
        #expect(throws: CmxIrohRelayPolicyError.invalidClaims) {
            try CmxIrohCustomRelay(url: "http://relay.example.net/")
        }
        #expect(throws: CmxIrohRelayPolicyError.invalidClaims) {
            try CmxIrohCustomRelay(
                url: "https://relay.example.net/",
                authenticationToken: "invalid\nprovider-token"
            )
        }
    }

    @Test
    func customProfileStoreKeepsTokensInSecureStorageAndRevalidatesRecords() async throws {
        let secureStore = TestSecureCredentialStore()
        let selectionStore = RelayPolicyTestInstallStateStore()
        let store = CmxIrohCustomRelayProfileStore(
            secureStore: secureStore,
            selectionStore: selectionStore
        )
        let profile = try CmxIrohCustomRelayProfile(
            relays: [
                CmxIrohCustomRelay(
                    url: "https://private.example.net:8443/",
                    authenticationToken: "private-token"
                ),
            ]
        )

        try await store.save(profile)
        #expect(try await store.load() == profile)
        #expect(await store.loadSelection() == .custom(profile))
        #expect(
            await secureStore.observedAccessibilities()
                == [.afterFirstUnlockThisDeviceOnly]
        )

        let invalid = Data(
            #"{"version":1,"relays":[{"url":"http://capture.example/","authenticationToken":null}]}"#.utf8
        )
        await secureStore.write(
            invalid,
            account: "active-custom-relay-profile",
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        #expect(try await store.load() == nil)
        #expect(await store.loadSelection() == .customUnavailable)
        #expect(await secureStore.recordCount() == 0)

        try await store.clear()
        #expect(await store.loadSelection() == .managed)
    }

    @Test
    func selectedCustomProfileFailsClosedWhenSecureStorageIsUnavailable() async throws {
        let secureStore = TestSecureCredentialStore()
        let selectionStore = RelayPolicyTestInstallStateStore()
        let store = CmxIrohCustomRelayProfileStore(
            secureStore: secureStore,
            selectionStore: selectionStore
        )
        let profile = try CmxIrohCustomRelayProfile(
            relays: [CmxIrohCustomRelay(url: "https://private.example.net/")]
        )
        try await store.save(profile)
        let unavailableStore = CmxIrohCustomRelayProfileStore(
            secureStore: RelayPolicyUnavailableSecureStore(),
            selectionStore: selectionStore
        )

        #expect(await unavailableStore.loadSelection() == .customUnavailable)

        let endpointProfile = CmxIrohEndpointRelayProfile.unavailableCustomOverride
        #expect(endpointProfile.allowedRelayURLs.isEmpty)
        #expect(endpointProfile.activeRelays.isEmpty)
        #expect(endpointProfile.source == .custom)
    }
}

private final class RelayPolicyTestInstallStateStore:
    CmxIrohInstallStateStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func string(forKey key: String) -> String? {
        lock.withLock { values[key] }
    }

    func set(_ value: String?, forKey key: String) {
        lock.withLock { values[key] = value }
    }
}

private struct RelayPolicyUnavailableSecureStore: CmxIrohSecureCredentialStoring {
    private struct Unavailable: Error {}

    func read(account: String) async throws -> Data? {
        throw Unavailable()
    }

    func write(
        _ data: Data,
        account: String,
        accessibility: CmxIrohSecureCredentialAccessibility
    ) async throws {}

    func delete(account: String) async throws {}

    func deleteAll() async throws {}
}
