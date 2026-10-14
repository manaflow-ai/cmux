import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The phone's two Secure Enclave P-256 keys (verify/phone-approvals.md).
///
/// - `identity` signs each link's pairing challenge with no prompt: it proves
///   this is the phone the Mac allowed, so a Stack token alone reaches nothing.
/// - `approval` signs an Allow or an answer for an agent, and every signature
///   needs the user: Face ID, or the device passcode when Face ID fails or is
///   not set up (`.userPresence`). acpmux on the Mac checks it.
///
/// Only the enclave's encrypted key blobs are stored (Keychain, this device
/// only); a private key never leaves the enclave. The simulator has no
/// enclave, so DEBUG builds there use software keys and ask for Face ID with
/// an explicit `LAContext` check (`xcrun simctl` can match it). Release builds
/// without an enclave have no keys: the phone stays deny-only and unpaired.
public final class PhoneKeys: @unchecked Sendable { // crash-allow: immutable after init except the lock-guarded cache
    public enum Failure: Error, Equatable {
        case unavailable
        case keychain(OSStatus)
        /// The user cancelled Face ID and the passcode.
        case cancelled
    }

    private let service: String
    private let lock = NSLock()
    private var cached: (identity: AnyKey, approval: AnyKey)?

    /// One key pair per bundle (a Demo and a Production install never share keys).
    public init(service: String = (Bundle.main.bundleIdentifier ?? "dev.cmux.cnx") + ".phone-keys") {
        self.service = service
    }

    /// X9.63 (65-byte uncompressed) points as lowercase hex.
    public func publicKeys() throws -> (identity: String, approval: String) {
        let keys = try load()
        return (Self.hex(keys.identity.publicKey), Self.hex(keys.approval.publicKey))
    }

    /// Raw `r || s` over `message` with the identity key; no prompt.
    public func signIdentity(_ message: Data) throws -> Data {
        try load().identity.sign(message, context: nil)
    }

    /// Raw `r || s` over `message` with the approval key, after Face ID (or the
    /// passcode). `reason` is the line the system sheet shows.
    public func signApproval(_ message: Data, reason: String) async throws -> Data {
        let key = try load().approval
        let context = LAContext()
        context.localizedFallbackTitle = nil
        do {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel, .userFallback].contains(error.code) {
            throw Failure.cancelled
        }
        return try key.sign(message, context: context)
    }

    /// Sign-out: deletes both keys; the next link makes new ones (and asks the Mac again).
    public func reset() {
        lock.withLock { cached = nil }
        for account in ["identity", "approval"] {
            SecItemDelete(query(account) as CFDictionary)
        }
    }

    // MARK: Storage

    private func load() throws -> (identity: AnyKey, approval: AnyKey) {
        try lock.withLock {
            if let cached { return cached }
            let keys = (identity: try key("identity", presence: false), approval: try key("approval", presence: true))
            cached = keys
            return keys
        }
    }

    private func key(_ account: String, presence: Bool) throws -> AnyKey {
        if SecureEnclave.isAvailable {
            if let blob = try read(account) {
                return .enclave(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob))
            }
            var error: Unmanaged<CFError>?
            let flags: SecAccessControlCreateFlags = presence ? [.privateKeyUsage, .userPresence] : .privateKeyUsage
            let protection = presence ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard let access = SecAccessControlCreateWithFlags(nil, protection, flags, &error) else {
                throw Failure.keychain(errSecParam)
            }
            let made = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            try write(account, made.dataRepresentation)
            return .enclave(made)
        }
        #if DEBUG
        // DEBUG ONLY (the simulator has no Secure Enclave): a software key in the
        // Keychain; `signApproval` still asks for Face ID first.
        if let raw = try read(account) { return .software(try P256.Signing.PrivateKey(rawRepresentation: raw)) }
        let made = P256.Signing.PrivateKey()
        try write(account, made.rawRepresentation)
        return .software(made)
        #else
        throw Failure.unavailable
        #endif
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func read(_ account: String) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return out as? Data
    }

    private func write(_ account: String, _ data: Data) throws {
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

private enum AnyKey {
    case enclave(SecureEnclave.P256.Signing.PrivateKey)
    case software(P256.Signing.PrivateKey)

    var publicKey: Data {
        switch self {
        case .enclave(let key): key.publicKey.x963Representation
        case .software(let key): key.publicKey.x963Representation
        }
    }

    /// Raw r||s (64 bytes). An enclave key with user presence uses the already
    /// evaluated `context`, so the user sees one prompt.
    func sign(_ message: Data, context: LAContext?) throws -> Data {
        switch self {
        case .enclave(let key):
            if let context {
                let bound = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: key.dataRepresentation,
                                                                      authenticationContext: context)
                return try bound.signature(for: message).rawRepresentation
            }
            return try key.signature(for: message).rawRepresentation
        case .software(let key):
            return try key.signature(for: message).rawRepresentation
        }
    }
}
