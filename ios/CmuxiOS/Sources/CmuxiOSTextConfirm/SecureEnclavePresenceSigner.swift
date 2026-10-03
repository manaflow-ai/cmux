public import CmuxTextConfirmCore
import CryptoKit
public import Foundation
import LocalAuthentication
import Security

/// The presence key: a Secure Enclave P-256 key whose use needs Face ID,
/// Touch ID or the device passcode (user presence), separate from the
/// install key. The enclave's key blob is kept in the Keychain (this device
/// only); the private key never leaves the enclave.
public struct SecureEnclavePresenceSigner: PresenceSigner {
    public enum Failure: Error { case secureEnclaveUnavailable, accessControl, alreadyExists, keychain(OSStatus) }

    private let service: String
    private let reason: String

    public init(bundleID: String, reason: String) {
        service = "\(bundleID).presence-key"
        self.reason = reason
    }

    /// True once this device has a presence key.
    public var exists: Bool { (try? readBlob()) != nil }

    /// The public point (X9.63) of the existing key; no Face ID needed.
    public func publicKey() throws -> Data? {
        guard let blob = try readBlob() else { return nil }
        return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob).publicKey.x963Representation
    }

    /// Creates the key (first run). Refuses when one exists: replacing a
    /// registered key needs a revoke and a new registration first.
    public func create() throws -> Data {
        guard SecureEnclave.isAvailable else { throw Failure.secureEnclaveUnavailable }
        guard try readBlob() == nil else { throw Failure.alreadyExists }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &error) else {
            throw Failure.accessControl
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        try writeBlob(key.dataRepresentation)
        return key.publicKey.x963Representation
    }

    /// Signs the exact bytes; the system shows the Face ID or passcode prompt.
    public func sign(_ message: Data) async throws -> Data {
        guard let blob = try readBlob() else { throw Failure.keychain(errSecItemNotFound) }
        let context = LAContext()
        context.localizedReason = reason
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
        return try key.signature(for: message).rawRepresentation
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "presence-key"]
    }

    private func readBlob() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return out as? Data
    }

    private func writeBlob(_ data: Data) throws {
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }
}
