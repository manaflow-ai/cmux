import CNCore
import Foundation
import Security
import Synchronization

/// Tokens persisted between launches.
public struct StoredSession: Codable, Sendable, Hashable {
    public var accessToken: String
    public var refreshToken: String
    public var accessTokenExpiresAt: Date
    public var user: User

    public init(accessToken: String, refreshToken: String, accessTokenExpiresAt: Date, user: User) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt; self.user = user
    }

    public init(tokens: Tokens, now: Date = Date()) {
        self.init(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
                  accessTokenExpiresAt: now.addingTimeInterval(TimeInterval(tokens.expiresIn)), user: tokens.user)
    }
}

/// Where the signed-in session lives.
public protocol TokenStore: Sendable {
    func load() -> StoredSession?
    func save(_ session: StoredSession) throws
    func clear()
}

/// Volatile store for previews and tests.
public final class InMemoryTokenStore: TokenStore {
    private let value: Mutex<StoredSession?>
    public init(_ initial: StoredSession? = nil) { value = Mutex(initial) }
    public func load() -> StoredSession? { value.withLock { $0 } }
    public func save(_ session: StoredSession) throws { value.withLock { $0 = session } }
    public func clear() { value.withLock { $0 = nil } }
}

public struct KeychainError: Error, Sendable, Hashable, LocalizedError {
    public var status: OSStatus
    public var errorDescription: String? { "Keychain error \(status)" }
}

/// Generic-password keychain item, service `<bundle id>.auth`, readable after
/// first unlock so background reconnects can refresh.
public final class KeychainTokenStore: TokenStore {
    public let service: String
    public let account: String

    public init(service: String = (Bundle.main.bundleIdentifier ?? "dev.cmux.next") + ".auth", account: String = "session") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> StoredSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    public func save(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(session)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        var status = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add.merge(attrs) { _, b in b }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
