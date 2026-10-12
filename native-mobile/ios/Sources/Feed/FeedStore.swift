import Foundation
import Observation

/// One attention event, shown as a post.
struct FeedItem: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable, Hashable {
        case question, permission, done, error, notice
    }

    var id: String
    var kind: Kind
    var surface: Int?
    var agent: String?
    var workspace: String?
    var terminalTitle: String?
    var title: String
    var body: String
    /// The prompt (or earlier reply) this event answers, for the quote bubble.
    var quote: String?
    /// Choices the agent offered (numbered menu), answered with one tap.
    var options: [FeedOption]
    var createdAt: Date
    var read: Bool
    var answered: String?

    var needsAttention: Bool { (kind == .question || kind == .permission) && answered == nil }
    /// Only a question or permission post offers its numbered choices; a
    /// finished agent's numbered list is prose, and tapping it would type a
    /// digit into the idle prompt.
    var takesOptions: Bool { kind == .question || kind == .permission }
}

struct FeedOption: Sendable, Hashable, Identifiable {
    var key: String
    var label: String
    var id: String { key }
}

/// Builds the feed from the Mac's daemon: notifications and agents moving
/// to `blocked` or `done`. Each post fetches the terminal text once to find
/// the prompt it answers and any numbered choices.
@MainActor
@Observable
final class FeedStore {
    enum Filter: String, CaseIterable, Identifiable {
        case all, attention, done
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .attention: String(localized: "Needs input")
            case .done: String(localized: "Done")
            }
        }
    }

    private(set) var items: [FeedItem] = []
    var filter: Filter = .all
    @ObservationIgnored private weak var connection: HostConnection?
    /// Posts already filled from their terminal. Each enrich reads the whole
    /// scrollback over the link; a reconnect's backfill must not redo them.
    @ObservationIgnored private var enriched: Set<String> = []

    var visible: [FeedItem] {
        switch filter {
        case .all: items
        case .attention: items.filter(\.needsAttention)
        case .done: items.filter { $0.kind == .done }
        }
    }

    var unreadCount: Int { items.filter { !$0.read }.count }

    func attach(_ connection: HostConnection) {
        self.connection = connection
        items = []
        enriched = []
    }

    /// Loads existing notifications (HostConnection calls it on connect).
    func backfill() async {
        guard let connection else { return }
        for notification in connection.notifications.prefix(60).reversed() {
            ingest(notification, from: connection, enrich: false)
        }
        for index in items.indices.prefix(12) { await enrich(items[index].id) }
    }

    func ingest(_ notification: DaemonNotification, from connection: HostConnection, enrich: Bool = true) {
        guard !items.contains(where: { $0.id == "n-\(notification.id)" }) else { return }
        let workspace = notification.surface.flatMap { connection.workspace(containing: $0)?.displayName }
        let tab = notification.surface.flatMap { connection.tab(surface: $0) }
        let text = [notification.title, notification.subtitle ?? "", notification.body].joined(separator: " ").lowercased()
        let kind: FeedItem.Kind = if notification.level == "error" {
            .error
        } else if text.contains("permission") || text.contains("approve") || text.contains("allow") {
            .permission
        } else if text.contains("?") || text.contains("waiting for your input") || text.contains("needs your") {
            .question
        } else if text.contains("done") || text.contains("finished") || text.contains("complete") {
            .done
        } else {
            .notice
        }
        let item = FeedItem(
            id: "n-\(notification.id)",
            kind: kind,
            surface: notification.surface,
            agent: connection.agents[notification.surface ?? -1]?.agent ?? Self.agentName(in: notification.title),
            workspace: workspace,
            terminalTitle: tab?.displayTitle,
            title: notification.title,
            body: notification.body.isEmpty ? (notification.subtitle ?? "") : notification.body,
            quote: nil,
            options: kind == .question || kind == .permission ? FeedTextParser.options(in: notification.body) : [],
            createdAt: notification.createdAtMs.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date(),
            read: notification.acknowledged ?? false,
            answered: nil
        )
        insert(item)
        if enrich { Task { await self.enrich(item.id) } }
    }

    func ingest(_ agent: DaemonAgent, previous: DaemonAgent?, from connection: HostConnection) {
        guard agent.status != previous?.status, agent.status == .blocked || agent.status == .done else { return }
        let tab = connection.tab(surface: agent.surface)
        let name = agent.agent.map(Self.displayName) ?? String(localized: "Agent")
        let item = FeedItem(
            id: "a-\(agent.surface)-\(Int(agent.updatedAtMs ?? Date().timeIntervalSince1970 * 1000))",
            kind: agent.status == .blocked ? .question : .done,
            surface: agent.surface,
            agent: agent.agent,
            workspace: connection.workspace(containing: agent.surface)?.displayName,
            terminalTitle: tab?.displayTitle,
            title: agent.status == .blocked ? String(localized: "\(name) needs your input") : String(localized: "\(name) finished"),
            body: "",
            quote: nil,
            options: [],
            createdAt: Date(),
            read: false,
            answered: nil
        )
        // A notification for the same moment usually follows; keep one post.
        if items.contains(where: { $0.surface == agent.surface && abs($0.createdAt.timeIntervalSinceNow) < 3 }) { return }
        insert(item)
        Task { await self.enrich(item.id) }
    }

    private func insert(_ item: FeedItem) {
        items.insert(item, at: 0)
        items.sort { $0.createdAt > $1.createdAt }
        if items.count > 300 { items.removeLast(items.count - 300) }
    }

    /// Reads the terminal once to fill the quote, the body and the choices.
    func enrich(_ id: String) async {
        guard !enriched.contains(id), let connection, let index = items.firstIndex(where: { $0.id == id }),
              let surface = items[index].surface else { return }
        enriched.insert(id)
        let text = await connection.scrollback(surface: surface)
        guard !text.isEmpty, let current = items.firstIndex(where: { $0.id == id }) else {
            enriched.remove(id)
            return
        }
        let parsed = FeedTextParser.parse(text, columns: connection.tab(surface: surface)?.size?.cols)
        if items[current].quote == nil { items[current].quote = parsed.lastPrompt }
        if items[current].body.count < 40, let reply = parsed.lastReply { items[current].body = reply }
        if items[current].options.isEmpty, items[current].takesOptions { items[current].options = parsed.options }
    }

    func markRead(_ item: FeedItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }), !items[index].read else { return }
        items[index].read = true
        if let surface = item.surface { Task { await connection?.acknowledge(surface: surface) } }
    }

    /// Marks every post read here and on the Mac (each terminal once), so
    /// the next backfill doesn't bring them back unread.
    func markAllRead() {
        let surfaces = Set(items.filter { !$0.read }.compactMap(\.surface))
        for index in items.indices { items[index].read = true }
        guard let connection, !surfaces.isEmpty else { return }
        Task { for surface in surfaces { await connection.acknowledge(surface: surface) } }
    }

    /// Types a reply into the agent's terminal and presses Return.
    func reply(_ item: FeedItem, text: String) async throws {
        guard let connection, let surface = item.surface else { return }
        try await connection.send(surface: surface, text: text)
        try await connection.sendKeys(surface: surface, ["enter"])
        markAnswered(item, text)
    }

    /// Picks a numbered choice (Claude Code / Codex menus take the digit).
    func answer(_ item: FeedItem, option: FeedOption) async throws {
        guard let connection, let surface = item.surface else { return }
        try await connection.sendKeys(surface: surface, [option.key])
        markAnswered(item, option.label)
    }

    private func markAnswered(_ item: FeedItem, _ text: String) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].answered = text
        items[index].read = true
        Haptics.success()
    }

    static func agentName(in title: String) -> String? {
        let lower = title.lowercased()
        for name in ["claude", "codex", "gemini", "grok", "cursor", "opencode", "amp"] where lower.contains(name) { return name }
        return nil
    }

    static func displayName(_ agent: String) -> String {
        switch agent.lowercased() {
        case "claude": "Claude"
        case "codex": "Codex"
        case "gemini": "Gemini"
        case "opencode": "OpenCode"
        default: agent.capitalized
        }
    }
}
