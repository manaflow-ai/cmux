import Foundation
import Security

protocol TerminalCredentialsStoring {
    func password(for hostID: TerminalHost.ID) -> String?
    func privateKey(for hostID: TerminalHost.ID) -> String?
    func setPassword(_ password: String?, for hostID: TerminalHost.ID) throws
    func setPrivateKey(_ privateKey: String?, for hostID: TerminalHost.ID) throws
}

extension TerminalCredentialsStoring {
    func sshCredentials(for hostID: TerminalHost.ID) -> TerminalSSHCredentials {
        TerminalSSHCredentials(
            password: password(for: hostID),
            privateKey: privateKey(for: hostID)
        )
    }

    func setSSHCredentials(_ credentials: TerminalSSHCredentials, for hostID: TerminalHost.ID) throws {
        let normalized = credentials.normalized
        try setPassword(normalized.password, for: hostID)
        try setPrivateKey(normalized.privateKey, for: hostID)
    }
}

final class TerminalKeychainStore: TerminalCredentialsStoring {
    private let passwordService = "dev.cmux.app.terminal.password"
    private let privateKeyService = "dev.cmux.app.terminal.private-key"

    func password(for hostID: TerminalHost.ID) -> String? {
        stringValue(for: hostID, service: passwordService)
    }

    func privateKey(for hostID: TerminalHost.ID) -> String? {
        stringValue(for: hostID, service: privateKeyService)
    }

    func setPassword(_ password: String?, for hostID: TerminalHost.ID) throws {
        try setStringValue(password, for: hostID, service: passwordService)
    }

    func setPrivateKey(_ privateKey: String?, for hostID: TerminalHost.ID) throws {
        try setStringValue(privateKey, for: hostID, service: privateKeyService)
    }

    private func stringValue(for hostID: TerminalHost.ID, service: String) -> String? {
        let query = baseQuery(hostID: hostID, service: service)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    private func setStringValue(_ value: String?, for hostID: TerminalHost.ID, service: String) throws {
        let query = baseQuery(hostID: hostID, service: service)
        if let value, !value.isEmpty {
            let data = Data(value.utf8)
            let attributes: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updateStatus == errSecItemNotFound {
                var insertQuery = query
                insertQuery[kSecValueData as String] = data
                let insertStatus = SecItemAdd(insertQuery as CFDictionary, nil)
                guard insertStatus == errSecSuccess else {
                    throw TerminalKeychainError.unhandledStatus(insertStatus)
                }
                return
            }

            guard updateStatus == errSecSuccess else {
                throw TerminalKeychainError.unhandledStatus(updateStatus)
            }
            return
        }

        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw TerminalKeychainError.unhandledStatus(deleteStatus)
        }
    }

    private func baseQuery(hostID: TerminalHost.ID, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
    }
}

enum TerminalKeychainError: Error {
    case unhandledStatus(OSStatus)
}

final class InMemoryTerminalCredentialsStore: TerminalCredentialsStoring {
    private var passwords: [TerminalHost.ID: String]
    private var privateKeys: [TerminalHost.ID: String]

    init(
        passwords: [TerminalHost.ID: String] = [:],
        privateKeys: [TerminalHost.ID: String] = [:]
    ) {
        self.passwords = passwords
        self.privateKeys = privateKeys
    }

    func password(for hostID: TerminalHost.ID) -> String? {
        passwords[hostID]
    }

    func privateKey(for hostID: TerminalHost.ID) -> String? {
        privateKeys[hostID]
    }

    func setPassword(_ password: String?, for hostID: TerminalHost.ID) throws {
        passwords[hostID] = password
    }

    func setPrivateKey(_ privateKey: String?, for hostID: TerminalHost.ID) throws {
        privateKeys[hostID] = privateKey
    }
}
