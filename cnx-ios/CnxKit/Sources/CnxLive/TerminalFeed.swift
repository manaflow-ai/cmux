import CnxFeed
import CnxModel
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.cnx", category: "feed")

/// Terminal agents in the Feed: Codex, Claude Code and other programs that
/// run in a Mac terminal tab report through the daemon's notification ledger
/// (agent hooks post "Codex finished", "Codex needs approval"; OSC 9/777/99
/// and `cmux notify` post too), not through acpmux. The Mac's own
/// notifications panel reads the same ledger (`list-notifications`) and marks
/// it read per tab (`ack-tab-notifications`).
///
/// Each notification on a terminal tab becomes one Feed item. The ledger is
/// read on connect (history) and again whenever the daemon posts a
/// notification or a tab's unread marker changes (live, and the Mac's reads).
/// Agent chat tabs are left to `LiveFeed`, which has their full turns.
@MainActor
public final class TerminalFeed {
    /// One `list-notifications` row.
    public struct Entry: Hashable, Sendable {
        public var id: String
        public var title: String
        public var subtitle: String?
        public var body: String
        public var level: String
        public var surface: Int?
        public var createdAt: Date
        public var source: String
        public var acknowledged: Bool

        public init?(json: [String: Any]) {
            guard let id = json["id"] as? String, !id.isEmpty else { return nil }
            self.id = id
            title = json["title"] as? String ?? ""
            subtitle = (json["subtitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            body = json["body"] as? String ?? ""
            level = json["level"] as? String ?? "info"
            surface = json["surface"] as? Int
            createdAt = AgentState.date(json["created_at_ms"]) ?? Date(timeIntervalSince1970: 0)
            source = json["source"] as? String ?? "cli"
            acknowledged = json["acknowledged"] as? Bool ?? false
        }
    }

    /// The most ledger rows read (the daemon keeps at most 256).
    static let limit = 100
    /// A terminal's own OSC notification this close to an agent hook's on the
    /// same tab is the same event told twice (Codex does both).
    static let echoWindow: TimeInterval = 10

    let store: FeedStore
    /// Sends one request on the Mac's `daemon` channel of `connection`; nil
    /// while unbound. It throws when that channel is no longer the bound one,
    /// so a read or a read mark never crosses to another Mac or connection.
    /// Parameters are integers only (`limit`, `surface`).
    public var request: (@MainActor (_ command: String, _ params: [String: Int], _ connection: Int) async throws -> Data)?

    private(set) var macID = ""
    private var connection: Int?
    private var tree: DaemonTree?
    private(set) var entries: [Entry] = []
    private var markers: [Int: DaemonTree.NotificationMarker] = [:]
    /// The agent last seen in each terminal (the Mac drops it when the agent exits).
    private var harnesses: [Int: String] = [:]
    /// Each terminal's agent status at the last tree, and the terminals seen
    /// going back to work since (blocked or idle, then working): an ask there
    /// was answered.
    private var statuses: [Int: WorkspaceTab.AgentStatus?] = [:]
    /// Items the Mac reported read: marked read once, so a later Unread on the phone sticks.
    private var macRead: Set<String> = []
    /// Tabs acknowledged from the phone, by the newest notification they covered.
    private var acked: [Int: Date] = [:]
    /// Whether this connection's ledger has been read once (history merges, live inserts).
    private var hydrated = false
    /// The rows of this connection's first read: history, wherever they land.
    private var historyIDs: Set<String> = []
    private var listing = false
    private var dirty = false
    private var generation = 0
    /// The Mac has no notification ledger (an older cmux): not asked again on this connection.
    private var unsupported = false

    public init(store: FeedStore) {
        self.store = store
    }

    /// The item id of a ledger row on `macID`.
    static func itemID(macID: String, entry: String) -> String { "term-\(macID)-\(entry)" }

    // MARK: Inputs

    /// The Mac's tree arrived (`connection` names the daemon channel it came
    /// on): a new connection reads the ledger (history); a changed unread
    /// marker reads it again (a new notification, or a read on the Mac).
    public func treeChanged(_ tree: DaemonTree, macID: String, connection: Int) {
        if connection != self.connection || macID != self.macID {
            self.connection = connection
            self.macID = macID
            entries = []
            markers = [:]
            harnesses = [:]
            statuses = [:]
            acked = [:]
            unsupported = false
            hydrated = false
            historyIDs = []
            generation += 1
        }
        self.tree = tree
        var resumed: Set<Int> = []
        for workspace in tree.workspaces + tree.homeWorkspaces {
            for tab in workspace.tabs where tab.kind == .terminal {
                guard let surface = tree.surfaces[tab.id] else { continue }
                if let harness = tab.harness { harnesses[surface] = harness }
                // Only a change seen here counts: a first sight of "working" may predate the ask.
                // Back at work, or no longer waiting (answered, declined, or the agent quit).
                if let before = statuses[surface],
                   (before != .working && tab.agentStatus == .working) || (before == .waiting && tab.agentStatus != .waiting) {
                    resumed.insert(surface)
                }
                statuses[surface] = .some(tab.agentStatus)
            }
        }
        let changed = tree.notificationMarkers != markers
        markers = tree.notificationMarkers
        apply()
        // Back at work or no longer waiting: the asks shown on that terminal were answered there.
        // An ask that arrives later waits again.
        for entry in entries {
            guard let surface = entry.surface, resumed.contains(surface) else { continue }
            let id = Self.itemID(macID: macID, entry: entry.id)
            if let item = store.item(id: id), item.kind == .needsInput, item.resolution == nil {
                store.resolveElsewhere(id, text: "Answered in the terminal")
            }
        }
        if !hydrated || changed { Task { await refresh() } }
    }

    /// The daemon posted a notification.
    public func notificationPosted() {
        Task { await refresh() }
    }

    /// Reads the ledger now (coalesced: one read in flight, one more queued).
    public func refresh() async {
        guard request != nil, connection != nil, !unsupported else { return }
        if listing {
            dirty = true
            return
        }
        listing = true
        defer { listing = false }
        repeat {
            dirty = false
            let generation = generation
            // The connection may have changed while an earlier read ran.
            guard let request, let connection = self.connection else { return }
            do {
                let reply = try await request("list-notifications", ["limit": Self.limit], connection)
                // A newer connection queued its own read (`dirty`): go round again.
                guard generation == self.generation else { continue }
                apply(ledger: try WorkspaceSync.check(reply))
            } catch let error as DaemonReplyError {
                // An older Mac without the ledger (`notification-ack-v1`): no terminal events.
                if generation == self.generation { unsupported = true }
                log.error("list-notifications refused: \(error.message, privacy: .public)")
                return
            } catch {
                log.error("list-notifications failed: \(String(describing: error), privacy: .public)")
                return
            }
        } while dirty
    }

    /// The Mac cleared its notifications (Clear All Notifications): their
    /// terminal events leave the Feed, then the ledger is read again.
    public func cleared() {
        for entry in entries {
            let id = Self.itemID(macID: macID, entry: entry.id)
            if store.item(id: id) != nil { store.remove(id) }
        }
        entries = []
        Task { await refresh() }
    }

    func apply(ledger reply: [String: Any]) {
        let rows = ((reply["data"] as? [String: Any])?["notifications"] as? [[String: Any]]) ?? []
        entries = rows.compactMap(Entry.init(json:)).sorted { $0.createdAt < $1.createdAt }
        if !hydrated { historyIDs = Set(entries.map(\.id)) }
        apply()
        hydrated = true
    }

    /// The phone read these items (opened, swiped, marked): the Mac marks
    /// their tabs read too, as its own panel does.
    public func itemsChanged(_ items: [FeedItem]) {
        guard let request, let connection, !macID.isEmpty else { return }
        let byID = Dictionary(entries.map { (Self.itemID(macID: macID, entry: $0.id), $0) }, uniquingKeysWith: { first, _ in first })
        // The Mac reads a whole tab at once, so only the read of a tab's newest
        // event marks it: reading an older one must not hide a newer one there.
        var newest: [Int: Date] = [:]
        for entry in entries where !isEcho(entry) {
            if let surface = entry.surface { newest[surface] = max(newest[surface] ?? entry.createdAt, entry.createdAt) }
        }
        var surfaces: [Int: Date] = [:]
        for item in items where item.opensTerminal && item.isRead {
            guard let entry = byID[item.id], !entry.acknowledged, let surface = entry.surface,
                  newest[surface] == entry.createdAt,
                  (acked[surface] ?? .distantPast) < entry.createdAt else { continue }
            surfaces[surface] = entry.createdAt
        }
        for (surface, newest) in surfaces {
            acked[surface] = newest
            Task {
                do {
                    _ = try WorkspaceSync.check(try await request("ack-tab-notifications", ["surface": surface], connection))
                } catch {
                    log.error("ack-tab-notifications \(surface, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    // MARK: Mapping

    /// Maps the ledger onto the Feed: history merges in, a row new to this
    /// connection goes on top, the Mac's reads mark items read, and a
    /// terminal waiting for input is resolved once it moved on.
    private func apply() {
        guard let tree, !macID.isEmpty else { return }
        let places = Self.places(tree)
        var history: [FeedItem] = []
        var fresh: [FeedItem] = []
        for entry in entries {
            guard let surface = entry.surface else { continue }
            let id = Self.itemID(macID: macID, entry: entry.id)
            let known = store.item(id: id)
            if isEcho(entry) {
                // Shown before the hook's own event arrived: the hook's tells it.
                if known != nil { store.remove(id) }
                continue
            }
            guard let place = places[surface] else { continue }
            guard place.tab.kind == .terminal else { continue }
            let harness = place.tab.harness ?? harnesses[surface] ?? Self.harness(title: entry.title) ?? "terminal"
            var item = Self.item(entry, id: id, harness: harness, workspace: place.workspace, tab: place.tab)
            if known == nil, hydrated, !historyIDs.contains(entry.id) { fresh.append(item) } else {
                if let known {
                    item.createdAt = known.createdAt
                    // Unchanged: no merge (each one rewrites and saves the Feed).
                    if known.kind == item.kind, known.markdown == item.markdown, known.agentName == item.agentName,
                       known.harness == item.harness, known.workspaceID == item.workspaceID,
                       known.workspaceTitle == item.workspaceTitle, known.tabID == item.tabID { continue }
                }
                history.append(item)
            }
        }
        if !history.isEmpty { store.mergeHistory(history) }
        for item in fresh { store.upsert(item, atTop: true) }
        // The Mac's reads.
        for entry in entries where entry.acknowledged {
            let id = Self.itemID(macID: macID, entry: entry.id)
            guard !macRead.contains(id), let item = store.item(id: id) else { continue }
            macRead.insert(id)
            if !item.isRead { store.markRead(id) }
        }
        resolveWaiting()
    }

    /// A terminal that asked for input and then posted again was answered there.
    private func resolveWaiting() {
        let prefix = "term-\(macID)-"
        for entry in entries {
            guard let surface = entry.surface else { continue }
            let id = Self.itemID(macID: macID, entry: entry.id)
            guard id.hasPrefix(prefix), let item = store.item(id: id), item.kind == .needsInput, item.resolution == nil else { continue }
            let later = entries.contains { $0.surface == surface && $0.createdAt > entry.createdAt && !isEcho($0) }
            if later { store.resolveElsewhere(id, text: "Answered in the terminal") }
        }
    }

    /// A terminal's own (OSC) notification next to an agent hook's on the same tab.
    private func isEcho(_ entry: Entry) -> Bool {
        guard entry.source == "terminal", let surface = entry.surface else { return false }
        return entries.contains { other in
            other.source == "agent" && other.surface == surface && abs(other.createdAt.timeIntervalSince(entry.createdAt)) <= Self.echoWindow
        }
    }

    struct Place {
        var workspace: Workspace
        var tab: WorkspaceTab
    }

    static func places(_ tree: DaemonTree) -> [Int: Place] {
        var places: [Int: Place] = [:]
        // The Mac's home workspace too: an agent there still reaches the Feed.
        for workspace in tree.workspaces + tree.homeWorkspaces {
            for tab in workspace.tabs {
                if let surface = tree.surfaces[tab.id] { places[surface] = Place(workspace: workspace, tab: tab) }
            }
        }
        return places
    }

    static func item(_ entry: Entry, id: String, harness: String, workspace: Workspace, tab: WorkspaceTab) -> FeedItem {
        let agentName = harness == "terminal" ? "Terminal" : DaemonTree.agentName(harness)
        let kind = kind(entry)
        var item = FeedItem(
            id: id, kind: kind, workspaceID: workspace.id, tabID: tab.id, agentName: agentName, harness: harness,
            workspaceTitle: workspace.title, markdown: text(entry, agentName: agentName, kind: kind), quote: nil,
            createdAt: entry.createdAt
        )
        item.opensTerminal = true
        return item
    }

    /// Errors fail; an approval, a question or a plan review waits for input
    /// (hooks post those as warnings; other posters are read by their words).
    static func kind(_ entry: Entry) -> FeedItem.Kind {
        if entry.level == "error" { return .failed }
        if entry.level == "warning" { return .needsInput }
        let text = "\(entry.title) \(entry.subtitle ?? "") \(entry.body)".lowercased()
        let waits = ["approval", "permission", "needs input", "needs your input", "waiting for input",
                     "waiting for your input", "asked a question", "plan review"]
        return waits.contains(where: text.contains) ? .needsInput : .finished
    }

    /// The event in words: the title without the agent's name the header
    /// already shows ("Codex needs approval" → "Needs approval"), then what
    /// it is about.
    static func text(_ entry: Entry, agentName: String, kind: FeedItem.Kind) -> String {
        var headline = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if headline.lowercased().hasPrefix(agentName.lowercased() + " ") {
            headline = String(headline.dropFirst(agentName.count + 1))
        } else if headline.caseInsensitiveCompare(agentName) == .orderedSame {
            headline = ""
        }
        if let first = headline.first { headline = first.uppercased() + headline.dropFirst() }
        let detail = [entry.subtitle, entry.body].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != headline }
            .joined(separator: "\n\n")
        switch (headline.isEmpty, detail.isEmpty) {
        case (true, true): return kind == .needsInput ? "Needs your input." : kind == .failed ? "Reported an error."
            // The hook said nothing more (Codex's finished event has no body): say where (D12).
            : "Finished its turn in the terminal. Open it to see the result."
        case (false, true): return headline.hasSuffix(".") || headline.hasSuffix("?") || headline.hasSuffix("!") ? headline : headline + "."
        case (true, false): return detail
        case (false, false): return "**\(headline):** \(detail)"
        }
    }

    /// The agent a hook named in its title ("Codex finished" → `codex`).
    static func harness(title: String) -> String? {
        let known = ["codex", "claude", "cursor", "gemini", "opencode", "amp", "droid", "copilot", "pi"]
        guard let first = title.split(separator: " ").first?.lowercased() else { return nil }
        return known.contains(first) ? first : nil
    }
}
