import Foundation
import Security

/// The real Keychain wipe: `SecItemDelete` per class, synchronizable or
/// not. Without an access-group attribute it reaches only the groups this
/// app's entitlements claim, which is its own bundle group.
public struct SecurityKeychainWiper: KeychainWiping {
    public struct Failure: Error, Hashable, Sendable {
        public var status: Int32
    }

    public init() {}

    public func deleteAll(_ itemClass: KeychainItemClass) throws {
        let query: [String: Any] = [
            kSecClass as String: Self.secClass(itemClass),
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    static func secClass(_ itemClass: KeychainItemClass) -> CFString {
        switch itemClass {
        case .genericPassword: kSecClassGenericPassword
        case .internetPassword: kSecClassInternetPassword
        case .key: kSecClassKey
        case .certificate: kSecClassCertificate
        case .identity: kSecClassIdentity
        }
    }
}
