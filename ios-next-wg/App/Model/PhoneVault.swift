import CmuxWireGuardPairing
import Foundation
import Security

/// The phone's secrets in the Keychain: its permanent WireGuard key and the
/// Macs it paired with (each carries a preshared key). Items stay on this
/// device and unlock after the first unlock since boot.
struct PhoneVault: Sendable {
    let service = "dev.cmux.ios.wg"

    /// The permanent WireGuard private key, created on first use.
    func identityKey() throws -> WireGuardKey {
        if let data = try read("identity-key"), let key = WireGuardKey(rawValue: data) { return key }
        let key = WireGuardKey()
        try write("identity-key", key.rawValue)
        return key
    }

    func pairedHosts() -> [PairedHost] {
        guard let data = try? read("paired-hosts") else { return [] }
        return (try? JSONDecoder().decode([PairedHost].self, from: data)) ?? []
    }

    func savePairedHosts(_ hosts: [PairedHost]) throws {
        try write("paired-hosts", JSONEncoder().encode(hosts))
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func read(_ account: String) throws -> Data? {
        #if targetEnvironment(simulator)
        if let data = try? Data(contentsOf: Self.simulatorFile(account)) { return data }
        #endif
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        #if targetEnvironment(simulator)
        if status == errSecMissingEntitlement { return nil }
        #endif
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return result as? Data
    }

    private func write(_ account: String, _ data: Data) throws {
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        #if targetEnvironment(simulator)
        // An unsigned simulator build has no Keychain entitlement.
        if status == errSecMissingEntitlement {
            let file = Self.simulatorFile(account)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            return
        }
        #endif
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    #if targetEnvironment(simulator)
    private static func simulatorFile(_ account: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vault", isDirectory: true).appendingPathComponent(account)
    }
    #endif
}
