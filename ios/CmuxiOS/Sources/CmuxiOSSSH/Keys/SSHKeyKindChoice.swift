import Foundation

/// Which key to generate.
enum SSHKeyKindChoice: String, CaseIterable, Hashable, Sendable {
    /// Ed25519 in the Keychain: every server accepts it.
    case ed25519
    /// P-256 in the Secure Enclave: never leaves the device.
    case secureEnclave
}
