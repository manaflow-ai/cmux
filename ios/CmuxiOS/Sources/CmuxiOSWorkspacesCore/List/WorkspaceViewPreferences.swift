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
    /// Group sections collapsed on this phone (`<host>/<group>`), E3.
    public var collapsedGroups: Set<String>

    public init(
        filter: WorkspaceListFilter = .all, sort: WorkspaceListSort = .ownerOrder,
        grouping: WorkspaceListGrouping = .byMachine, hiddenHosts: Set<HostID> = [], hostOrder: [HostID] = [],
        collapsedGroups: Set<String> = []
    ) {
        self.filter = filter
        self.sort = sort
        self.grouping = grouping
        self.hiddenHosts = hiddenHosts
        self.hostOrder = hostOrder
        self.collapsedGroups = collapsedGroups
    }

    enum CodingKeys: String, CodingKey {
        case filter, sort, grouping, hiddenHosts, hostOrder, collapsedGroups
    }

    /// Decodes what older builds saved (no `collapsedGroups`) as well.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filter = try c.decode(WorkspaceListFilter.self, forKey: .filter)
        sort = try c.decode(WorkspaceListSort.self, forKey: .sort)
        grouping = try c.decode(WorkspaceListGrouping.self, forKey: .grouping)
        hiddenHosts = try c.decode(Set<HostID>.self, forKey: .hiddenHosts)
        hostOrder = try c.decode([HostID].self, forKey: .hostOrder)
        collapsedGroups = try c.decodeIfPresent(Set<String>.self, forKey: .collapsedGroups) ?? []
    }

    /// The key of a group section in `collapsedGroups`.
    public static func groupKey(host: HostID, group: String) -> String { host.rawValue + "/" + group }

    public func isCollapsed(host: HostID, group: String) -> Bool {
        collapsedGroups.contains(Self.groupKey(host: host, group: group))
    }

    public mutating func toggleCollapsed(host: HostID, group: String) {
        let key = Self.groupKey(host: host, group: group)
        if collapsedGroups.remove(key) == nil { collapsedGroups.insert(key) }
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
