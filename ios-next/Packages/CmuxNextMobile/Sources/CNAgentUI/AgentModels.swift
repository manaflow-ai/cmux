import CNCore
import CNTransport
import Foundation
import Observation
import SwiftUI

/// Sessions and harnesses on the connected host. Kept current from
/// `agent.session` / `agent.removed` pushes and reloaded on every reconnect.
@MainActor
@Observable
final class AgentDirectory {
    private(set) var sessions: [AgentSession] = []
    private(set) var harnesses: [Harness] = []
    private(set) var loaded = false
    private(set) var error: String?

    @ObservationIgnored let connection: HostConnection

    init(connection: HostConnection) { self.connection = connection }

    /// Sessions newest first, closed ones hidden.
    var visibleSessions: [AgentSession] {
        sessions.filter { $0.status != .closed }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func harness(_ id: String) -> Harness? { harnesses.first { $0.id == id } }

    func reload() async {
        guard let client = connection.client else { return }
        do {
            async let s = client.listAgentSessions()
            async let h = client.harnesses()
            let (sessions, harnesses) = try await (s, h)
            self.sessions = sessions
            self.harnesses = harnesses
            self.error = nil
        } catch {
            self.error = Self.describe(error)
        }
        loaded = true
    }

    func listen() async {
        for await push in connection.pushes() {
            switch push {
            case .agentSession(let s):
                if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
            case .agentRemoved(let id):
                sessions.removeAll { $0.id == id }
            default:
                break
            }
        }
    }

    func create(_ params: AgentCreateParams) async throws -> AgentSession {
        let session = try await connection.requireClient().createAgentSession(params)
        if let i = sessions.firstIndex(where: { $0.id == session.id }) { sessions[i] = session } else { sessions.append(session) }
        RecentFolders.shared.note(session.cwd)
        return session
    }

    func close(_ id: String) async {
        try? await connection.requireClient().closeAgent(id)
        sessions.removeAll { $0.id == id }
    }

    func rename(_ id: String, title: String) async {
        try? await connection.requireClient().renameAgent(id, title: title)
    }

    /// Recently used folders: this phone's picks first, then the host's sessions.
    var recentFolders: [String] {
        var seen = Set<String>()
        return (RecentFolders.shared.list + visibleSessions.map(\.cwd)).filter { seen.insert($0).inserted }.prefix(6).map { $0 }
    }

    static func describe(_ error: any Error) -> String {
        if let rpc = error as? RPCError { return rpc.message }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// Folders the user started sessions in, newest first.
@MainActor
final class RecentFolders {
    static let shared = RecentFolders()
    private let key = "cn.agent.recentFolders"

    var list: [String] { (UserDefaults.standard.array(forKey: key) as? [String]) ?? [] }

    func note(_ folder: String) {
        var l = list.filter { $0 != folder }
        l.insert(folder, at: 0)
        UserDefaults.standard.set(Array(l.prefix(8)), forKey: key)
    }
}

/// A file or photo picked in the composer, ready for `agent.prompt`.
struct ComposerAttachment: Identifiable, Hashable, Sendable {
    let id = UUID()
    var name: String
    var mimeType: String
    var data: Data
    var isImage: Bool { mimeType.hasPrefix("image/") }
}

/// A prompt written while the agent was busy; sent when the turn ends.
struct QueuedPrompt: Identifiable, Hashable, Sendable {
    let id = UUID()
    var text: String
    var attachments: [ComposerAttachment]
}

/// One session's transcript and actions.
@MainActor
@Observable
final class AgentChatModel {
    let sessionId: String
    private(set) var session: AgentSession?
    private(set) var items: [TranscriptItem] = []
    private(set) var commands: [SlashCommand] = []
    private(set) var harnesses: [Harness] = []
    private(set) var loaded = false
    private(set) var error: String?
    /// Prompts typed while the agent works, sent in order once it is idle.
    var queue: [QueuedPrompt] = []
    /// Open disclosures (worked folds, tool groups, thoughts, tool output, edited files).
    var expanded: Set<String> = []
    /// Send state of prompts the phone inserted before the host echoed them.
    private(set) var sendStates: [String: LocalSendState] = [:]
    /// When the running turn started, for "Working for 12s".
    private(set) var turnStartedAt: Date?
    /// Turns (by prompt id) that ended while this screen watched them. They
    /// stay unfolded so the transcript does not collapse under the reader.
    private(set) var finishedInView: Set<String> = []
    /// Bumped when the user sends, so the view scrolls to the bottom.
    private(set) var sendTick = 0

    @ObservationIgnored let connection: HostConnection
    /// Host item id -> the id of the local bubble it replaced, so the bubble
    /// keeps its identity (no re-insert animation) when the echo arrives.
    @ObservationIgnored private var aliases: [String: String] = [:]
    @ObservationIgnored private var sending = false
    /// Local bubbles the host has not echoed yet (the echo can arrive before
    /// or after the `agent.prompt` response).
    @ObservationIgnored private var awaitingEcho: [String] = []

    init(connection: HostConnection, sessionId: String) {
        self.connection = connection
        self.sessionId = sessionId
    }

    var harness: Harness? { session.flatMap { s in harnesses.first { $0.id == s.harness } } }
    var isLive: Bool { session?.status == .running || session?.status == .waiting }
    var pendingPermission: PendingPermission? { PendingPermission.find(in: items) }
    var lastPromptId: String? { items.last { if case .user = $0 { true } else { false } }?.id }
    var hasTurns: Bool { items.contains { if case .user = $0 { true } else { false } } }

    var modelName: String? {
        guard let id = session?.model else { return nil }
        return harness?.models.first { $0.id == id }?.name ?? id
    }

    var modeName: String? {
        guard let id = session?.mode else { return nil }
        return harness?.modes.first { $0.id == id }?.name ?? id
    }

    // MARK: Loading

    func reload() async {
        guard let client = connection.client else { return }
        do {
            async let history = client.agentHistory(sessionId)
            async let harnesses = client.harnesses()
            let (h, list) = try await (history, harnesses)
            // Keep bubbles the host has not seen yet; drop ones it has echoed
            // (history carries them under the host's ids).
            let pendingLocal = items.filter { if case .user(let u) = $0 { sendStates[u.id] == .failed || (awaitingEcho.contains(u.id) && !h.items.contains { if case .user(let x) = $0 { x.text == u.text } else { false } }) } else { false } }
            awaitingEcho.removeAll { id in !pendingLocal.contains { $0.id == id } }
            aliases.removeAll()
            session = h.session
            items = h.items + pendingLocal
            commands = h.commands
            self.harnesses = list
            if isLive, turnStartedAt == nil { turnStartedAt = Date(epochMillis: h.session.updatedAt) }
            error = nil
        } catch {
            self.error = AgentDirectory.describe(error)
        }
        loaded = true
    }

    func listen() async {
        for await push in connection.pushes() {
            switch push {
            case .agentSession(let s) where s.id == sessionId:
                let wasLive = isLive
                session = s
                if isLive, !wasLive, turnStartedAt == nil { turnStartedAt = Date() }
                if !isLive { turnStartedAt = nil; flushQueue() }
            case .agentItem(let sid, let item) where sid == sessionId:
                if case .turnEnd = item, !items.contains(where: { $0.id == item.id }),
                   let prompt = items.last(where: { if case .user = $0 { true } else { false } }) {
                    finishedInView.insert(prompt.id)
                }
                if items.contains(where: { $0.id == item.id }) || aliases[item.id] != nil {
                    upsert(item)
                } else {
                    // New rows fade in; updates (streaming text) are not animated.
                    withAnimation(.smooth(duration: 0.22)) { upsert(item) }
                }
            case .agentRemoved(let sid) where sid == sessionId:
                session?.status = .closed
            default:
                break
            }
        }
    }

    func upsert(_ incoming: TranscriptItem) {
        var item = incoming
        if case .user(var u) = item {
            if let local = aliases[u.id] {
                u.id = local
                item = .user(u)
            } else if let local = awaitingEcho.first(where: { id in
                items.contains { if case .user(let c) = $0 { c.id == id && c.text == u.text } else { false } }
            }) {
                awaitingEcho.removeAll { $0 == local }
                aliases[u.id] = local
                sendStates[local] = .sent
                u.id = local
                item = .user(u)
            }
            if turnStartedAt == nil { turnStartedAt = Date() }
        }
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i] = item
        } else {
            items.append(item)
        }
    }

    // MARK: Actions

    /// Sends now, or queues while a turn runs.
    func submit(_ text: String, attachments: [ComposerAttachment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        if isLive || sending {
            queue.append(QueuedPrompt(text: trimmed, attachments: attachments))
            return
        }
        send(trimmed, attachments: attachments)
    }

    private func send(_ text: String, attachments: [ComposerAttachment]) {
        let localId = "local-\(UUID().uuidString)"
        let meta = attachments.map { PromptAttachment(name: $0.name, mimeType: $0.mimeType) }
        sendStates[localId] = .sending
        awaitingEcho.append(localId)
        items.append(.user(UserTranscriptItem(id: localId, text: text, attachments: meta)))
        turnStartedAt = Date()
        sendTick += 1
        sending = true
        let wire = attachments.map { PromptAttachment(name: $0.name, mimeType: $0.mimeType, dataBase64: $0.data.base64EncodedString()) }
        Task {
            defer { self.sending = false }
            do {
                try await connection.requireClient().prompt(sessionId, text: text, attachments: wire.isEmpty ? nil : wire)
                if sendStates[localId] == .sending { sendStates[localId] = .sent }
            } catch {
                sendStates[localId] = .failed
                awaitingEcho.removeAll { $0 == localId }
                self.error = AgentDirectory.describe(error)
                turnStartedAt = nil
            }
        }
    }

    func retry(_ itemId: String) {
        guard let i = items.firstIndex(where: { $0.id == itemId }), case .user(let u) = items[i] else { return }
        items.remove(at: i)
        sendStates[itemId] = nil
        submit(u.text, attachments: [])
    }

    func removeQueued(_ id: UUID) { queue.removeAll { $0.id == id } }

    private func flushQueue() {
        guard !isLive, !sending, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        send(next.text, attachments: next.attachments)
    }

    func cancel() {
        Task { try? await connection.requireClient().cancelAgent(sessionId) }
    }

    func answer(_ permission: PermissionTranscriptItem, option: PermissionOption) {
        // Optimistic: the card leaves at once; the host's echo confirms it.
        var resolved = permission
        resolved.resolved = option.id
        upsert(.permission(resolved))
        Task {
            do {
                try await connection.requireClient().answerPermission(sessionId, itemId: permission.id, optionId: option.id)
            } catch {
                self.error = AgentDirectory.describe(error)
                await reload()
            }
        }
    }

    func setModel(_ id: String) {
        session?.model = id
        Task { try? await connection.requireClient().setAgentModel(sessionId, modelId: id) }
    }

    func setMode(_ id: String) {
        session?.mode = id
        Task { try? await connection.requireClient().setAgentMode(sessionId, modeId: id) }
    }

    func rename(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        session?.title = t
        Task { try? await connection.requireClient().renameAgent(sessionId, title: t) }
    }

    func close() async {
        try? await connection.requireClient().closeAgent(sessionId)
        session?.status = .closed
    }

    func toggle(_ id: String) {
        if id.hasPrefix("worked-"), finishedInView.remove(String(id.dropFirst("worked-".count))) != nil {
            // Folding a turn that ended on screen returns it to the normal fold.
            expanded.remove(id)
            return
        }
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}
