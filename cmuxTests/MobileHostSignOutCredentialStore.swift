import CmuxIrohTransport
import Foundation

/// Isolated persistence used by the host sign-out behavior test.
actor MobileHostSignOutCredentialStore: CmxIrohSecureCredentialStoring {
    private var records: [String: Data] = [:]

    func read(account: String) async throws -> Data? { records[account] }
    func write(_ data: Data, account: String, accessibility: CmxIrohSecureCredentialAccessibility) async throws {
        records[account] = data
    }
    func delete(account: String) async throws { records[account] = nil }
    func deleteAll() async throws { records.removeAll() }
}
