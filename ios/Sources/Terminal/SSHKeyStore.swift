import Foundation
import Security
import CryptoKit

// MARK: - Key Pair Model

struct SSHKeyPair: Identifiable {
    let label: String
    let publicKey: Data
    let privateKey: Data
    let createdAt: Date
    let fingerprint: String

    var id: String { label }
}

// MARK: - Key Store Errors

enum SSHKeyStoreError: Error, LocalizedError {
    case keyGenerationFailed
    case keychainError(OSStatus)
    case keyNotFound(String)
    case duplicateKey(String)
    case invalidKeyData

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed: return "Failed to generate SSH key pair"
        case .keychainError(let status): return "Keychain error: \(status)"
        case .keyNotFound(let label): return "Key not found: \(label)"
        case .duplicateKey(let label): return "Key already exists: \(label)"
        case .invalidKeyData: return "Invalid key data"
        }
    }
}

// MARK: - Key Store

/// Manages SSH Ed25519 key pairs in the iOS Keychain.
struct SSHKeyStore {
    private static let service = "ai.manaflow.cmux.ssh-keys"

    /// Generate a new Ed25519 SSH key pair and store it in the Keychain.
    static func generateKeyPair(label: String) throws -> SSHKeyPair {
        if let existing = try? getKey(label: label), existing != nil {
            throw SSHKeyStoreError.duplicateKey(label)
        }

        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey

        let privateKeyData = privateKey.rawRepresentation
        let publicKeyData = publicKey.rawRepresentation
        let createdAt = Date()

        let fingerprint = Self.sha256Fingerprint(publicKeyData)

        // Store private key in Keychain
        let metadata = KeyMetadata(label: label, createdAt: createdAt, fingerprint: fingerprint)
        let metadataJSON = try JSONEncoder().encode(metadata)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: label,
            kSecValueData as String: privateKeyData,
            kSecAttrLabel as String: "cmux-ssh-\(label)",
            kSecAttrComment as String: String(data: metadataJSON, encoding: .utf8) ?? "",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SSHKeyStoreError.keychainError(status)
        }

        return SSHKeyPair(
            label: label,
            publicKey: publicKeyData,
            privateKey: privateKeyData,
            createdAt: createdAt,
            fingerprint: fingerprint
        )
    }

    /// List all stored SSH key pairs.
    static func listKeys() throws -> [SSHKeyPair] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw SSHKeyStoreError.keychainError(status)
        }

        guard let items = result as? [[String: Any]] else { return [] }

        return items.compactMap { item -> SSHKeyPair? in
            guard
                let label = item[kSecAttrAccount as String] as? String,
                let privateKeyData = item[kSecValueData as String] as? Data,
                let commentStr = item[kSecAttrComment as String] as? String,
                let commentData = commentStr.data(using: .utf8),
                let metadata = try? JSONDecoder().decode(KeyMetadata.self, from: commentData)
            else { return nil }

            let publicKeyData: Data
            do {
                let privKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
                publicKeyData = privKey.publicKey.rawRepresentation
            } catch {
                return nil
            }

            return SSHKeyPair(
                label: label,
                publicKey: publicKeyData,
                privateKey: privateKeyData,
                createdAt: metadata.createdAt,
                fingerprint: metadata.fingerprint
            )
        }
    }

    /// Get a specific key pair by label.
    static func getKey(label: String) throws -> SSHKeyPair? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: label,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw SSHKeyStoreError.keychainError(status)
        }

        guard
            let item = result as? [String: Any],
            let privateKeyData = item[kSecValueData as String] as? Data,
            let commentStr = item[kSecAttrComment as String] as? String,
            let commentData = commentStr.data(using: .utf8),
            let metadata = try? JSONDecoder().decode(KeyMetadata.self, from: commentData)
        else {
            throw SSHKeyStoreError.invalidKeyData
        }

        let privKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)

        return SSHKeyPair(
            label: label,
            publicKey: privKey.publicKey.rawRepresentation,
            privateKey: privateKeyData,
            createdAt: metadata.createdAt,
            fingerprint: metadata.fingerprint
        )
    }

    /// Delete a key pair from the Keychain.
    static func deleteKey(label: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: label,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SSHKeyStoreError.keychainError(status)
        }
    }

    /// Format the public key in OpenSSH authorized_keys format.
    /// Output: `ssh-ed25519 <base64> <label>`
    static func publicKeyOpenSSH(_ keyPair: SSHKeyPair) -> String {
        // OpenSSH wire format for Ed25519:
        // [4 bytes: length of key type] [key type: "ssh-ed25519"]
        // [4 bytes: length of public key] [32 bytes: public key]
        let keyType = "ssh-ed25519"
        let keyTypeData = keyType.data(using: .utf8)!

        var wireFormat = Data()
        wireFormat.appendSSHString(keyTypeData)
        wireFormat.appendSSHString(keyPair.publicKey)

        let base64 = wireFormat.base64EncodedString()
        return "\(keyType) \(base64) \(keyPair.label)"
    }

    // MARK: - Private

    private static func sha256Fingerprint(_ publicKey: Data) -> String {
        let hash = SHA256.hash(data: publicKey)
        let base64 = Data(hash).base64EncodedString()
        return "SHA256:\(base64)"
    }
}

// MARK: - Helpers

private struct KeyMetadata: Codable {
    let label: String
    let createdAt: Date
    let fingerprint: String
}

private extension Data {
    mutating func appendSSHString(_ data: Data) {
        var length = UInt32(data.count).bigEndian
        append(Data(bytes: &length, count: 4))
        append(data)
    }
}
