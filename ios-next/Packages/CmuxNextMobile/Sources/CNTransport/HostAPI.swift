import CNCore
import Foundation

/// A decoded host push.
public enum HostPush: Sendable, Hashable {
    case conversationMessage(Message)
    case conversationUpdated(Conversation)
    case typing(TypingEvent)
    case conversationRemoved(conversationId: String)
    case agentSession(AgentSession)
    case agentItem(sessionId: String, item: TranscriptItem)
    case agentRemoved(sessionId: String)
    case terminalUpdated(Terminal)
    case terminalExited(terminalId: String, code: Int)
    case browserTab(BrowserTab)
    case browserClosed(tabId: String)
    /// A topic this client does not know.
    case other(topic: String)

    public init(_ event: HostEvent) throws {
        switch HostTopic(rawValue: event.topic) {
        case .convMessage: self = .conversationMessage(try event.decode(MessageResult.self).message)
        case .convUpdated: self = .conversationUpdated(try event.decode(ConversationResult.self).conversation)
        case .convTyping: self = .typing(try event.decode(TypingEvent.self))
        case .convRemoved: self = .conversationRemoved(conversationId: try event.decode(ConversationRef.self).conversationId)
        case .agentSession: self = .agentSession(try event.decode(AgentSessionResult.self).session)
        case .agentItem:
            let e = try event.decode(AgentItemEvent.self)
            self = .agentItem(sessionId: e.sessionId, item: e.item)
        case .agentRemoved: self = .agentRemoved(sessionId: try event.decode(AgentSessionRef.self).sessionId)
        case .termUpdated: self = .terminalUpdated(try event.decode(TerminalResult.self).terminal)
        case .termExited:
            let e = try event.decode(TerminalExitedEvent.self)
            self = .terminalExited(terminalId: e.terminalId, code: e.code)
        case .browserTab: self = .browserTab(try event.decode(BrowserTabResult.self).tab)
        case .browserClosed: self = .browserClosed(tabId: try event.decode(BrowserClosedEvent.self).tabId)
        case nil: self = .other(topic: event.topic)
        }
    }
}

extension AsyncStream where Element == HostEvent {
    /// Decodes events into `HostPush`, dropping malformed ones.
    public func pushes() -> AsyncStream<HostPush> {
        AsyncStream<HostPush> { continuation in
            let task = Task {
                for await event in self {
                    if let push = try? HostPush(event) { continuation.yield(push) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Decodes the payload of each event as `P`, dropping malformed ones.
    public func decoded<P: Decodable & Sendable>(as type: P.Type) -> AsyncStream<P> {
        AsyncStream<P> { continuation in
            let task = Task {
                for await event in self {
                    if let p = try? event.decode(P.self) { continuation.yield(p) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Typed PROTOCOL §4 calls.
extension HostClient {
    public nonisolated func pushes() -> AsyncStream<HostPush> { events().pushes() }

    // host
    public func hello(_ client: ClientInfo) async throws -> HostInfo {
        try await request(HostMethod.hello.rawValue, HelloParams(client: client))
    }

    public func ping() async throws -> PingResult { try await request(HostMethod.ping.rawValue) }

    // conversations
    public func listConversations() async throws -> [Conversation] {
        try await request(HostMethod.convList.rawValue, as: ConversationList.self).conversations
    }

    public func conversationHistory(_ conversationId: String, before: String? = nil, limit: Int? = nil) async throws -> ConversationHistory {
        try await request(HostMethod.convHistory.rawValue, ConversationHistoryParams(conversationId: conversationId, before: before, limit: limit))
    }

    public func sendMessage(_ conversationId: String, text: String, clientId: String = UUID().uuidString) async throws -> Message {
        try await request(HostMethod.convSend.rawValue, ConversationSendParams(conversationId: conversationId, text: text, clientId: clientId), as: MessageResult.self).message
    }

    public func markConversationRead(_ conversationId: String) async throws {
        try await call(HostMethod.convRead.rawValue, ConversationRef(conversationId: conversationId))
    }

    public func setConversationPinned(_ conversationId: String, pinned: Bool) async throws {
        try await call(HostMethod.convSetPinned.rawValue, ConversationPinnedParams(conversationId: conversationId, pinned: pinned))
    }

    public func setConversationMuted(_ conversationId: String, muted: Bool) async throws {
        try await call(HostMethod.convSetMuted.rawValue, ConversationMutedParams(conversationId: conversationId, muted: muted))
    }

    public func deleteConversation(_ conversationId: String) async throws {
        try await call(HostMethod.convDelete.rawValue, ConversationRef(conversationId: conversationId))
    }

    // agents
    public func harnesses() async throws -> [Harness] {
        try await request(HostMethod.agentHarnesses.rawValue, as: HarnessList.self).harnesses
    }

    public func listAgentSessions() async throws -> [AgentSession] {
        try await request(HostMethod.agentList.rawValue, as: AgentSessionList.self).sessions
    }

    public func createAgentSession(_ params: AgentCreateParams) async throws -> AgentSession {
        try await request(HostMethod.agentCreate.rawValue, params, as: AgentSessionResult.self).session
    }

    public func agentHistory(_ sessionId: String) async throws -> AgentHistory {
        try await request(HostMethod.agentHistory.rawValue, AgentSessionRef(sessionId: sessionId))
    }

    public func prompt(_ sessionId: String, text: String, attachments: [PromptAttachment]? = nil) async throws {
        try await call(HostMethod.agentPrompt.rawValue, AgentPromptParams(sessionId: sessionId, text: text, attachments: attachments))
    }

    public func cancelAgent(_ sessionId: String) async throws {
        try await call(HostMethod.agentCancel.rawValue, AgentSessionRef(sessionId: sessionId))
    }

    public func closeAgent(_ sessionId: String) async throws {
        try await call(HostMethod.agentClose.rawValue, AgentSessionRef(sessionId: sessionId))
    }

    public func answerPermission(_ sessionId: String, itemId: String, optionId: String) async throws {
        try await call(HostMethod.agentPermission.rawValue, AgentPermissionParams(sessionId: sessionId, itemId: itemId, optionId: optionId))
    }

    public func setAgentModel(_ sessionId: String, modelId: String) async throws {
        try await call(HostMethod.agentSetModel.rawValue, AgentSetModelParams(sessionId: sessionId, modelId: modelId))
    }

    public func setAgentMode(_ sessionId: String, modeId: String) async throws {
        try await call(HostMethod.agentSetMode.rawValue, AgentSetModeParams(sessionId: sessionId, modeId: modeId))
    }

    public func renameAgent(_ sessionId: String, title: String) async throws {
        try await call(HostMethod.agentRename.rawValue, AgentRenameParams(sessionId: sessionId, title: title))
    }

    // terminals
    public func listTerminals() async throws -> [Terminal] {
        try await request(HostMethod.termList.rawValue, as: TerminalList.self).terminals
    }

    public func createTerminal(cols: Int, rows: Int, cwd: String? = nil) async throws -> Terminal {
        try await request(HostMethod.termCreate.rawValue, TerminalCreateParams(cols: cols, rows: rows, cwd: cwd), as: TerminalResult.self).terminal
    }

    /// Attaches and returns the result; read output with `openStream(id: result.streamId)`.
    public func attachTerminal(_ terminalId: String, cols: Int, rows: Int) async throws -> TerminalAttachResult {
        try await request(HostMethod.termAttach.rawValue, TerminalAttachParams(terminalId: terminalId, cols: cols, rows: rows))
    }

    public func detachTerminal(streamId: UInt32) async throws {
        closeStream(id: streamId)
        try await call(HostMethod.termDetach.rawValue, StreamRef(streamId: streamId))
    }

    public func resizeTerminal(_ terminalId: String, cols: Int, rows: Int) async throws {
        try await call(HostMethod.termResize.rawValue, TerminalResizeParams(terminalId: terminalId, cols: cols, rows: rows))
    }

    public func closeTerminal(_ terminalId: String) async throws {
        try await call(HostMethod.termClose.rawValue, TerminalRef(terminalId: terminalId))
    }

    public func renameTerminal(_ terminalId: String, title: String) async throws {
        try await call(HostMethod.termRename.rawValue, TerminalRenameParams(terminalId: terminalId, title: title))
    }

    /// Sends raw input bytes (already encoded by the terminal) to a stream.
    public nonisolated func sendTerminalInput(streamId: UInt32, _ bytes: Data) throws {
        try send(StreamFrame(kind: .termInput, streamId: streamId, payload: bytes))
    }

    // browser
    public func listTabs() async throws -> [BrowserTab] {
        try await request(HostMethod.browserList.rawValue, as: BrowserTabList.self).tabs
    }

    public func createTab(url: String? = nil) async throws -> BrowserTab {
        try await request(HostMethod.browserCreate.rawValue, BrowserCreateParams(url: url), as: BrowserTabResult.self).tab
    }

    /// Attaches and returns the result; read frames with `openBrowserStream(id:)`
    /// and acknowledge each with `ackFrame`.
    public func attachTab(_ params: BrowserAttachParams) async throws -> BrowserAttachResult {
        try await request(HostMethod.browserAttach.rawValue, params)
    }

    public func detachTab(streamId: UInt32) async throws {
        closeStream(id: streamId)
        try await call(HostMethod.browserDetach.rawValue, StreamRef(streamId: streamId))
    }

    public func closeTab(_ tabId: String) async throws { try await call(HostMethod.browserClose.rawValue, BrowserTabRef(tabId: tabId)) }
    public func activateTab(_ tabId: String) async throws { try await call(HostMethod.browserActivate.rawValue, BrowserTabRef(tabId: tabId)) }

    public func setViewport(_ params: BrowserViewportParams) async throws { try await call(HostMethod.browserViewport.rawValue, params) }

    public func ackFrame(streamId: UInt32, seq: UInt32) async throws {
        try await call(HostMethod.browserAck.rawValue, BrowserAckParams(streamId: streamId, seq: seq))
    }

    public func navigate(_ tabId: String, to url: String) async throws {
        try await call(HostMethod.browserNavigate.rawValue, BrowserNavigateParams(tabId: tabId, url: url))
    }

    public func goBack(_ tabId: String) async throws { try await call(HostMethod.browserBack.rawValue, BrowserTabRef(tabId: tabId)) }
    public func goForward(_ tabId: String) async throws { try await call(HostMethod.browserForward.rawValue, BrowserTabRef(tabId: tabId)) }
    public func reload(_ tabId: String) async throws { try await call(HostMethod.browserReload.rawValue, BrowserTabRef(tabId: tabId)) }
    public func stopLoading(_ tabId: String) async throws { try await call(HostMethod.browserStop.rawValue, BrowserTabRef(tabId: tabId)) }

    public func pointer(_ params: BrowserPointerParams) async throws { try await call(HostMethod.browserPointer.rawValue, params) }
    public func touch(_ params: BrowserTouchParams) async throws { try await call(HostMethod.browserTouch.rawValue, params) }
    public func scroll(_ params: BrowserScrollParams) async throws { try await call(HostMethod.browserScroll.rawValue, params) }
    public func key(_ params: BrowserKeyParams) async throws { try await call(HostMethod.browserKey.rawValue, params) }

    public func insertText(_ tabId: String, text: String) async throws {
        try await call(HostMethod.browserText.rawValue, BrowserTextParams(tabId: tabId, text: text))
    }

    public func screenshot(_ tabId: String) async throws -> BrowserScreenshot {
        try await request(HostMethod.browserScreenshot.rawValue, BrowserTabRef(tabId: tabId))
    }
}
