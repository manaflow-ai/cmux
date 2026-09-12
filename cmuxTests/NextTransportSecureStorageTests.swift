#if DEBUG
import CmuxIrohTransport
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Next transport secure storage fails closed")
struct NextTransportSecureStorageTests {
    @Test func unreadableRevocationsDoNotBecomeAnEmptyDenylist() async {
        let fixture = NextTransportSecureStoreFixture(readFails: true)
        let store = MobileHostNextTransportGrantRevocationStore(keychain: fixture)
        await #expect(throws: NextTransportSecureStoreFixture.Unavailable.self) {
            try await store.load()
        }
        await #expect(throws: NextTransportSecureStoreFixture.Unavailable.self) {
            try await store.revoke(["new-revocation"])
        }
        #expect(await fixture.writes == 0)
    }

    @Test func corruptRevocationsAreNotOverwritten() async {
        let fixture = NextTransportSecureStoreFixture(data: Data("corrupt".utf8))
        let store = MobileHostNextTransportGrantRevocationStore(keychain: fixture)
        await #expect(throws: DecodingError.self) { try await store.load() }
        await #expect(throws: DecodingError.self) { try await store.revoke(["new-revocation"]) }
        #expect(await fixture.writes == 0)
    }

    @Test func unreadableIdentityIsNotMissing() async {
        let fixture = NextTransportSecureStoreFixture(readFails: true)
        let defaults = UserDefaults(suiteName: "next-transport-read-error-\(UUID())")!
        await #expect(throws: NextTransportSecureStoreFixture.Unavailable.self) {
            try await MobileHostNextTransportRuntime.loadOrMigrateSecret(
                account: "identity", legacyDefaultsKey: "legacy", store: fixture, defaults: defaults)
        }
        #expect(await fixture.writes == 0)
    }

    @Test func missingRevocationsAreEmpty() async throws {
        let store = MobileHostNextTransportGrantRevocationStore(keychain: NextTransportSecureStoreFixture())
        #expect(try await store.load().isEmpty)
    }
}
#endif
