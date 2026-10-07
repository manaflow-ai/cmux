public import CmuxiOSFeatureKit
import Foundation

/// Builds the list from the seam's hosts and the view preferences. Pure:
/// the same input gives the same sections with the same ids, so the screen
/// only diffs (c5-workspaces.md section 6).
public struct WorkspaceListBuilder: Sendable {
    public var preferences: WorkspaceViewPreferences

    public init(preferences: WorkspaceViewPreferences) {
        self.preferences = preferences
    }

    /// `hosts == nil` means no snapshot has arrived yet.
    public func snapshot(for hosts: [HostWorkspaces]?) -> WorkspaceListSnapshot {
        guard let hosts else { return WorkspaceListSnapshot(sections: [], emptyState: .loading, allOffline: false) }
        guard !hosts.isEmpty else { return WorkspaceListSnapshot(sections: [], emptyState: .noMachines, allOffline: false) }
        let visible = preferences.ordered(hosts, id: \.hostID).filter { !preferences.hiddenHosts.contains($0.hostID) }
        guard !visible.isEmpty else { return WorkspaceListSnapshot(sections: [], emptyState: .allHidden, allOffline: false) }
        let allOffline = !visible.contains(where: \.isReachable)
        let sections: [WorkspaceListSection]
        switch preferences.grouping {
        case .byMachine: sections = visible.flatMap(machineSections)
        case .flat: sections = flatSection(visible)
        }
        var empty: WorkspaceListEmptyState?
        if sections.allSatisfy({ $0.rows.isEmpty }) {
            let hasWorkspaces = visible.contains { !$0.workspaces.isEmpty }
            if preferences.filter != .all && hasWorkspaces {
                empty = .filterEmpty(preferences.filter)
            } else if preferences.grouping == .flat {
                empty = .noWorkspaces
            }
        }
        return WorkspaceListSnapshot(sections: empty == nil ? sections : [], emptyState: empty, allOffline: allOffline)
    }

    // MARK: Sections

    private func machineSections(_ host: HostWorkspaces) -> [WorkspaceListSection] {
        let rows = sorted(host.workspaces.filter(matches)).map { row($0, host: host) }
        let header = machineHeader(host)
        let base = "host:" + host.hostID.rawValue
        if rows.isEmpty {
            // With a filter, a machine with nothing matching is left out.
            guard preferences.filter == .all else { return [] }
            return [WorkspaceListSection(id: base + "/empty", hostID: host.hostID, machine: header, kind: .empty, rows: [])]
        }
        var sections: [WorkspaceListSection] = []
        let pinned = rows.filter(\.isPinned)
        if !pinned.isEmpty {
            sections.append(WorkspaceListSection(id: base + "/pinned", hostID: host.hostID, machine: nil, kind: .pinned, rows: pinned))
        }
        let unpinned = rows.filter { !$0.isPinned }
        let groupOf = Dictionary(host.workspaces.compactMap { w in w.group.map { (w.id, $0.id) } },
                                 uniquingKeysWith: { first, _ in first })
        var groupOrder: [WorkspaceGroup] = []
        for workspace in host.workspaces.sorted(by: { $0.order < $1.order }) {
            if let group = workspace.group, !groupOrder.contains(where: { $0.id == group.id }) { groupOrder.append(group) }
        }
        for group in groupOrder {
            let members = unpinned.filter { groupOf[$0.workspaceID] == group.id }
            guard !members.isEmpty else { continue }
            sections.append(WorkspaceListSection(
                id: base + "/group:" + group.id, hostID: host.hostID, machine: nil, kind: .group(group.name), rows: members))
        }
        let rest = unpinned.filter { groupOf[$0.workspaceID] == nil }
        if !rest.isEmpty {
            sections.append(WorkspaceListSection(id: base + "/all", hostID: host.hostID, machine: nil, kind: .workspaces, rows: rest))
        }
        sections[0].machine = header
        return sections
    }

    private func flatSection(_ hosts: [HostWorkspaces]) -> [WorkspaceListSection] {
        let pairs = hosts.flatMap { host in host.workspaces.filter(matches).map { (host, $0) } }
        let ordered: [(HostWorkspaces, WorkspaceSummary)]
        switch preferences.sort {
        case .ownerOrder:
            // Machine order, then each machine's own order.
            ordered = hosts.flatMap { host in sorted(host.workspaces.filter(matches)).map { (host, $0) } }
        case .recentActivity, .name:
            ordered = pairs.sorted { compare($0.1, $1.1) }
        }
        return [WorkspaceListSection(id: "flat", hostID: nil, machine: nil, kind: .flat,
                                     rows: ordered.map { row($1, host: $0) })]
    }

    // MARK: Rows

    private func matches(_ workspace: WorkspaceSummary) -> Bool {
        switch preferences.filter {
        case .all: true
        case .unread: workspace.unreadCount > 0
        case .needsInput: workspace.status == .waitingForInput
        case .running: workspace.status == .running
        }
    }

    private func sorted(_ workspaces: [WorkspaceSummary]) -> [WorkspaceSummary] {
        workspaces.sorted(by: compare)
    }

    private func compare(_ a: WorkspaceSummary, _ b: WorkspaceSummary) -> Bool {
        switch preferences.sort {
        case .ownerOrder:
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.order != b.order ? a.order < b.order : a.id < b.id
        case .recentActivity:
            switch (a.lastActivity, b.lastActivity) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.order != b.order ? a.order < b.order : a.id < b.id
            }
        case .name:
            let result = a.title.localizedStandardCompare(b.title)
            return result != .orderedSame ? result == .orderedAscending : a.id < b.id
        }
    }

    private func row(_ workspace: WorkspaceSummary, host: HostWorkspaces) -> WorkspaceListRow {
        WorkspaceListRow(
            id: host.hostID.rawValue + "/" + workspace.id, hostID: host.hostID, workspaceID: workspace.id,
            title: workspace.title, preview: workspace.preview, status: workspace.status,
            unreadCount: workspace.unreadCount, machineName: host.hostName,
            machineColor: MachineColor(hostID: host.hostID), isReachable: host.isReachable,
            isPinned: workspace.isPinned, lastActivity: workspace.lastActivity,
            capabilities: host.capabilities, paneCount: workspace.paneCount)
    }

    private func machineHeader(_ host: HostWorkspaces) -> WorkspaceMachineHeader {
        WorkspaceMachineHeader(
            hostID: host.hostID, name: host.hostName, kind: host.kind, color: MachineColor(hostID: host.hostID),
            isReachable: host.isReachable, offlineReason: host.offlineReason, isResyncing: host.isResyncing,
            workspaceCount: host.workspaces.count,
            unreadCount: host.workspaces.reduce(0) { $0 + $1.unreadCount })
    }
}
