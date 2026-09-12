#if DEBUG
import CmuxIrohTransport
import Foundation

/// Per-test secure store; failures never rely on the user's real Keychain.
actor NextTransportSecureStoreFixture: CmxIrohSecureIdentityStoring, CmxIrohSecureCredentialStoring {
    struct Unavailable: Error {}
    let data: Data?
    let readFails: Bool
    private(set) var writes = 0

    init(data: Data? = nil, readFails: Bool = false) {
        self.data = data
        self.readFails = readFails
    }

    func read(account: String) async throws -> Data? {
        if readFails { throw Unavailable() }
        return data
    }

    func write(_ data: Data, account: String) async throws { writes += 1 }
    func write(_ data: Data, account: String, accessibility: CmxIrohSecureCredentialAccessibility) async throws {
        writes += 1
    }
    func delete(account: String) async throws {}
    func deleteAll() async throws {}
}
#endif
