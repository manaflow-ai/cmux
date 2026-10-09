#if os(iOS)
import CNCore
import CNTransport
import Foundation
import Observation

/// Conversations state over `HostConnection`: the list, loaded histories,
/// typing state and optimistic sends. Reloads whenever
/// `connection.generation` changes, so it survives reconnects.
@MainActor
final class ConversationsStore {
    enum Change {
        case list
        case thread(String)
        case typing(String)
        case removed(String)
    }

    let connection: HostConnection
    private(set) var conversations: [Conversation] = []
    private(set) var loaded = false
    private(set) var histories: [String: [Message]] = [:]
    private(set) var hasMore: [String: Bool] = [:]
    private(set) var typing: [String: Set<String>] = [:]
    /// Local "Mark as Unread" (the protocol has only `conv.read`).
    private(set) var markedUnread: Set<String> = []
    private var me: MessageSender?
    private var lastGeneration = -1
    private var pushTask: Task<Void, Never>?
    private var observers: [UUID: (Change) -> Void] = [:]
    private var historyRequests: Set<String> = []

    init(connection: HostConnection) {
        self.connection = connection
    }

    func start() {
        guard pushTask == nil else { return }
        trackGeneration()
        let stream = connection.pushes()
        pushTask = Task { [weak self] in
            for await push in stream {
                self?.handle(push)
            }
        }
    }

    func stop() {
        pushTask?.cancel()
        pushTask = nil
    }

    @discardableResult
    func observe(_ body: @escaping (Change) -> Void) -> UUID {
        let id = UUID()
        observers[id] = body
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    private func emit(_ change: Change) {
        for o in observers.values { o(change) }
    }

    // MARK: Derived

    var sorted: [Conversation] {
        conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    var pinned: [Conversation] { sorted.filter(\.pinned) }
    var unpinned: [Conversation] { sorted.filter { !$0.pinned } }

    func conversation(_ id: String) -> Conversation? { conversations.first { $0.id == id } }

    func isUnread(_ c: Conversation) -> Bool { c.unread > 0 || markedUnread.contains(c.id) }

    func isTyping(_ conversationId: String) -> Bool { !(typing[conversationId]?.isEmpty ?? true) }

    // MARK: Loading

    private func trackGeneration() {
        let generation = withObservationTracking {
            connection.generation
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackGeneration() }
        }
        guard generation != lastGeneration else { return }
        lastGeneration = generation
        guard generation > 0 else { return }
        reload()
    }

    func reload() {
        Task {
            guard let client = connection.client else { return }
            do {
                let list = try await client.listConversations()
                conversations = list
                loaded = true
                emit(.list)
                // Refresh histories the UI already holds; a reconnect may have
                // missed pushes.
                for id in histories.keys { await loadHistory(id, force: true) }
            } catch {
                loaded = true
                emit(.list)
            }
        }
    }

    func loadHistory(_ conversationId: String, force: Bool = false) async {
        guard force || histories[conversationId] == nil, !historyRequests.contains(conversationId) else { return }
        guard let client = connection.client else { return }
        historyRequests.insert(conversationId)
        defer { historyRequests.remove(conversationId) }
        do {
            let page = try await client.conversationHistory(conversationId, limit: 200)
            let pending = (histories[conversationId] ?? []).filter { $0.status == .sending || $0.status == .failed }
            var merged = page.messages
            for p in pending where !merged.contains(where: { $0.clientId != nil && $0.clientId == p.clientId }) {
                merged.append(p)
            }
            histories[conversationId] = merged.sorted { $0.sentAt < $1.sentAt }
            hasMore[conversationId] = page.hasMore
            if me == nil, let m = merged.first(where: { $0.sender.isMe }) { me = m.sender }
            emit(.thread(conversationId))
        } catch {
            if histories[conversationId] == nil { histories[conversationId] = [] }
            emit(.thread(conversationId))
        }
    }

    // MARK: Pushes

    private func handle(_ push: HostPush) {
        switch push {
        case .conversationMessage(let m):
            upsert(m)
        case .conversationUpdated(let c):
            if let i = conversations.firstIndex(where: { $0.id == c.id }) { conversations[i] = c } else { conversations.append(c) }
            emit(.list)
        case .typing(let t):
            var set = typing[t.conversationId] ?? []
            if t.typing { set.insert(t.senderId) } else { set.remove(t.senderId) }
            typing[t.conversationId] = set
            emit(.typing(t.conversationId))
        case .conversationRemoved(let id):
            conversations.removeAll { $0.id == id }
            histories[id] = nil
            emit(.removed(id))
            emit(.list)
        default:
            break
        }
    }

    private func upsert(_ m: Message) {
        if me == nil, m.sender.isMe { me = m.sender }
        guard var list = histories[m.conversationId] else { return }
        if let i = list.firstIndex(where: { $0.id == m.id || ($0.clientId != nil && $0.clientId == m.clientId) }) {
            var incoming = m
            // Never move a confirmed message back to "sending".
            if incoming.status == .sending, list[i].status != .sending { incoming.status = list[i].status }
            list[i] = incoming
        } else {
            list.append(m)
            list.sort { $0.sentAt < $1.sentAt }
        }
        histories[m.conversationId] = list
        if !m.sender.isMe, var t = typing[m.conversationId] {
            t.remove(m.sender.id)
            typing[m.conversationId] = t
        }
        emit(.thread(m.conversationId))
    }

    // MARK: Actions

    /// Appends an optimistic message and sends it; the echo replaces it by `clientId`.
    @discardableResult
    func send(_ text: String, to conversationId: String) -> Message {
        let clientId = UUID().uuidString
        let sender = me ?? MessageSender(id: "me", name: "You", isMe: true)
        let optimistic = Message(id: "local-" + clientId, conversationId: conversationId, clientId: clientId,
                                 sender: sender, text: text, sentAt: Date().epochMillis, status: .sending)
        histories[conversationId, default: []].append(optimistic)
        emit(.thread(conversationId))
        Task {
            do {
                guard let client = connection.client else { throw HostClientError.notConnected }
                let echo = try await client.sendMessage(conversationId, text: text, clientId: clientId)
                upsert(echo)
            } catch {
                guard var list = histories[conversationId], let i = list.firstIndex(where: { $0.clientId == clientId }) else { return }
                if list[i].status == .sending {
                    list[i].status = .failed
                    histories[conversationId] = list
                    emit(.thread(conversationId))
                }
            }
        }
        return optimistic
    }

    func markRead(_ id: String) {
        markedUnread.remove(id)
        if let i = conversations.firstIndex(where: { $0.id == id }) { conversations[i].unread = 0 }
        emit(.list)
        Task { try? await connection.client?.markConversationRead(id) }
    }

    func toggleUnread(_ id: String) {
        guard let c = conversation(id) else { return }
        if isUnread(c) { markRead(id) } else { markedUnread.insert(id); emit(.list) }
    }

    func setPinned(_ id: String, _ pinned: Bool) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].pinned = pinned
        emit(.list)
        Task {
            do { try await connection.client?.setConversationPinned(id, pinned: pinned) } catch { reload() }
        }
    }

    func setMuted(_ id: String, _ muted: Bool) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].muted = muted
        emit(.list)
        Task {
            do { try await connection.client?.setConversationMuted(id, muted: muted) } catch { reload() }
        }
    }

    func delete(_ id: String) {
        conversations.removeAll { $0.id == id }
        emit(.list)
        Task {
            do { try await connection.client?.deleteConversation(id) } catch { reload() }
        }
    }
}
#endif
