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
    private let keychain = Keychain(service: "dev.cmux.next.native")
    private let lock = NSLock()
    private var cached: String?
    private var loaded = false

    var value: String? {
        get {
            lock.lock(); defer { lock.unlock() }
            if !loaded {
                loaded = true
                cached = keychain.read("session")
                #if DEBUG
                if cached == nil { cached = UserDefaults.standard.string(forKey: "debug.session") }
                #endif
            }
            return cached
        }
        set {
            lock.lock(); defer { lock.unlock() }
            loaded = true
            cached = newValue
            keychain.write("session", newValue)
            #if DEBUG
            if keychain.read("session") != newValue { UserDefaults.standard.set(newValue, forKey: "debug.session") }
            #endif
        }
    }
}
