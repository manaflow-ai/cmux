import Foundation
import Security

/// Keychain-backed identity material for the v3 endpoint. The seed is shared
/// by the libp2p PeerId and the HTTP enrollment proof, so the server can bind
/// the enrolled device to the exact transport identity.
struct MobileV3IdentityStore: Sendable {
    let service: String
    let accessGroup: String?

    func seed() throws -> Data {
        let account = "transport-v3-seed"
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        if let value = read(query: query), value.count == 32 { return value }
        var seed = Data(repeating: 0, count: 32)
        let status = seed.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw Error.keychain(status) }
        var insert = baseQuery(account: account)
        insert[kSecValueData as String] = seed
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
            if let value = read(query: query), value.count == 32 { return value }
            throw Error.keychain(errSecDuplicateItem)
        }
        return seed
    }

    func deviceID() throws -> UUID {
        let account = "transport-v3-device-id"
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        if let value = read(query: query), let string = String(data: value, encoding: .utf8), let id = UUID(uuidString: string) {
            return id
        }
        let id = UUID()
        var insert = baseQuery(account: account)
        insert[kSecValueData as String] = Data(id.uuidString.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
            if let value = read(query: query), let string = String(data: value, encoding: .utf8), let id = UUID(uuidString: string) { return id }
            throw Error.keychain(errSecDuplicateItem)
        }
        return id
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func read(query: [String: Any]) -> Data? {
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    enum Error: Swift.Error, Sendable {
        case keychain(OSStatus)
    }
}
