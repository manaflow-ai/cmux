public import CmuxiOSFeatureKit
import Foundation
import Security

/// Host passwords as Keychain generic-password items, readable only while
/// the device is unlocked and never synced or migrated to another device
/// (`WhenUnlockedThisDeviceOnly`).
public struct KeychainSecretVault: SSHSecretVault {
    public enum Failure: Error, Hashable, Sendable {
        case keychain(OSStatus)
    }

    private let service: String

    public init(service: String = "dev.cmux.ios.ssh.passwords") {
        self.service = service
    }

    public func password(for host: HostID) async throws -> String? {
        var query = baseQuery(host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.keychain(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func setPassword(_ password: String, for host: HostID) async throws {
        let query = baseQuery(host)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    public func removePassword(for host: HostID) async throws {
        let status = SecItemDelete(baseQuery(host) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }

    private func baseQuery(_ host: HostID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host.rawValue,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
