import CnxModel
import Foundation
import Observation

/// Which Macs the Workspaces list shows: every Mac in the team, grouped by
/// Mac, or one Mac, ungrouped.
public enum MacScope: Hashable, Sendable {
    case all
    case mac(String)

    public var macID: String? {
        if case let .mac(id) = self { id } else { nil }
    }
}

/// The Workspaces list's Mac filter, remembered per team. A Mac that has
/// left the team (or was never in it) reads as All Macs.
@MainActor
@Observable
public final class MacFilter {
    /// By team id; only teams this device has chosen a Mac for.
    private var scopes: [String: MacScope] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    static let keyPrefix = "cnx.workspaces.macFilter."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ teamID: String) -> String { Self.keyPrefix + teamID }

    /// The stored scope for a team, resolved against its current Macs.
    public func scope(in team: Team?) -> MacScope {
        guard let team else { return .all }
        let stored = scopes[team.id] ?? defaults.string(forKey: key(team.id)).map(MacScope.mac) ?? .all
        return Self.resolve(stored, macs: team.macs)
    }

    public func select(_ scope: MacScope, in teamID: String) {
        scopes[teamID] = scope
        if let id = scope.macID {
            defaults.set(id, forKey: key(teamID))
        } else {
            defaults.removeObject(forKey: key(teamID))
        }
    }

    /// A Mac scope whose Mac is gone falls back to All Macs.
    public nonisolated static func resolve(_ scope: MacScope, macs: [MacDevice]) -> MacScope {
        guard let id = scope.macID else { return .all }
        return macs.contains { $0.id == id } ? scope : .all
    }
}

/// One group of the list: a Mac and its workspaces, already sorted.
public struct MacSection: Identifiable, Hashable, Sendable {
    public var mac: MacDevice
    public var workspaces: [Workspace]
    public var id: String { mac.id }
}

/// What the list shows for a scope, computed from the store.
public struct WorkspaceListLayout: Hashable, Sendable {
    public var scope: MacScope
    public var sections: [MacSection]

    /// Sections with headers (All Macs); one Mac shows a flat list.
    public var isGrouped: Bool { scope == .all }

    /// - All Macs: one section per Mac, online Macs first in team order;
    ///   offline Macs only when `showsOffline`.
    /// - One Mac: just that Mac, online or not (an explicit choice wins over
    ///   Show Offline Macs).
    public init(scope: MacScope, macs: [MacDevice], workspaces: [Workspace], sort: WorkspaceSort, showsOffline: Bool) {
        let scope = MacFilter.resolve(scope, macs: macs)
        self.scope = scope
        let chosen: [MacDevice]
        if let id = scope.macID {
            chosen = macs.filter { $0.id == id }
        } else {
            chosen = macs.filter(\.isOnline) + macs.filter { !$0.isOnline && showsOffline }
        }
        sections = chosen.map { mac in
            MacSection(mac: mac, workspaces: sort.ordered(workspaces.filter { $0.macID == mac.id }))
        }
    }

    public var isEmpty: Bool { sections.allSatisfy(\.workspaces.isEmpty) }
}

extension MacScope {
    /// The list's title: "All Macs" or the Mac's name.
    public func title(macs: [MacDevice]) -> String {
        guard let id = macID, let mac = macs.first(where: { $0.id == id }) else { return "All Macs" }
        return mac.name
    }

    /// The Mac New Workspace targets: the filtered Mac (nil while it cannot
    /// take one, e.g. offline), else the creator's preferred or only Mac.
    public func newWorkspaceMac(available: [MacDevice], fallback: MacDevice?) -> MacDevice? {
        if let id = macID { return available.first { $0.id == id } }
        return fallback
    }
}

/// The row's tab-kind summary: agents, terminals, browsers, with counts.
public struct TabKindSummary: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public var kind: WorkspaceTab.Kind
        public var count: Int
    }

    public var entries: [Entry]

    public init(_ tabs: [WorkspaceTab]) {
        let order: [WorkspaceTab.Kind] = [.agent, .terminal, .browser]
        entries = order.compactMap { kind in
            let count = tabs.count(where: { $0.kind == kind })
            return count > 0 ? Entry(kind: kind, count: count) : nil
        }
    }

    /// "2 agents, 1 terminal" for VoiceOver.
    public var spoken: String {
        entries.map { entry in
            let noun = switch entry.kind {
            case .agent: "agent"
            case .terminal: "terminal"
            case .browser: "browser tab"
            }
            return "\(entry.count) \(noun)\(entry.count == 1 ? "" : "s")"
        }.joined(separator: ", ")
    }
}

/// The row's third line: what the workspace is doing.
public enum WorkspaceActivity: Hashable, Sendable {
    /// An agent waits for the user.
    case needsYou(agent: String?, detail: String?)
    /// An agent is working.
    case working(agent: String?, detail: String?)
    /// Nothing running; the most relevant tab's subtitle, if any.
    case idle(String?)

    public init(_ workspace: Workspace) {
        let agentTab = workspace.tabs.first { $0.kind == .agent }
        let agent = agentTab.map { $0.title.isEmpty ? ($0.harness ?? "Agent") : $0.title }
        if workspace.needsAttention {
            self = .needsYou(agent: agent, detail: agentTab?.subtitle)
        } else if workspace.isWorking {
            self = .working(agent: agent, detail: agentTab?.subtitle)
        } else {
            let tab = agentTab ?? workspace.tabs.first
            self = .idle(tab.flatMap { tab in
                guard let subtitle = tab.subtitle, !subtitle.isEmpty else { return nil }
                return tab.kind == .agent ? "\(tab.title): \(subtitle)" : subtitle
            })
        }
    }
}
