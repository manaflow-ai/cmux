import Foundation
import Security

/// Small generic-password Keychain wrapper for the session token.
struct Keychain: Sendable {
    let service: String

    func read(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ account: String, _ value: String?) {
        SecItemDelete(base(account) as CFDictionary)
        guard let value else { return }
        var query = base(account)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

/// The session token: Keychain-backed, with an in-memory copy. An unsigned
/// simulator build has no Keychain access; DEBUG builds fall back to
/// UserDefaults there so agent test runs survive relaunches.
final class SessionTokenStore: @unchecked Sendable {
    /// One cache for every instance (the app model and the push manager each
    /// make one): a sign-in or sign-out through one is seen by the others.
    private struct Cache {
        var value: String?
        var loaded = false
    }

    nonisolated(unsafe) private static var cache = Cache()
    private static let lock = NSLock()
    private let keychain = Keychain(service: "dev.cmux.next.native")

    var value: String? {
        get {
            Self.lock.lock(); defer { Self.lock.unlock() }
            if !Self.cache.loaded {
                Self.cache.loaded = true
                Self.cache.value = keychain.read("session")
                #if DEBUG
                if Self.cache.value == nil { Self.cache.value = UserDefaults.standard.string(forKey: "debug.session") }
                #endif
            }
            return Self.cache.value
        }
        set {
            Self.lock.lock(); defer { Self.lock.unlock() }
            Self.cache.loaded = true
            Self.cache.value = newValue
            keychain.write("session", newValue)
            #if DEBUG
            if keychain.read("session") != newValue { UserDefaults.standard.set(newValue, forKey: "debug.session") }
            #endif
        }
    }
}
