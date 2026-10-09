import Foundation

/// How this device logs in to a host. Device state: a key id names a
/// Keychain item that never leaves this device, so it is never synced.
public enum SSHHostAuth: Hashable, Sendable, Codable {
    /// A key from `SSHKeyStore` (generated Ed25519, Secure Enclave or imported).
    case key(UUID)
    /// A password kept in the Keychain (`SSHSecretVault`).
    case password
    /// Not chosen yet; connecting asks the user to pick.
    case unset
}
