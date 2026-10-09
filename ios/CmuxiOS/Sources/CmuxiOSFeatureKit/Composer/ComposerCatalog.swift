import Foundation

/// Everything the composer pickers offer.
public struct ComposerCatalog: Hashable, Sendable {
    public var hosts: [HostWorkspaces]
    /// Agents offered everywhere (mocks, or a host without its own list).
    public var agents: [ComposerAgent]
    /// Agents each Mac advertises (`task:<host>`); wins over `agents`.
    public var agentsByHost: [HostID: [ComposerAgent]]
    /// Macs that accept `task.dispatch` right now (cap negotiated, gate on).
    /// Nil means every reachable host does (mocks).
    public var dispatchHosts: Set<HostID>?

    public init(hosts: [HostWorkspaces], agents: [ComposerAgent], agentsByHost: [HostID: [ComposerAgent]] = [:],
                dispatchHosts: Set<HostID>? = nil) {
        self.hosts = hosts
        self.agents = agents
        self.agentsByHost = agentsByHost
        self.dispatchHosts = dispatchHosts
    }

    public func agents(on host: HostID) -> [ComposerAgent] { agentsByHost[host] ?? agents }

    public func host(_ id: HostID) -> HostWorkspaces? { hosts.first { $0.hostID == id } }

    public func acceptsDispatch(_ host: HostID) -> Bool { dispatchHosts?.contains(host) ?? true }
}
