public import CmuxMobileSSH
import Foundation

/// Trust on first use: a pinned key continues silently, an unknown key is
/// asked once and pinned on trust, and a changed key stops with a warning
/// unless the user replaces the pin.
public struct TOFUHostKeyVerifier: SSHHostKeyVerifier {
    private let knownHosts: any SSHKnownHostsStore
    private let prompter: any SSHTrustPrompter
    /// Display names by `SSHEndpoint.hostKeyIdentity` (jump hops included).
    private let names: [String: String]

    public init(knownHosts: any SSHKnownHostsStore, prompter: any SSHTrustPrompter, names: [String: String] = [:]) {
        self.knownHosts = knownHosts
        self.prompter = prompter
        self.names = names
    }

    public func verify(_ key: SSHHostKey, for endpoint: SSHEndpoint) async -> Bool {
        let identity = endpoint.hostKeyIdentity
        let name = names[identity] ?? endpoint.host
        let question: SSHTrustQuestion
        switch SSHHostKeyVerdict(presented: key, pinned: await knownHosts.pinnedKey(for: identity)) {
        case .trusted:
            return true
        case .unknown(let presented):
            question = .unknown(hostName: name, identity: identity, presented: presented)
        case .changed(let pinned, let presented):
            question = .changed(hostName: name, identity: identity, pinned: pinned, presented: presented)
        }
        guard await prompter.decide(question) == .trust else { return false }
        await knownHosts.pin(key, for: identity)
        return true
    }
}
