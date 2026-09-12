#if DEBUG
import Foundation
import OSLog
import Security

/// Device-only Keychain persistence for ticket/grant pairs. The defaults
/// key is retained solely as a one-time migration source for older debug
/// builds; new writes never place pairing material in preferences.
struct NextTransportBootstrapKeychain: Sendable {
    let service: String
    let logger: Logger

    private static let accountPrefix = "mac-"

    /// Performs JSON encoding and protected persistence off the UI actor.
    #if compiler(>=6.2)
    @concurrent
    #endif
    func persist(
        ticket: String, grant: String, macID: String,
        defaults: NextTransportDefaultsBox, keyPrefix: String
    ) async -> Bool {
        guard let data = try? JSONEncoder().encode(["ticket": ticket, "grant": grant]) else {
            return false
        }
        return write(data, macID: macID, defaults: defaults.value, keyPrefix: keyPrefix)
    }

    /// Runs invalidation on the same concurrent persistence boundary as writes.
    #if compiler(>=6.2)
    @concurrent
    #endif
    func remove(
        macID: String, defaults: NextTransportDefaultsBox, keyPrefix: String
    ) async -> Bool {
        let status = SecItemDelete(baseQuery(account: Self.accountPrefix + macID) as CFDictionary)
        defaults.value.removeObject(forKey: keyPrefix + macID)
        let succeeded = status == errSecSuccess || status == errSecItemNotFound
        if !succeeded { logger.error("bootstrap Keychain deletion failed status=\(status, privacy: .public)") }
        return succeeded
    }

    func read(
        macID: String, defaults: UserDefaults, keyPrefix: String
    ) -> Data? {
        let account = Self.accountPrefix + macID
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data {
            return data
        }
        guard let legacy = defaults.data(forKey: keyPrefix + macID) else { return nil }
        // Migrate atomically from the old preferences slot when possible.
        let migrated = writeKeychain(legacy, account: account)
        // Never leave ticket/grant material in the preferences plist when
        // the protected write is unavailable; callers can re-pair.
        defaults.removeObject(forKey: keyPrefix + macID)
        return migrated ? legacy : nil
    }

    func write(
        _ data: Data, macID: String, defaults: UserDefaults, keyPrefix: String
    ) -> Bool {
        let account = Self.accountPrefix + macID
        if writeKeychain(data, account: account) {
            defaults.removeObject(forKey: keyPrefix + macID)
            return true
        } else {
            logger.error(
                "bootstrap Keychain write failed mac=\(String(macID.prefix(8)), privacy: .public); not writing defaults")
            defaults.removeObject(forKey: keyPrefix + macID)
            return false
        }
    }

    private func writeKeychain(_ data: Data, account: String) -> Bool {
        let query = baseQuery(account: account)
        let update = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
#endif
