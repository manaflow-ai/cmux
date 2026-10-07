import Foundation

/// A `WorkspaceSource` over two sample Macs. The unreachable Mac refuses
/// every intent, as a real owner that is asleep would be unreachable.
public final class MockWorkspaceSource: WorkspaceSource {
    public let hub: MockSnapshotHub<[HostWorkspaces]>

    public init(hosts: [HostWorkspaces] = MockFixtures.hostWorkspaces()) {
        hub = MockSnapshotHub(hosts)
    }

    public func updates() async -> AsyncStream<SourceSnapshot<[HostWorkspaces]>> {
        await hub.stream()
    }

    public func perform(_ intent: WorkspaceIntent, key: IntentKey) async throws -> IntentReceipt {
        try await hub.receipt(for: key) { hosts in try Self.apply(intent, key: key, to: &hosts) }
    }

    private static func apply(_ intent: WorkspaceIntent, key: IntentKey, to hosts: inout [HostWorkspaces]) throws {
        switch intent {
        case .create(let hostID, let title):
            guard let host = hosts.firstIndex(where: { $0.hostID == hostID }) else { throw MockRefusal("Unknown host") }
            guard hosts[host].isReachable else { throw MockRefusal("Host unreachable") }
            hosts[host].workspaces.append(WorkspaceSummary(
                id: "ws_" + key.rawValue.prefix(8), hostID: hostID, title: title ?? "workspace",
                status: .idle, paneCount: 1, lastActivity: Date(),
                order: (hosts[host].workspaces.map(\.order).max() ?? -1) + 1))
        case .rename(let workspaceID, let title):
            let (host, index) = try locate(workspaceID, in: hosts)
            hosts[host].workspaces[index].title = title
        case .close(let workspaceID):
            let (host, index) = try locate(workspaceID, in: hosts)
            hosts[host].workspaces.remove(at: index)
        case .markRead(let workspaceID):
            let (host, index) = try locate(workspaceID, in: hosts)
            hosts[host].workspaces[index].unreadCount = 0
            for pane in hosts[host].workspaces[index].panes.indices {
                for surface in hosts[host].workspaces[index].panes[pane].surfaces.indices {
                    hosts[host].workspaces[index].panes[pane].surfaces[surface].unreadCount = 0
                }
            }
        }
    }

    /// The host and row of a workspace on a reachable host.
    private static func locate(_ id: WorkspaceSummary.ID, in hosts: [HostWorkspaces]) throws -> (Int, Int) {
        for (hostIndex, host) in hosts.enumerated() {
            guard let index = host.workspaces.firstIndex(where: { $0.id == id }) else { continue }
            guard host.isReachable else { throw MockRefusal("Host unreachable") }
            return (hostIndex, index)
        }
        throw MockRefusal("Unknown workspace")
    }
}
