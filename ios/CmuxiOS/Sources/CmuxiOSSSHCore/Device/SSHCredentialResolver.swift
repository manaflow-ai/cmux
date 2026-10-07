public import CmuxiOSFeatureKit
public import CmuxMobileSSH
import Foundation

/// Builds the credentials one host logs in with from device state: its
/// `SSHHostSettings`, the key store and the password vault.
public struct SSHCredentialResolver: Sendable {
    private let settings: SSHHostSettingsStore
    private let keys: any SSHKeyProviding
    private let vault: any SSHSecretVault

    public init(settings: SSHHostSettingsStore, keys: any SSHKeyProviding, vault: any SSHSecretVault) {
        self.settings = settings
        self.keys = keys
        self.vault = vault
    }

    public func credentials(for host: HostID) async throws -> [SSHCredential] {
        switch await settings.settings(for: host).auth {
        case .key(let id):
            do {
                return [try await keys.credential(for: id)]
            } catch {
                throw SSHSessionFailure.missingCredentials
            }
        case .password:
            guard let password = try? await vault.password(for: host), !password.isEmpty else {
                throw SSHSessionFailure.missingCredentials
            }
            return [.password(password)]
        case .unset:
            throw SSHSessionFailure.missingCredentials
        }
    }
}
