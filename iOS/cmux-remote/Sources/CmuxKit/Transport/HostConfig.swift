public import Foundation

/// One configured remote cmux host.
///
/// The credentials field is **not** encoded — it's resolved at use-time from
/// the Keychain via `CmuxCredentialResolver` so this struct itself can be
/// persisted to UserDefaults / an App Group plist without leaking secrets.
public struct CmuxHost: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public var label: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var authMethod: AuthMethodKind
    public var serverFingerprintPin: String?
    public var cmuxBinaryPath: String
    public var preferRemoteSocketPath: String?

    public enum AuthMethodKind: String, Hashable, Codable, Sendable {
        case ed25519Key = "ed25519"
        case ecdsaP256Key = "ecdsa-p256"
        case rsaKey = "rsa"
        case password
    }

    public init(
        id: UUID = UUID(),
        label: String,
        hostname: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethodKind,
        serverFingerprintPin: String? = nil,
        cmuxBinaryPath: String = "cmux",
        preferRemoteSocketPath: String? = nil
    ) {
        self.id = id
        self.label = label
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.serverFingerprintPin = serverFingerprintPin
        self.cmuxBinaryPath = cmuxBinaryPath
        self.preferRemoteSocketPath = preferRemoteSocketPath
    }
}

/// Resolved credential ready to hand to Citadel. Lifetime is bounded to one
/// connection attempt — never persist these.
public struct CmuxResolvedCredential: Sendable {
    public enum Material: Sendable {
        case password(String)
        case ed25519PrivateKey(Data)
        case ecdsaP256PrivateKey(Data)
        case rsaPrivateKey(Data)
        case secureEnclaveSigner(any SecureEnclaveSigner)
    }

    public let username: String
    public let material: Material

    public init(username: String, material: Material) {
        self.username = username
        self.material = material
    }
}

/// A signer wrapper for Secure Enclave–backed ECDSA P-256 keys. The actual
/// signing happens in-Enclave via `SecKeyCreateSignature`; this protocol lets
/// the SSH transport delegate signature production without needing to know
/// the private key bytes.
public protocol SecureEnclaveSigner: Sendable {
    /// SSH ed25519 / ecdsa public-key blob, ready to embed in a public-key
    /// auth packet.
    var publicKeyBlob: Data { get }
    /// Sign a challenge bytes blob — Citadel handles framing.
    func sign(_ data: Data) async throws -> Data
}
