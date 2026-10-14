import CnxModel
import Foundation

/// What a workspace row says about its workspace, highest priority first
/// (SPEC 11.1 status rules).
public enum WorkspaceStatus: Int, Comparable, Hashable, Sendable {
    /// Being created on its Mac (optimistic row).
    case creating
    /// Its Mac is offline: the agent state is stale and not shown.
    case offline
    /// An agent waits for a permission or an answer.
    case needsYou
    case working
    /// Something new arrived (the Mac's unread flags) since this device last opened it.
    case done
    case idle

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// `seenAt`: when this device last opened the workspace. "Done" stays
    /// cleared until the workspace has newer activity.
    public init(_ workspace: Workspace, isOnline: Bool, isPending: Bool = false, seenAt: Date? = nil) {
        if isPending { self = .creating }
        else if !isOnline { self = .offline }
        else if workspace.needsAttention { self = .needsYou }
        else if workspace.isWorking { self = .working }
        else if workspace.hasUnread, seenAt.map({ $0 < workspace.lastActivityAt }) ?? true { self = .done }
        else { self = .idle }
    }
}

extension Workspace {
    /// The agent tab a status line is about: the waiting tab for needs-you,
    /// the working tab for working, else the first agent tab. Falls back to
    /// the first agent tab while the Mac reports no per-tab state.
    public func agentTab(for status: WorkspaceStatus) -> WorkspaceTab? {
        let wanted: WorkspaceTab.AgentStatus? = switch status {
        case .needsYou: .waiting
        case .working: .working
        default: nil
        }
        if let wanted, let tab = tabs.first(where: { $0.agentStatus == wanted }) { return tab }
        return tabs.first(where: \.isAgent)
    }

    /// "feat-cnx-ios", else the directory.
    public var place: String { branch ?? directory }
}

/// The Workspaces list for a Mac filter and a search (SPEC 11.1, the
/// "Inbox"): Needs You first, then Recent, then one folded line per Mac
/// whose list is not live (offline, or online but not linked).
public struct WorkspaceInbox: Hashable, Sendable {
    /// A Mac whose workspaces are folded into one line.
    public struct Fold: Hashable, Sendable, Identifiable {
        public enum Reason: Hashable, Sendable {
            /// The Mac is offline; its rows expand in place.
            case offline
            /// Online, but this phone is linked to another Mac, so its list
            /// is not known (live mode). A tap links it.
            case notConnected
        }

        public var mac: MacDevice
        public var reason: Reason
        /// Newest first; empty for `.notConnected` (not known).
        public var workspaces: [Workspace]
        /// Rows always shown (filtered to this Mac, a search, or every Mac asleep).
        public var isForcedOpen: Bool
        public var id: String { mac.id }
    }

    /// What the phone sees of the store, for the layout.
    public struct Context: Hashable, Sendable {
        public var pending: Set<String>
        public var seenAt: [String: Date]
        public var sync: AppStore.WorkspaceListSync?

        public init(pending: Set<String> = [], seenAt: [String: Date] = [:], sync: AppStore.WorkspaceListSync? = nil) {
            self.pending = pending
            self.seenAt = seenAt
            self.sync = sync
        }

        func listState(_ macID: String) -> AppStore.WorkspaceListSync.State {
            guard let sync else { return .current }
            if sync.current.contains(macID) { return .current }
            if sync.loading.contains(macID) { return .loading }
            return .notConnected
        }
    }

    public var scope: MacScope
    public var needsYou: [Workspace]
    public var recent: [Workspace]
    public var folds: [Fold]
    public var statuses: [String: WorkspaceStatus]
    /// Recent mixes several Macs, so idle rows name their Mac.
    public var showsMacNames: Bool
    /// A Mac in scope is linking, and there is nothing (cached) to show yet.
    public var isLoading: Bool
    /// An online Mac in scope is linking and its list has not arrived (cached rows may show).
    public var isUpdating: Bool
    /// Scope is All and every Mac is offline.
    public var allAsleep: Bool

    public init(scope: MacScope, macs: [MacDevice], workspaces: [Workspace], query: String = "",
                context: Context = Context()) {
        let scope = MacFilter.resolve(scope, macs: macs)
        self.scope = scope
        let scoped = macs.filter { scope.macID == nil || $0.id == scope.macID }
        let byID = Dictionary(macs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = Set(scoped.map(\.id))
        let order = Dictionary(workspaces.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let matching = workspaces.filter { ws in
            chosen.contains(ws.macID) && Self.matches(ws, macName: byID[ws.macID]?.name, query)
        }
        var statuses: [String: WorkspaceStatus] = [:]
        for ws in matching {
            statuses[ws.id] = WorkspaceStatus(ws, isOnline: byID[ws.macID]?.isOnline ?? false,
                                              isPending: context.pending.contains(ws.id), seenAt: context.seenAt[ws.id])
        }
        func sorted(_ list: [Workspace]) -> [Workspace] {
            list.sorted { Self.isNewer($0, $1, order: order) }
        }
        let live = matching.filter { ws in
            guard let mac = byID[ws.macID], mac.isOnline else { return false }
            return context.listState(mac.id) != .notConnected || context.pending.contains(ws.id)
        }
        needsYou = sorted(live.filter { statuses[$0.id] == .needsYou })
        recent = sorted(live.filter { statuses[$0.id] != .needsYou })
        let online = scoped.filter(\.isOnline)
        let asleep = scope == .all && !scoped.isEmpty && online.isEmpty
        allAsleep = asleep
        let searching = !query.isEmpty
        var folds = scoped.compactMap { mac -> Fold? in
            if !mac.isOnline {
                let rows = sorted(matching.filter { $0.macID == mac.id })
                guard !rows.isEmpty else { return nil }
                return Fold(mac: mac, reason: .offline, workspaces: rows,
                            isForcedOpen: scope.macID != nil || searching || asleep)
            }
            guard context.listState(mac.id) == .notConnected, !searching else { return nil }
            return Fold(mac: mac, reason: .notConnected, workspaces: [], isForcedOpen: false)
        }
        // A fold for the one Mac a filter shows is its empty state, not a line.
        if scope.macID != nil { folds.removeAll { $0.reason == .notConnected } }
        self.folds = folds
        let loadingMacs = online.filter { context.listState($0.id) == .loading }
        isUpdating = !loadingMacs.isEmpty
        isLoading = isUpdating && needsYou.isEmpty && recent.isEmpty && !searching
        showsMacNames = scope == .all && Set(recent.map(\.macID)).count > 1
        self.statuses = statuses
    }

    /// Newest activity first. A row with no known activity time (live: no
    /// event since the phone connected) goes after every row with one, in
    /// the Mac's focus order, then the Mac's own order.
    static func isNewer(_ a: Workspace, _ b: Workspace, order: [String: Int]) -> Bool {
        if a.hasActivityTime != b.hasActivityTime { return a.hasActivityTime }
        if a.hasActivityTime, a.lastActivityAt != b.lastActivityAt { return a.lastActivityAt > b.lastActivityAt }
        if a.focusOrder != b.focusOrder { return a.focusOrder > b.focusOrder }
        return (order[a.id] ?? 0) < (order[b.id] ?? 0)
    }

    /// Search matches the name, branch, directory, Mac name and agent tabs' titles.
    static func matches(_ workspace: Workspace, macName: String?, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        var fields = [workspace.title, workspace.branch ?? "", workspace.directory, macName ?? ""]
        for tab in workspace.tabs where tab.isAgent {
            fields.append(tab.title)
            if let task = tab.task { fields.append(task) }
        }
        return fields.contains { $0.localizedStandardContains(query) }
    }

    public var isEmpty: Bool { needsYou.isEmpty && recent.isEmpty && folds.isEmpty }

    public func status(_ workspace: Workspace) -> WorkspaceStatus { statuses[workspace.id] ?? .idle }

    /// "2 need you", for the navigation subtitle.
    public var needsYouCount: Int { needsYou.count }
}
