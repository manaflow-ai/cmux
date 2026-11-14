import CNMBackend
import CNMProtocol
import CNMTransport
import Foundation
import Observation

/// One paired Mac: its link state and everything the app shows from it.
/// Transport-agnostic: it only sees a `PeerDialer` and an `RPCPeer`.
@MainActor
@Observable
final class HostConnection: Identifiable {
    enum Status: Equatable {
        case offline
        case connecting
        case connected(route: String)
        case failed(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    let id: String
    var name: String
    var status: Status = .offline
    var hello: HostHello?

    var conversations: [ConversationInfo] = []
    var messages: [String: [ConversationMessage]] = [:]
    var typing: Set<String> = []

    var agents: [AgentSessionInfo] = []
    var agentEvents: [String: [AgentEvent]] = [:]
    var harnesses: [AgentHarness] = []
    var projects: [ProjectInfo] = []

    var terminals: [TerminalInfo] = []

    @ObservationIgnored private var transcriptCache: [String: (count: Int, lastSeq: Int, builder: TranscriptBuilder)] = [:]

    /// The folded transcript, rebuilt only when the session's log grew.
    func transcript(for session: String) -> TranscriptBuilder {
        let events = agentEvents[session] ?? []
        let lastSeq = events.last?.seq ?? -1
        if let cached = transcriptCache[session], cached.count == events.count, cached.lastSeq == lastSeq { return cached.builder }
        let builder = TranscriptBuilder(events: events)
        transcriptCache[session] = (events.count, lastSeq, builder)
        return builder
    }

    @ObservationIgnored private var peer: RPCPeer?
    @ObservationIgnored private var terminalSinks: [UInt32: (BulkFrame) -> Void] = [:]
    @ObservationIgnored private var terminalSizes: [UInt32: (cols: Int, rows: Int)] = [:]
    /// Agent events that arrived while an attach was in flight.
    @ObservationIgnored private var attaching: [String: [AgentEvent]] = [:]
    @ObservationIgnored private var dialTask: Task<Void, Never>?
    @ObservationIgnored private var online = false
    @ObservationIgnored private var dialGeneration: UUID?
    @ObservationIgnored private var offlineDropTask: Task<Void, Never>?
    @ObservationIgnored private var retry = 0
    @ObservationIgnored private let dialer: PeerDialer
    @ObservationIgnored var peerID: String { "host-" + id }

    init(host: BackendHost, dialer: PeerDialer) {
        id = host.id
        name = host.name
        self.dialer = dialer
    }

    // MARK: Link lifecycle

    /// The phone's own signaling socket dropped: presence is unknown, so a
    /// live link is left alone (it doesn't depend on signaling).
    func signalingLost() {
        online = false
        if peer == nil { status = .offline }
    }

    func setOnline(_ online: Bool) {
        let cameOnline = online && !self.online
        self.online = online
        if online {
            // A dial started while the Mac was away would sit out its full
            // timeout; the Mac is back, so dial again now.
            if cameOnline, peer == nil, let stale = dialTask {
                stale.cancel()
                dialTask = nil
            }
            if peer == nil, dialTask == nil { connect() }
        } else if peer == nil {
            status = .offline
        } else {
            // The Mac left signaling. If it stays away, the link is dead too
            // (a killed host never says goodbye; WebRTC would take ~30 s to
            // notice), so drop it and reconnect as soon as the Mac is back.
            offlineDropTask?.cancel()
            offlineDropTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, !self.online, let peer = self.peer else { return }
                peer.close()
                self.dropped("Mac went offline", peer: peer)
            }
        }
        if online { offlineDropTask?.cancel() }
    }

    func connect() {
        guard dialTask == nil else { return }
        status = .connecting
        let generation = UUID()
        dialGeneration = generation
        dialTask = Task { [weak self] in
            guard let self else { return }
            do {
                let link = try await dialer.dial(peerID: peerID)
                // Superseded, disconnected or removed while dialing: drop it.
                guard !Task.isCancelled, self.online, self.dialGeneration == generation, self.peer == nil else {
                    link.close()
                    if self.dialGeneration == generation { self.dialTask = nil }
                    return
                }
                await self.attach(link)
            } catch {
                guard !Task.isCancelled, self.dialGeneration == generation else { return }
                self.status = self.online ? .failed(error.localizedDescription) : .offline
                self.dialTask = nil
                self.scheduleRetry()
            }
        }
    }

    private func scheduleRetry() {
        guard online else { return }
        retry += 1
        let delay = min(20.0, pow(2, Double(min(retry, 4))))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.peer == nil, self.online else { return }
            self.connect()
        }
    }

    private func attach(_ link: PeerLink) async {
        let peer = RPCPeer(link: link)
        self.peer = peer
        peer.start(
            onNotification: { [weak self] method, params in
                Task { @MainActor in self?.handle(method, params) }
            },
            onBulk: { [weak self] frame in
                Task { @MainActor in self?.terminalSinks[frame.terminal]?(frame) }
            }
        )
        Task { [weak self] in
            for await state in link.states {
                switch state {
                case .connected(let route): self?.status = .connected(route: route)
                case .disconnected(let reason): self?.dropped(reason, peer: peer)
                case .connecting: break
                }
            }
            self?.dropped(nil, peer: peer)
        }
        if case .connecting = status { status = .connected(route: "direct") }
        retry = 0
        dialTask = nil
        await refreshAll()
        // The Mac forgot this phone's viewers when the old link dropped.
        for (id, size) in terminalSizes where terminalSinks[id] != nil {
            _ = try? await peer.request(.terminalAttach, params: try .encode(TerminalSizeParams(id: id, cols: size.cols, rows: size.rows)))
        }
        for session in agentEvents.keys { await attachAgent(session) }
    }

    /// Only the current link's end counts; an old link ending later must
    /// not clear a healthy newer one.
    private func dropped(_ reason: String?, peer ended: RPCPeer? = nil) {
        guard let current = peer, ended == nil || ended === current else { return }
        peer = nil
        status = online ? .failed(reason ?? "Disconnected") : .offline
        scheduleRetry()
    }

    /// After the app was suspended: a link that doesn't answer in 3 s is dead
    /// (ICE would take ~30 s to say so); drop it and dial again now.
    func probe() async {
        guard let peer else { if online, dialTask == nil { connect() }; return }
        do {
            _ = try await peer.request(.hello, params: nil, timeout: .seconds(3))
        } catch {
            guard self.peer === peer else { return }
            peer.close()
            dropped("No answer after resuming", peer: peer)
        }
    }

    func disconnect() {
        dialTask?.cancel()
        dialTask = nil
        online = false
        peer?.close()
        peer = nil
        status = .offline
    }

    func refreshAll() async {
        guard let peer else { return }
        hello = try? await peer.request(.hello, as: HostHello.self)
        async let conversations = try? peer.request(.conversationList, as: [ConversationInfo].self)
        async let agents = try? peer.request(.agentList, as: [AgentSessionInfo].self)
        async let terminals = try? peer.request(.terminalList, as: [TerminalInfo].self)
        async let harnesses = try? peer.request(.agentHarnesses, as: [AgentHarness].self)
        if let value = await conversations { self.conversations = value }
        if let value = await agents { self.agents = value }
        if let value = await terminals { self.terminals = value }
        if let value = await harnesses { self.harnesses = value }
    }

    func loadProjects() async {
        guard let peer else { return }
        if let value = try? await peer.request(.projectList, as: [ProjectInfo].self) { projects = value }
    }

    // MARK: Notifications

    private func handle(_ method: String, _ params: JSONValue?) {
        guard let params else { return }
        switch RPCMethod(rawValue: method) {
        case .conversationMessage:
            guard let message = try? params.decode(ConversationMessage.self) else { return }
            var list = messages[message.conversation] ?? []
            if let index = list.firstIndex(where: { $0.id == message.id || ($0.clientID != nil && $0.clientID == message.clientID) }) {
                list[index] = message
            } else {
                list.append(message)
            }
            messages[message.conversation] = list
        case .conversationChanged:
            if params["deleted"]?.boolValue == true, let id = params["id"]?.stringValue {
                conversations.removeAll { $0.id == id }
                return
            }
            guard let info = try? params.decode(ConversationInfo.self) else { return }
            if let index = conversations.firstIndex(where: { $0.id == info.id }) {
                conversations[index] = info
            } else {
                conversations.append(info)
            }
        case .conversationTyping:
            guard let typing = try? params.decode(ConversationTyping.self) else { return }
            if typing.typing { self.typing.insert(typing.conversation) } else { self.typing.remove(typing.conversation) }
        case .agentChanged:
            guard let info = try? params.decode(AgentSessionInfo.self) else { return }
            if let index = agents.firstIndex(where: { $0.id == info.id }) { agents[index] = info } else { agents.append(info) }
        case .agentEvent:
            guard let event = try? params.decode(AgentEvent.self) else { return }
            if attaching[event.session] != nil {
                attaching[event.session]?.append(event)
                return
            }
            guard var events = agentEvents[event.session] else { return }
            let lastSeq = events.last?.seq ?? -1
            if event.seq == lastSeq + 1 {
                events.append(event)
                agentEvents[event.session] = events
            } else if event.seq > lastSeq + 1 {
                // A gap (a dropped notification): reload the log.
                Task { await attachAgent(event.session) }
            }
        case .terminalChanged:
            if params["removed"]?.boolValue == true, let id = params["id"]?.intValue {
                terminals.removeAll { $0.id == UInt32(clamping: id) }
                return
            }
            guard let info = try? params.decode(TerminalInfo.self) else { return }
            if let index = terminals.firstIndex(where: { $0.id == info.id }) { terminals[index] = info } else { terminals.append(info) }
        default:
            break
        }
    }

    // MARK: Requests

    private func requirePeer() throws -> RPCPeer {
        guard let peer else { throw RPCError(code: -32000, message: "\(name) is not connected") }
        return peer
    }

    func loadMessages(_ conversation: String) async {
        guard let peer else { return }
        guard let list = try? await peer.request(
            .conversationMessages, ConversationIDParams(conversation: conversation), as: [ConversationMessage].self
        ) else { return }
        // Keep what arrived meanwhile: notifications and unconfirmed sends.
        let known = Set(list.map(\.id))
        let clientIDs = Set(list.compactMap(\.clientID))
        let extra = (messages[conversation] ?? []).filter {
            !known.contains($0.id) && !($0.clientID.map(clientIDs.contains) ?? false)
        }
        messages[conversation] = (list + extra).sorted { $0.sentAt < $1.sentAt }
    }

    @discardableResult
    func send(text: String, to conversation: String) -> ConversationMessage {
        let clientID = UUID().uuidString
        let pending = ConversationMessage(
            id: "pending-" + clientID, conversation: conversation, sender: "me", text: text, sentAt: .now, clientID: clientID
        )
        messages[conversation, default: []].append(pending)
        Task {
            _ = try? await requirePeer().request(
                .conversationSend, ConversationSendParams(conversation: conversation, text: text, clientID: clientID),
                as: ConversationMessage.self
            )
        }
        return pending
    }

    func createConversation(firstMessage: String?) async throws -> ConversationInfo {
        let info = try await requirePeer().request(
            .conversationCreate, ConversationCreateParams(firstMessage: firstMessage, clientID: UUID().uuidString),
            as: ConversationInfo.self
        )
        if !conversations.contains(where: { $0.id == info.id }) { conversations.append(info) }
        return info
    }

    func markRead(_ conversation: String) {
        if let index = conversations.firstIndex(where: { $0.id == conversation }) { conversations[index].unreadCount = 0 }
        Task { _ = try? await requirePeer().request(.conversationRead, params: try .encode(ConversationIDParams(conversation: conversation))) }
    }

    func markUnread(_ conversation: String) {
        if let index = conversations.firstIndex(where: { $0.id == conversation }) {
            conversations[index].unreadCount = max(1, conversations[index].unreadCount)
        }
        Task { _ = try? await requirePeer().request(.conversationRead, params: try .encode(ConversationIDParams(conversation: conversation, flag: false))) }
    }

    func setPinned(_ conversation: String, _ pinned: Bool) {
        if let index = conversations.firstIndex(where: { $0.id == conversation }) { conversations[index].pinned = pinned }
        Task { _ = try? await requirePeer().request(.conversationPin, params: try .encode(ConversationIDParams(conversation: conversation, flag: pinned))) }
    }

    func deleteConversation(_ conversation: String) {
        conversations.removeAll { $0.id == conversation }
        Task { _ = try? await requirePeer().request(.conversationDelete, params: try .encode(ConversationIDParams(conversation: conversation))) }
    }

    func react(_ conversation: String, message: String, reaction: String?) {
        if var list = messages[conversation], let index = list.firstIndex(where: { $0.id == message }) {
            if let reaction { list[index].reactions["me"] = reaction } else { list[index].reactions.removeValue(forKey: "me") }
            messages[conversation] = list
        }
        Task {
            _ = try? await requirePeer().request(
                .conversationReact, params: try .encode(ConversationReactParams(conversation: conversation, message: message, reaction: reaction))
            )
        }
    }

    // Agents

    func attachAgent(_ session: String) async {
        guard let peer, attaching[session] == nil else { return }
        attaching[session] = []
        defer { attaching[session] = nil }
        guard let result = try? await peer.request(.agentAttach, AgentSessionParams(session: session), as: AgentAttachResult.self) else {
            return
        }
        var events = result.events
        for event in (attaching[session] ?? []).sorted(by: { $0.seq < $1.seq }) where event.seq == (events.last?.seq ?? -1) + 1 {
            events.append(event)
        }
        agentEvents[session] = events
        if let index = agents.firstIndex(where: { $0.id == session }) { agents[index] = result.info }
    }

    func createAgent(harness: String, cwd: String, prompt: [JSONValue]?) async throws -> AgentSessionInfo {
        let info = try await requirePeer().request(
            .agentCreate, AgentCreateParams(harness: harness, cwd: cwd, prompt: prompt), as: AgentSessionInfo.self, timeout: .seconds(120)
        )
        if !agents.contains(where: { $0.id == info.id }) { agents.append(info) }
        agentEvents[info.id] = agentEvents[info.id] ?? []
        return info
    }

    func prompt(_ session: String, blocks: [JSONValue]) async throws {
        // The Mac may first restart the agent (install, load its session).
        _ = try await requirePeer().request(.agentPrompt, params: try .encode(AgentPromptParams(session: session, prompt: blocks)), timeout: .seconds(180))
    }

    func cancel(_ session: String) {
        Task { _ = try? await requirePeer().request(.agentCancel, params: try .encode(AgentSessionParams(session: session))) }
    }

    func setMode(_ session: String, _ mode: String) {
        Task { _ = try? await requirePeer().request(.agentSetMode, params: try .encode(AgentSessionParams(session: session, value: mode))) }
    }

    func setModel(_ session: String, _ model: String) {
        Task { _ = try? await requirePeer().request(.agentSetModel, params: try .encode(AgentSessionParams(session: session, value: model))) }
    }

    func answerPermission(_ session: String, request: String, option: String?) {
        Task {
            _ = try? await requirePeer().request(
                .agentPermission, params: try .encode(AgentPermissionParams(session: session, request: request, optionID: option))
            )
        }
    }

    func archiveAgent(_ session: String) {
        if let index = agents.firstIndex(where: { $0.id == session }) { agents[index].archived = true }
        Task { _ = try? await requirePeer().request(.agentArchive, params: try .encode(AgentSessionParams(session: session))) }
    }

    // Terminals

    func createTerminal(cwd: String?, cols: Int, rows: Int) async throws -> TerminalInfo {
        let info = try await requirePeer().request(.terminalCreate, TerminalCreateParams(cwd: cwd, cols: cols, rows: rows), as: TerminalInfo.self)
        if !terminals.contains(where: { $0.id == info.id }) { terminals.append(info) }
        return info
    }

    func attachTerminal(_ id: UInt32, cols: Int, rows: Int, sink: @escaping (BulkFrame) -> Void) async throws {
        terminalSinks[id] = sink
        terminalSizes[id] = (cols, rows)
        _ = try await requirePeer().request(.terminalAttach, params: try .encode(TerminalSizeParams(id: id, cols: cols, rows: rows)))
    }

    func detachTerminal(_ id: UInt32) {
        terminalSinks.removeValue(forKey: id)
        terminalSizes.removeValue(forKey: id)
        Task { _ = try? await requirePeer().request(.terminalDetach, params: try .encode(TerminalIDParams(id: id))) }
    }

    func resizeTerminal(_ id: UInt32, cols: Int, rows: Int) {
        if terminalSinks[id] != nil { terminalSizes[id] = (cols, rows) }
        Task { _ = try? await requirePeer().request(.terminalResize, params: try .encode(TerminalSizeParams(id: id, cols: cols, rows: rows))) }
    }

    func closeTerminal(_ id: UInt32) {
        Task { _ = try? await requirePeer().request(.terminalClose, params: try .encode(TerminalIDParams(id: id))) }
    }

    func sendTerminalInput(_ id: UInt32, _ data: Data) {
        try? peer?.send(BulkFrame(kind: .input, terminal: id, payload: data))
    }
}
