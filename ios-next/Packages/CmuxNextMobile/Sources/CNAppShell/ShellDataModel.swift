#if os(iOS)
import CNCore
import CNTransport
import Foundation
import Observation

/// Lightweight lists the shells show outside the module roots: the drawer
/// sidebar's sections and the tab shell's running-agent accessory. Reloads on
/// every (re)connect and applies host pushes.
@MainActor
@Observable
public final class ShellDataModel {
    public private(set) var conversations: [Conversation] = []
    public private(set) var sessions: [AgentSession] = []
    public private(set) var terminals: [Terminal] = []
    public private(set) var tabs: [BrowserTab] = []

    @ObservationIgnored let connection: HostConnection
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var loadedGeneration = -1

    init(connection: HostConnection) {
        self.connection = connection
    }

    public var runningSessions: [AgentSession] { sessions.filter { $0.status == .running } }
    public var waitingSessions: [AgentSession] { sessions.filter { $0.status == .waiting } }

    /// Runs for the lifetime of the shell (call from `.task`).
    func run() async {
        if pushTask == nil {
            let pushes = connection.pushes()
            pushTask = Task { [weak self] in
                for await push in pushes { self?.apply(push) }
            }
        }
        await reloadIfNeeded()
    }

    func reloadIfNeeded() async {
        guard connection.state.isConnected, loadedGeneration != connection.generation, let client = connection.client else { return }
        loadedGeneration = connection.generation
        let info = connection.hostInfo
        async let conv = (info?.supports(.conversations) ?? true) ? (try? await client.listConversations()) : []
        async let agents = (info?.supports(.agent) ?? true) ? (try? await client.listAgentSessions()) : []
        async let terms = (info?.supports(.terminal) ?? true) ? (try? await client.listTerminals()) : []
        async let browser = (info?.supports(.browser) ?? true) ? (try? await client.listTabs()) : []
        let (c, a, t, b) = await (conv, agents, terms, browser)
        if let c { conversations = Self.sortConversations(c) }
        if let a { sessions = Self.sortSessions(a) }
        if let t { terminals = t.sorted { $0.createdAt > $1.createdAt } }
        if let b { tabs = b }
    }

    private func apply(_ push: HostPush) {
        switch push {
        case .conversationUpdated(let c):
            conversations.removeAll { $0.id == c.id }
            conversations = Self.sortConversations(conversations + [c])
        case .conversationMessage(let m):
            if let i = conversations.firstIndex(where: { $0.id == m.conversationId }) {
                conversations[i].lastMessage = m
                conversations[i].updatedAt = max(conversations[i].updatedAt, m.sentAt)
                conversations = Self.sortConversations(conversations)
            }
        case .conversationRemoved(let id):
            conversations.removeAll { $0.id == id }
        case .agentSession(let s):
            sessions.removeAll { $0.id == s.id }
            sessions = Self.sortSessions(sessions + [s])
        case .agentRemoved(let id):
            sessions.removeAll { $0.id == id }
        case .terminalUpdated(let t):
            if let i = terminals.firstIndex(where: { $0.id == t.id }) { terminals[i] = t } else { terminals.insert(t, at: 0) }
        case .terminalExited(let id, _):
            if let i = terminals.firstIndex(where: { $0.id == id }) { terminals[i].running = false }
        case .browserTab(let tab):
            if let i = tabs.firstIndex(where: { $0.id == tab.id }) { tabs[i] = tab } else { tabs.append(tab) }
        case .browserClosed(let id):
            tabs.removeAll { $0.id == id }
        case .typing, .agentItem, .other:
            break
        }
    }

    static func sortConversations(_ list: [Conversation]) -> [Conversation] {
        list.sorted { ($0.pinned ? 0 : 1, -$0.updatedAt) < ($1.pinned ? 0 : 1, -$1.updatedAt) }
    }

    static func sortSessions(_ list: [AgentSession]) -> [AgentSession] {
        list.filter { $0.status != .closed }.sorted { $0.updatedAt > $1.updatedAt }
    }
}
#endif

/// Reload trigger for `ShellDataModel`: a new connection generation that is
/// connected.
struct ShellDataKey: Hashable {
    var generation: Int
    var connected: Bool
}
