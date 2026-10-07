public import CmuxMobileSSH
import Foundation

/// Continues only with a pinned key and never asks: background work (the
/// Workspaces list's discovery) must not pop a trust prompt. An unknown or
/// changed key fails the handshake as `hostKeyRejected`; the user trusts a
/// host by opening it once from the Hosts tab.
public struct PinnedHostKeyVerifier: SSHHostKeyVerifier {
    private let knownHosts: any SSHKnownHostsStore

    public init(knownHosts: any SSHKnownHostsStore) { self.knownHosts = knownHosts }

    public func verify(_ key: SSHHostKey, for endpoint: SSHEndpoint) async -> Bool {
        if case .trusted = SSHHostKeyVerdict(presented: key, pinned: await knownHosts.pinnedKey(for: endpoint.hostKeyIdentity)) {
            return true
        }
        return false
    }
}
