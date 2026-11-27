public import CmuxInstallAuthCore
import CryptoKit
public import Foundation
import Security

/// The install key in the Secure Enclave. Only the enclave's encrypted key
/// blob is stored (Keychain, this device only); the private key never leaves
/// the enclave. The key is usable after first unlock (a locked phone can
/// still answer Deny from a banner); no user-presence prompt.
public struct SecureEnclaveInstallSigner: InstallSigner {
    public enum Failure: Error { case secureEnclaveUnavailable, keychain(OSStatus) }

    private let service: String

    /// One key per (bundle, API environment).
    public init(bundleID: String, environment: String) {
        service = "\(bundleID).install-key.\(environment)"
    }

    public func publicKeyX963() async throws -> Data { try key().publicKeyX963 }

    public func sign(_ message: Data) async throws -> Data { try key().sign(message) }

    /// Destroys the key; the next use makes a new one.
    public func rotate() async throws { destroy() }

    /// Deletes the key (sign-out of the last account is not a reason; a
    /// reset of the app's data is).
    public func destroy() { _ = SecItemDelete(query() as CFDictionary) }

    private func key() throws -> AnyInstallKey {
        if SecureEnclave.isAvailable {
            if let blob = try read() { return .enclave(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)) }
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error) else {
                throw Failure.keychain(errSecParam)
            }
            let made = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            try write(made.dataRepresentation)
            return .enclave(made)
        }
        #if DEBUG
        // DEBUG ONLY (the simulator has no Secure Enclave): a software key in the
        // Keychain. Release builds never take this path; they refuse instead.
        if let raw = try read() { return .software(try P256.Signing.PrivateKey(rawRepresentation: raw)) }
        let made = P256.Signing.PrivateKey()
        try write(made.rawRepresentation)
        return .software(made)
        #else
        throw Failure.secureEnclaveUnavailable
        #endif
    }

    private func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "install-key"]
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

private enum AnyInstallKey {
    case enclave(SecureEnclave.P256.Signing.PrivateKey)
    case software(P256.Signing.PrivateKey)

    var publicKeyX963: Data {
        switch self {
        case .enclave(let key): key.publicKey.x963Representation
        case .software(let key): key.publicKey.x963Representation
        }
    }

    /// Raw r||s (64 bytes).
    func sign(_ message: Data) throws -> Data {
        switch self {
        case .enclave(let key): try key.signature(for: message).rawRepresentation
        case .software(let key): try key.signature(for: message).rawRepresentation
        }
    }
}
