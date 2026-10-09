public import CmuxiOSFeatureKit
import Foundation

/// Where host passwords live. The only implementation that ships is the
/// Keychain (`KeychainSecretVault`); tests use an in-memory one. A vault
/// never logs or describes its values.
public protocol SSHSecretVault: Sendable {
    func password(for host: HostID) async throws -> String?
    func setPassword(_ password: String, for host: HostID) async throws
    func removePassword(for host: HostID) async throws
}
