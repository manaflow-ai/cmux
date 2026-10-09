import CNCore
import CNTransport
import Foundation

/// All demo host state. One per `MockHost`; shared by every link.
actor MockEngine {
    let options: MockHost.Options
    let clock: any Clock<Duration>
    let fixtures: MockFixtures

    var sessions: [UUID: MockServerSession] = [:]

    // Conversations
    var conversations: [String: Conversation] = [:]
    var messages: [String: [Message]] = [:]
    var conversationTasks: [String: Task<Void, Never>] = [:]

    // Agents
    var harnessList: [Harness] = []
    var agentSessions: [String: AgentSession] = [:]
    var transcripts: [String: [TranscriptItem]] = [:]
    var turnTasks: [String: Task<Void, Never>] = [:]
    var permissionWaiters: [String: CheckedContinuation<String?, Never>] = [:]

    // Terminals
    var terminals: [String: MockTerminal] = [:]
    var terminalOrder: [String] = []

    // Browser
    var tabs: [String: MockTab] = [:]
    var tabOrder: [String] = []
    var browserStreams: [UInt32: MockBrowserStream] = [:]

    // Streams
    var nextStreamId: UInt32 = 1
    var streamOwners: [UInt32: UUID] = [:]
    var terminalStreams: [UInt32: String] = [:]

    var idCounter = 0

    init(options: MockHost.Options) {
        self.options = options
        self.clock = options.clock
        let fixtures = MockFixtures(now: Date())
        self.fixtures = fixtures
        for c in fixtures.conversations { conversations[c.id] = c }
        messages = fixtures.messages
        harnessList = fixtures.harnesses
        for s in fixtures.agentSessions { agentSessions[s.id] = s }
        transcripts = fixtures.transcripts
        for t in fixtures.terminals() {
            terminals[t.info.id] = t
            terminalOrder.append(t.info.id)
        }
        for t in fixtures.tabs() {
            tabs[t.tab.id] = t
            tabOrder.append(t.tab.id)
        }
    }

    // MARK: Sessions

    func register(_ session: MockServerSession) {
        sessions[session.id] = session
    }

    func unregister(_ session: MockServerSession) {
        sessions[session.id] = nil
        for (streamId, owner) in streamOwners where owner == session.id {
            releaseStream(streamId)
        }
    }

    func dropAllLinks() {
        for s in sessions.values { s.link.transport.close() }
    }

    func releaseStream(_ streamId: UInt32) {
        streamOwners[streamId] = nil
        if let terminalId = terminalStreams.removeValue(forKey: streamId) {
            terminals[terminalId]?.streams.remove(streamId)
            updateTerminalAnimation(terminalId)
        }
        if let stream = browserStreams.removeValue(forKey: streamId) {
            stream.task?.cancel()
        }
    }

    func allocateStream(for session: MockServerSession) -> UInt32 {
        let id = nextStreamId
        nextStreamId += 1
        streamOwners[id] = session.id
        return id
    }

    func sendFrame(_ frame: StreamFrame) {
        guard let owner = streamOwners[frame.streamId], let session = sessions[owner] else { return }
        session.sendFrame(frame)
    }

    /// Sends an event to one link only.
    func send(_ topic: HostTopic, _ payload: some Encodable, to sessionId: UUID) {
        let envelope = ControlEnvelope.event(topic: topic.rawValue, payload: (try? JSONValue(encoding: payload)) ?? .null)
        guard let data = try? JSONEncoder().encode(envelope), let session = sessions[sessionId] else { return }
        session.sendEvent(data)
    }

    func broadcast(_ topic: HostTopic, _ payload: some Encodable) {
        let envelope = ControlEnvelope.event(topic: topic.rawValue, payload: (try? JSONValue(encoding: payload)) ?? .null)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        for s in sessions.values { s.sendEvent(data) }
    }

    // MARK: Helpers

    func now() -> EpochMillis { Date().epochMillis }

    func makeId(_ prefix: String) -> String {
        idCounter += 1
        return "\(prefix)_\(idCounter)_\(UInt32.random(in: 0...UInt32.max) & 0xffff)"
    }

    /// Sleeps a simulated delay, scaled by `options.speed`.
    nonisolated func pause(_ milliseconds: Double) async throws {
        let ms = max(1, milliseconds / max(options.speed, 0.001))
        try await clock.sleep(for: .microseconds(Int64(ms * 1000)))
    }

    func decode<T: Decodable>(_ params: JSONValue, _ type: T.Type) throws -> T {
        do { return try params.decode(as: T.self) } catch {
            throw RPCError(code: .badRequest, message: "Invalid params: \(error)")
        }
    }

    func encode(_ value: some Encodable) throws -> JSONValue {
        try JSONValue(encoding: value)
    }

    static let empty: JSONValue = .object([:])

    // MARK: Dispatch

    func handle(method: String, params: JSONValue, session: MockServerSession) async throws -> JSONValue {
        guard let m = HostMethod(rawValue: method) else {
            throw RPCError(code: .unsupported, message: "Unknown method \(method)")
        }
        switch m {
        case .hello:
            _ = try decode(params, HelloParams.self)
            return try encode(HostInfo(hostId: options.hostId, hostName: options.hostName, os: "macOS 26.1 (demo)",
                                       version: "0.1.0-demo", capabilities: HostCapability.allCases.map(\.rawValue)))
        case .ping:
            return try encode(PingResult(at: now()))

        case .convList:
            let list = conversations.values.sorted { ($0.pinned ? 1 : 0, $0.updatedAt) > ($1.pinned ? 1 : 0, $1.updatedAt) }
            return try encode(ConversationList(conversations: list))
        case .convHistory:
            return try encode(conversationHistory(try decode(params, ConversationHistoryParams.self)))
        case .convSend:
            return try encode(MessageResult(message: try sendMessage(try decode(params, ConversationSendParams.self))))
        case .convRead:
            try markRead(try decode(params, ConversationRef.self).conversationId)
            return Self.empty
        case .convSetPinned:
            let p = try decode(params, ConversationPinnedParams.self)
            try mutateConversation(p.conversationId) { $0.pinned = p.pinned }
            return Self.empty
        case .convSetMuted:
            let p = try decode(params, ConversationMutedParams.self)
            try mutateConversation(p.conversationId) { $0.muted = p.muted }
            return Self.empty
        case .convDelete:
            let id = try decode(params, ConversationRef.self).conversationId
            guard conversations.removeValue(forKey: id) != nil else { throw notFound("conversation", id) }
            messages[id] = nil
            broadcast(.convRemoved, ConversationRef(conversationId: id))
            return Self.empty

        case .agentHarnesses:
            return try encode(HarnessList(harnesses: harnessList))
        case .agentList:
            return try encode(AgentSessionList(sessions: agentSessions.values.sorted { $0.updatedAt > $1.updatedAt }))
        case .agentCreate:
            return try encode(AgentSessionResult(session: try createAgent(try decode(params, AgentCreateParams.self))))
        case .agentHistory:
            let id = try decode(params, AgentSessionRef.self).sessionId
            guard var s = agentSessions[id] else { throw notFound("session", id) }
            if s.unread > 0 { s.unread = 0; agentSessions[id] = s; broadcast(.agentSession, AgentSessionResult(session: s)) }
            return try encode(AgentHistory(session: s, items: transcripts[id] ?? [], commands: fixtures.commands))
        case .agentPrompt:
            try prompt(try decode(params, AgentPromptParams.self))
            return Self.empty
        case .agentCancel:
            try cancelTurn(try decode(params, AgentSessionRef.self).sessionId)
            return Self.empty
        case .agentClose:
            let id = try decode(params, AgentSessionRef.self).sessionId
            guard agentSessions[id] != nil else { throw notFound("session", id) }
            turnTasks.removeValue(forKey: id)?.cancel()
            agentSessions[id] = nil
            transcripts[id] = nil
            broadcast(.agentRemoved, AgentSessionRef(sessionId: id))
            return Self.empty
        case .agentPermission:
            try answerPermission(try decode(params, AgentPermissionParams.self))
            return Self.empty
        case .agentSetModel:
            let p = try decode(params, AgentSetModelParams.self)
            try mutateAgent(p.sessionId) { $0.model = p.modelId }
            return Self.empty
        case .agentSetMode:
            let p = try decode(params, AgentSetModeParams.self)
            try mutateAgent(p.sessionId) { $0.mode = p.modeId }
            return Self.empty
        case .agentRename:
            let p = try decode(params, AgentRenameParams.self)
            try mutateAgent(p.sessionId) { $0.title = p.title }
            return Self.empty

        case .termList:
            return try encode(TerminalList(terminals: terminalOrder.compactMap { terminals[$0]?.info }))
        case .termCreate:
            return try encode(TerminalResult(terminal: createTerminal(try decode(params, TerminalCreateParams.self))))
        case .termAttach:
            return try encode(try attachTerminal(try decode(params, TerminalAttachParams.self), session: session))
        case .termDetach:
            releaseStream(try decode(params, StreamRef.self).streamId)
            return Self.empty
        case .termResize:
            let p = try decode(params, TerminalResizeParams.self)
            try mutateTerminal(p.terminalId) { $0.info.cols = p.cols; $0.info.rows = p.rows }
            return Self.empty
        case .termClose:
            try closeTerminal(try decode(params, TerminalRef.self).terminalId)
            return Self.empty
        case .termRename:
            let p = try decode(params, TerminalRenameParams.self)
            try mutateTerminal(p.terminalId) { $0.info.title = p.title }
            return Self.empty

        case .browserList:
            return try encode(BrowserTabList(tabs: tabOrder.compactMap { tabs[$0]?.tab }))
        case .browserCreate:
            return try encode(BrowserTabResult(tab: createTab(url: try decode(params, BrowserCreateParams.self).url)))
        case .browserAttach:
            return try encode(try attachTab(try decode(params, BrowserAttachParams.self), session: session))
        case .browserDetach:
            releaseStream(try decode(params, StreamRef.self).streamId)
            return Self.empty
        case .browserClose:
            try closeTab(try decode(params, BrowserTabRef.self).tabId)
            return Self.empty
        case .browserActivate:
            try activateTab(try decode(params, BrowserTabRef.self).tabId)
            return Self.empty
        case .browserViewport:
            try setViewport(try decode(params, BrowserViewportParams.self))
            return Self.empty
        case .browserAck:
            let p = try decode(params, BrowserAckParams.self)
            ack(streamId: p.streamId, seq: p.seq)
            return Self.empty
        case .browserNavigate:
            let p = try decode(params, BrowserNavigateParams.self)
            try navigate(p.tabId, to: p.url)
            return Self.empty
        case .browserBack:
            try goBack(try decode(params, BrowserTabRef.self).tabId)
            return Self.empty
        case .browserForward:
            try goForward(try decode(params, BrowserTabRef.self).tabId)
            return Self.empty
        case .browserReload:
            let id = try decode(params, BrowserTabRef.self).tabId
            guard let tab = tabs[id] else { throw notFound("tab", id) }
            startLoading(id, url: tab.tab.url, pushHistory: false)
            return Self.empty
        case .browserStop:
            try stopLoading(try decode(params, BrowserTabRef.self).tabId)
            return Self.empty
        case .browserPointer:
            try pointer(try decode(params, BrowserPointerParams.self))
            return Self.empty
        case .browserTouch:
            try touch(try decode(params, BrowserTouchParams.self))
            return Self.empty
        case .browserScroll:
            let p = try decode(params, BrowserScrollParams.self)
            try scroll(p.tabId, dy: p.dy)
            return Self.empty
        case .browserKey:
            try key(try decode(params, BrowserKeyParams.self))
            return Self.empty
        case .browserText:
            let p = try decode(params, BrowserTextParams.self)
            try typeText(p.tabId, p.text)
            return Self.empty
        case .browserScreenshot:
            let id = try decode(params, BrowserTabRef.self).tabId
            return try encode(BrowserScreenshot(dataBase64: try screenshot(id).base64EncodedString()))
        case .fsUpload:
            // Nothing is written: the demo host only names where the file would be.
            let p = try decode(params, FileUploadParams.self)
            let name = p.name.split(separator: "/").last.map(String.init) ?? "upload"
            return try encode(FileUploadResult(path: "/Users/aziz/.cmux-next-host/uploads/\(UUID().uuidString.lowercased())/\(name)"))
        }
    }

    func notFound(_ what: String, _ id: String) -> RPCError {
        RPCError(code: .notFound, message: "No \(what) \(id)")
    }
}
