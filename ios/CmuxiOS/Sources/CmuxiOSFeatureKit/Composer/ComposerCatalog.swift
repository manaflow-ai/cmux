import Foundation

/// Everything the composer pickers offer.
public struct ComposerCatalog: Hashable, Sendable {
    public var hosts: [HostWorkspaces]
    public var agents: [ComposerAgent]

    public init(hosts: [HostWorkspaces], agents: [ComposerAgent]) {
        self.hosts = hosts
        self.agents = agents
    }
}
