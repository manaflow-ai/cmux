public import CmuxMobileSSH
public import Foundation

/// Everything SSH keeps on this device and never syncs: per-host login
/// settings, keys, passwords and pinned host keys. Built once by the app's
/// composition root; independent of the signed-in account, so SSH can work
/// before sign-in once deferred sign-in lands (lane C16).
public struct SSHDeviceState: Sendable {
    public let settings: SSHHostSettingsStore
    public let keys: SSHKeyStore
    public let vault: any SSHSecretVault
    public let knownHosts: SSHKnownHostsFile

    public init(settings: SSHHostSettingsStore, keys: SSHKeyStore, vault: any SSHSecretVault, knownHosts: SSHKnownHostsFile) {
        self.settings = settings
        self.keys = keys
        self.vault = vault
        self.knownHosts = knownHosts
    }

    /// The stores under `directory` (Application Support/ssh) and the Keychain.
    public init(directory: URL) {
        self.init(
            settings: SSHHostSettingsStore(url: directory.appendingPathComponent("host-settings.json")),
            keys: SSHKeyStore(directory: directory, keychainService: "dev.cmux.ios.ssh.keys"),
            vault: KeychainSecretVault(),
            knownHosts: SSHKnownHostsFile(url: directory.appendingPathComponent("known_hosts"))
        )
    }

    public var credentials: SSHCredentialResolver {
        SSHCredentialResolver(settings: settings, keys: keys, vault: vault)
    }
}
