public import CmuxiOSFeatureKit
import Foundation

/// The list's client view state on this device (OWNERSHIP-PRINCIPLES:
/// client-owned, never synced): filter, sort, grouping, hidden machines and
/// machine order.
public struct WorkspaceViewPreferences: Codable, Hashable, Sendable {
    public var filter: WorkspaceListFilter
    public var sort: WorkspaceListSort
    public var grouping: WorkspaceListGrouping
    public var hiddenHosts: Set<HostID>
    /// Machines in the user's order; machines not listed follow in the
    /// directory's order.
    public var hostOrder: [HostID]

    public init(
        filter: WorkspaceListFilter = .all, sort: WorkspaceListSort = .ownerOrder,
        grouping: WorkspaceListGrouping = .byMachine, hiddenHosts: Set<HostID> = [], hostOrder: [HostID] = []
    ) {
        self.filter = filter
        self.sort = sort
        self.grouping = grouping
        self.hiddenHosts = hiddenHosts
        self.hostOrder = hostOrder
    }

    /// `hosts` in the user's machine order.
    public func ordered<T>(_ hosts: [T], id: (T) -> HostID) -> [T] {
        let rank = Dictionary(hostOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return hosts.enumerated().sorted { a, b in
            let ra = rank[id(a.element)] ?? Int.max
            let rb = rank[id(b.element)] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// Moves a machine to `index` among `visibleOrder` (the machines as the
    /// user sees them now) and records the full order.
    public mutating func move(_ host: HostID, to index: Int, in visibleOrder: [HostID]) {
        var next = visibleOrder.filter { $0 != host }
        next.insert(host, at: min(max(0, index), next.count))
        hostOrder = next + hostOrder.filter { !next.contains($0) }
    }
}
