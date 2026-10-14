import CnxModel
import Foundation
import Observation

/// Which Macs the Workspaces list shows: every Mac in the team (mixed, no
/// per-Mac grouping) or one Mac. The chip row at the top of the list.
public enum MacScope: Hashable, Sendable {
    case all
    case mac(String)

    public var macID: String? {
        if case let .mac(id) = self { id } else { nil }
    }
}

/// The Workspaces list's Mac chip, remembered per team. A Mac that has
/// left the team (or was never in it) reads as All.
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

/// How long ago a workspace was last active, as ChatGPT groups its chat
/// history: Today, Yesterday, Previous 7 Days, Previous 30 Days, then by
/// month ("September", or "September 2025" in an earlier year).
public enum RecencyBucket: Hashable, Sendable {
    case today
    case yesterday
    case previous7Days
    case previous30Days
    case month(year: Int, month: Int)

    /// Days are calendar days in `calendar`'s time zone; a date in the
    /// future (clock skew) reads as Today.
    public init(_ date: Date, now: Date, calendar: Calendar) {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: self = .today
        case 1: self = .yesterday
        case 2...7: self = .previous7Days
        case 8...30: self = .previous30Days
        default:
            let parts = calendar.dateComponents([.year, .month], from: date)
            self = .month(year: parts.year ?? 0, month: parts.month ?? 1)
        }
    }

    public func title(now: Date, calendar: Calendar) -> String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .previous7Days: return "Previous 7 Days"
        case .previous30Days: return "Previous 30 Days"
        case let .month(year, month):
            let names = calendar.standaloneMonthSymbols
            let name = names.indices.contains(month - 1) ? names[month - 1] : "\(month)"
            return calendar.component(.year, from: now) == year ? name : "\(name) \(year)"
        }
    }
}

/// One recency group of the list, newest first.
public struct RecencySection: Identifiable, Hashable, Sendable {
    public var bucket: RecencyBucket
    public var title: String
    public var workspaces: [Workspace]
    public var id: RecencyBucket { bucket }
}

/// What the list shows for a chip and a search, computed from the store:
/// the chosen Macs' workspaces, newest first, grouped by recency. All mixes
/// every Mac in the team, online or not.
public struct WorkspaceListLayout: Hashable, Sendable {
    public var scope: MacScope
    public var sections: [RecencySection]

    public init(scope: MacScope, macs: [MacDevice], workspaces: [Workspace], query: String = "",
                now: Date = Date(), calendar: Calendar = .current) {
        let scope = MacFilter.resolve(scope, macs: macs)
        self.scope = scope
        let chosen = Set(scope.macID.map { [$0] } ?? macs.map(\.id))
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = workspaces
            .filter { chosen.contains($0.macID) && Self.matches($0, query) }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        var sections: [RecencySection] = []
        for workspace in matching {
            let bucket = RecencyBucket(workspace.lastActivityAt, now: now, calendar: calendar)
            if sections.last?.bucket == bucket {
                sections[sections.count - 1].workspaces.append(workspace)
            } else {
                sections.append(RecencySection(bucket: bucket, title: bucket.title(now: now, calendar: calendar), workspaces: [workspace]))
            }
        }
        self.sections = sections
    }

    /// Search matches the name, then the branch and directory.
    static func matches(_ workspace: Workspace, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [workspace.title, workspace.branch ?? "", workspace.directory].contains { $0.localizedStandardContains(query) }
    }

    public var isEmpty: Bool { sections.isEmpty }
}

extension MacScope {
    /// The chips after All: online Macs first, each group in team order.
    public static func chipOrder(_ macs: [MacDevice]) -> [MacDevice] {
        macs.filter(\.isOnline) + macs.filter { !$0.isOnline }
    }

    /// The Mac New Workspace targets: the chosen Mac (nil while it cannot
    /// take one, e.g. offline), else the creator's preferred or only Mac.
    public func newWorkspaceMac(available: [MacDevice], fallback: MacDevice?) -> MacDevice? {
        if let id = macID { return available.first { $0.id == id } }
        return fallback
    }
}
