import CryptoKit
public import CmuxPairing
public import Foundation
import Security

/// `DirectKeyStore` in the Keychain, `AfterFirstUnlockThisDeviceOnly`, not
/// synced (transport.md section 8; b4-direct.md section 2). One X25519 key
/// per link purpose: B4's `direct` key, B3's WireGuard (`wg`) key.
public struct KeychainDirectKeyStore: DirectKeyStore {
    public enum Failure: Error, Hashable { case keychain(OSStatus) }

    private let service: String
    private let account: String

    /// One key per (bundle, API environment, purpose), like the install key.
    public init(bundleID: String, environment: String, purpose: LinkPurpose = .direct) {
        let name = purpose == .wg ? "wg-key" : "direct-key"
        service = "\(bundleID).\(name).\(environment)"
        account = name
    }

    public func privateKey() throws -> Data {
        if let raw = try read() { return raw }
        let made = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        try write(made)
        return made
    }

    public func publicKey() throws -> Data {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey()).publicKey.rawRepresentation
    }

    public func rotate() throws {
        SecItemDelete(query() as CFDictionary)
        _ = try privateKey()
    }

    private func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    private func read() throws -> Data? {
        var q = query()
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return out as? Data
    }

    private func write(_ data: Data) throws {
        var q = query()
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }
}
