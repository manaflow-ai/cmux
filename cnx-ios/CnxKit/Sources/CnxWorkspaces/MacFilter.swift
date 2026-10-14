import CnxModel
import Foundation
import Observation

/// Which Macs the Workspaces list shows: every Mac in the team (mixed, no
/// per-Mac grouping) or one Mac. The toolbar's filter menu.
public enum MacScope: Hashable, Sendable {
    case all
    case mac(String)

    public var macID: String? {
        if case let .mac(id) = self { id } else { nil }
    }
}

/// The Workspaces list's Mac filter, remembered per team. A Mac that has
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

extension MacScope {
    /// The filter menu's Macs after All: online first, each group in team order.
    public static func menuOrder(_ macs: [MacDevice]) -> [MacDevice] {
        macs.filter(\.isOnline) + macs.filter { !$0.isOnline }
    }

    /// The Mac New Workspace targets: the chosen Mac (nil while it cannot
    /// take one, e.g. offline), else the creator's preferred or only Mac.
    public func newWorkspaceMac(available: [MacDevice], fallback: MacDevice?) -> MacDevice? {
        if let id = macID { return available.first { $0.id == id } }
        return fallback
    }
}

extension MacScope {
    /// The Mac the phone links while the list shows this scope. The phone
    /// links one Mac at a time, and a Mac the user chose to look at must
    /// never sit unlinked behind a false empty state (verify/e2e-matrix.md
    /// #2): the chosen Mac when it is online. Nil for All Macs (the link
    /// keeps its Mac) and for an offline or unknown Mac (nothing to dial).
    public func macToLink(in macs: [MacDevice]) -> String? {
        guard let id = macID, macs.contains(where: { $0.id == id && $0.isOnline }) else { return nil }
        return id
    }

    /// Opening a workspace links its Mac when it is online.
    public static func macToLink(opening workspace: Workspace, in macs: [MacDevice]) -> String? {
        MacScope.mac(workspace.macID).macToLink(in: macs)
    }
}

/// Live mode: moves the phone's one link to a Mac.
public struct MacLinking {
    /// Links the Mac (nothing when it already is the link's Mac).
    public var link: @MainActor (String) -> Void
    /// Whether this phone may dial the Mac at all (a teammate's Mac in a
    /// shared team is listed, never dialed). A read, safe in a view body.
    public var canLink: @MainActor (String) -> Bool
    /// Whether the phone's one link targets the Mac now (dialing or up). A read.
    public var isLinkTarget: @MainActor (String) -> Bool

    public init(link: @escaping @MainActor (String) -> Void, canLink: @escaping @MainActor (String) -> Bool,
                isLinkTarget: @escaping @MainActor (String) -> Bool) {
        self.link = link
        self.canLink = canLink
        self.isLinkTarget = isLinkTarget
    }

    /// How the link stands toward `macID`, for ``MacEmptyState``.
    @MainActor public func reach(_ macID: String) -> MacReach {
        guard canLink(macID) else { return .othersMac }
        return isLinkTarget(macID) ? .linkTarget : .elsewhere
    }
}

/// How the phone's link stands toward one Mac.
public enum MacReach: Equatable, Sendable {
    /// No live link to move (mock mode).
    case none
    /// The link targets this Mac: its data is on its way.
    case linkTarget
    /// The link is on another Mac (or none); Connect moves it here.
    case elsewhere
    /// A teammate's Mac: protocol v1 lets only its owner's phones connect.
    case othersMac
}

/// What the list says when it is filtered to one Mac and has no rows.
public enum MacEmptyState: Equatable, Sendable {
    case offline
    case failed(String)
    /// Online, and the link is not on it: Connect moves it here.
    case notConnected
    /// A teammate's Mac: listed, but only its owner's phones can connect.
    case othersMac
    /// Online and being linked: its list (or the ability to create on it)
    /// arrives with the link.
    case connecting
    /// The Mac answered with no workspaces (or cached data says so).
    case empty(canCreate: Bool)

    /// - `reach`: how the phone's link stands toward the Mac. "Connecting"
    ///   only while the link actually targets it; otherwise Connect.
    /// - `connection`: this phone's link to the Mac (nil: not linked).
    /// - `tracksLive`: live data (false in mock mode, where every list is the Mac's).
    public static func resolve(isOnline: Bool, list: WorkspaceInbox.ListState, connection: MacConnection?,
                               tracksLive: Bool, reach: MacReach, canCreate: Bool) -> MacEmptyState {
        guard isOnline else { return .offline }
        if reach == .othersMac { return .othersMac }
        let autoLinks = reach == .linkTarget
        switch list {
        case .failed(let reason):
            return .failed(reason)
        case .notConnected:
            return autoLinks ? .connecting : .notConnected
        case .loading:
            return reach == .elsewhere ? .notConnected : .connecting
        case .live, .cached:
            if canCreate || !tracksLive { return .empty(canCreate: canCreate) }
            switch connection {
            case .failed(let reason): return .failed(reason)
            // Linked, but the Mac's own list has not come over this link
            // yet (the rows are last-known): still connecting. Only a Mac
            // that answered and still refuses new workspaces says so.
            case .connected: return list == .live ? .empty(canCreate: false) : .connecting
            case .connecting: return autoLinks || reach == .none ? .connecting : .notConnected
            case nil: return autoLinks ? .connecting : .notConnected
            }
        }
    }
}
