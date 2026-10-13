import Foundation
import Security

/// Client-generated device UUIDs persisted in the Keychain (PROTOCOL.md "Devices").
///
/// Two ids: `link` dials Macs (its signaling socket carries the WireGuard
/// relay while a link is up), and `presence` holds the app's own presence
/// socket. The backend keeps one socket per device and a newer one replaces
/// the older (close 4000), so sharing one id would cut the relay whenever the
/// presence listener reconnects.
public struct DeviceIdentity: Sendable {
    public let link: String
    public let presence: String

    public init(link: String, presence: String) {
        self.link = link
        self.presence = presence
    }

    /// Reads (or creates and stores) both ids.
    public static func load(service: String = "dev.cmux.cnx.device") -> DeviceIdentity {
        DeviceIdentity(link: id(service: service, account: "link"), presence: id(service: service, account: "presence"))
    }

    /// Sign-out: forgets both ids. The service binds a device id to the user
    /// who registered it (`403 not_owner` for anyone else), so the next account
    /// gets new ones.
    public static func reset(service: String = "dev.cmux.cnx.device") {
        for account in ["link", "presence"] {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
            SecItemDelete(query as CFDictionary)
        }
    }

    static func id(service: String, account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let value = String(data: data, encoding: .utf8), UUID(uuidString: value) != nil {
            return value
        }
        let value = UUID().uuidString.lowercased()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemDelete(add as CFDictionary)
        SecItemAdd(add as CFDictionary, nil)
        return value
    }
}
