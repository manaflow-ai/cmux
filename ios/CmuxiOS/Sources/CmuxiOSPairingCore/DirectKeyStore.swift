public import Foundation

/// Holds this install's X25519 `direct` key (B4's device static key). The
/// private key never leaves the device and is never synced.
public protocol DirectKeyStore: Sendable {
    /// The private key's raw representation, made on first use.
    func privateKey() throws -> Data
    /// The matching raw 32-byte public key.
    func publicKey() throws -> Data
    /// Replaces the key (rotation); the next publish signs the new one.
    func rotate() throws
}
