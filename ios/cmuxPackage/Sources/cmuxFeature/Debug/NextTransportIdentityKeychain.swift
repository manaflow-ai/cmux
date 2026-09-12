#if DEBUG
import Foundation
import OSLog
import Security

/// Identity private-key storage: the device-only Keychain (query shape
/// matches `CmxIrohKeychainIdentityStore`), with a one-time migration
/// from the UserDefaults slot early dev builds used. Secret material
/// never returns to defaults; if the Keychain refuses the write the
/// identity stays ephemeral for this launch.
struct NextTransportIdentityKeychain: Sendable {
    let logger: Logger

    static let account = "identity-private-key"

    /// Encodes and persists a live relay push on the generic executor.
    #if compiler(>=6.2)
    @concurrent
    #endif
    func persistRelay(
        url: String, token: String, service: String, account: String,
        defaults: NextTransportDefaultsBox, legacyKey: String
    ) async -> Bool {
        defer { defaults.value.removeObject(forKey: legacyKey) }
        guard let data = try? JSONEncoder().encode(["url": url, "token": token]) else {
            return false
        }
        return write(data, service: service, account: account)
    }

    func read(service: String, account: String) -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                logger.error(
                    "identity keychain read failed status=\(status, privacy: .public)")
            }
            return nil
        }
        return data
    }

    func write(_ data: Data, service: String, account: String) -> Bool {
        let query = baseQuery(service: service, account: account)
        let update = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else {
            logger.error(
                "identity keychain update failed status=\(update, privacy: .public)")
            return false
        }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(insert as CFDictionary, nil)
        guard add == errSecSuccess else {
            logger.error(
                "identity keychain add failed status=\(add, privacy: .public)")
            return false
        }
        return true
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
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
