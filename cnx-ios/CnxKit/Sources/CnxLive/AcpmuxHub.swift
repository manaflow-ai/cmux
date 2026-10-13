import CmuxAgentQuestion
import CnxAgentChat
import CnxTransport
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "dev.cmux.cnx", category: "acpmux")

/// The app's acpmux client for the connected Mac. It outlives links: each
/// new link binds a fresh `acpmux` channel, runs `initialize` and
/// `_acpmux/watch`, and re-attaches every open chat from its last seq.
@MainActor
@Observable
public final class AcpmuxHub {
    public private(set) var sessions: [String: AcpmuxSession] = [:]
    public private(set) var isReady = false
    /// A failure binding the channel (shown in diagnostics).
    public private(set) var lastError: String?

    @ObservationIgnored private var connection: AcpmuxConnection?
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var sources: [String: WeakSource] = [:]
    /// Watch-level events for the Feed: `(sessionId, notification)`.
    @ObservationIgnored public var onWatchEvent: (@MainActor (AcpmuxHub.WatchEvent) -> Void)?

    public enum WatchEvent: Sendable {
        case sessionChanged(AcpmuxSession, recordKind: String, seq: Int)
        case permissionPending(sessionID: String, permissionID: String, request: JSONValue)
        case permissionResolved(sessionID: String)
    }

    private struct WeakSource { weak var source: AcpmuxSessionSource? }

    public init() {}

    /// Binds a new `acpmux` channel (nil unbinds after a link drop).
    public func bind(_ channel: (any LinkChannel)?) async {
        pumpTask?.cancel()
        if let old = connection { Task { await old.close() } }
        connection = nil
        isReady = false
        for entry in sources.values { entry.source?.linkDown() }
        guard let channel else { return }
        let connection = AcpmuxConnection(channel: channel)
        self.connection = connection
        await connection.start()
        let notifications = connection.notifications
        pumpTask = Task { [weak self] in
            for await notification in notifications {
                self?.handle(notification)
            }
        }
        do {
            _ = try await connection.request("initialize", .object([
                "protocolVersion": .number(1),
                "clientInfo": .object(["name": .string("cmux-ios"), "version": .string("1")]),
                "clientCapabilities": .object([:]),
            ]))
            let watched = try await connection.request("_acpmux/watch", .object(["enabled": .bool(true)]))
            var next: [String: AcpmuxSession] = [:]
            for value in watched["sessions"]?.arrayValue ?? [] {
                if let session = AcpmuxSession(value) { next[session.id] = session }
            }
            sessions = next
            isReady = true
            lastError = nil
            log.info("acpmux ready, \(next.count, privacy: .public) sessions")
            for entry in sources.values { entry.source?.linkUp() }
            await seedPending(connection)
        } catch {
            lastError = LinkController.reason(error)
            log.error("acpmux bind failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Asks that were already open before this connection watched: acpmux
    /// notifies `permission_pending` only for new ones, so read each waiting
    /// session's permission records and report those with no decision.
    private func seedPending(_ connection: AcpmuxConnection) async {
        for session in sessions.values where session.pendingPermissions > 0 {
            guard let page = try? await connection.request("_acpmux/events", .object([
                "sessionId": .string(session.id),
                "beforeSeq": .number(Double(session.lastSeq + 1)),
                "limit": .number(200),
                "kinds": .array([.string("permission_request"), .string("permission_decision")]),
            ])) else { continue }
            let records = page["events"]?.arrayValue ?? []
            let decided = Set(records.compactMap { record -> String? in
                record["kind"]?.stringValue == "permission_decision" ? record["msg"]?["permissionId"]?.stringValue : nil
            })
            for record in records where record["kind"]?.stringValue == "permission_request" {
                guard let id = record["msg"]?["permissionId"]?.stringValue, !decided.contains(id),
                      let request = record["msg"]?["request"] else { continue }
                onWatchEvent?(.permissionPending(sessionID: session.id, permissionID: id, request: request))
            }
        }
    }

    public func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        guard let connection else { throw LinkError(code: "offline", message: "Not connected to the Mac") }
        return try await connection.request(method, params)
    }

    public func notify(_ method: String, _ params: JSONValue) async throws {
        guard let connection else { throw LinkError(code: "offline", message: "Not connected to the Mac") }
        try await connection.notify(method, params)
    }

    /// The chat source for an acpmux session (one per session).
    public func source(sessionID: String, summary: AgentSessionSummary) -> AcpmuxSessionSource {
        if let existing = sources[sessionID]?.source { return existing }
        let source = AcpmuxSessionSource(hub: self, sessionID: sessionID, summary: summary)
        sources[sessionID] = WeakSource(source: source)
        return source
    }

    /// `_acpmux/permission_respond`. Throws the server's refusal (a remote
    /// connection may deny or cancel; an allow needs the Mac's person proof).
    public func respond(sessionID: String, permissionID: String, optionID: String?, answers: JSONValue? = nil) async throws {
        var params: [String: JSONValue] = ["sessionId": .string(sessionID), "permissionId": .string(permissionID)]
        if let optionID { params["optionId"] = .string(optionID) }
        if let answers { params["answers"] = answers }
        _ = try await request("_acpmux/permission_respond", .object(params))
    }

    /// Answers a question with the harness-shaped reply.
    public func answer(_ question: AgentQuestion, with answer: AgentQuestionAnswer) async throws {
        let reply = try question.reply(answer)
        let params = try AcpmuxRecords.convert(reply.params, to: JSONValue.self)
        _ = try await request("_acpmux/permission_respond", params)
    }

    private func handle(_ notification: AcpmuxConnection.Notification) {
        let params = notification.params
        let sessionID = params["sessionId"]?.stringValue
        switch notification.method {
        case "_acpmux/event":
            if let sessionID { sources[sessionID]?.source?.receive(record: params) }
        case "_acpmux/session_changed":
            guard let value = params["session"], let session = AcpmuxSession(value) else { return }
            sessions[session.id] = session
            let kind = params["recordKind"]?.stringValue ?? params["kind"]?.stringValue ?? ""
            let seq = Int(params["seq"]?.numberValue ?? 0)
            onWatchEvent?(.sessionChanged(session, recordKind: kind, seq: seq))
            if params["kind"]?.stringValue == "permission_resolved" { onWatchEvent?(.permissionResolved(sessionID: session.id)) }
            if params["kind"]?.stringValue == "purged" { sessions[session.id] = nil }
        case "_acpmux/permission_pending":
            guard let sessionID, let permissionID = params["permissionId"]?.stringValue, let request = params["request"] else { return }
            onWatchEvent?(.permissionPending(sessionID: sessionID, permissionID: permissionID, request: request))
        case "_acpmux/lagged":
            // Missed notifications: re-run watch and let attached chats fill their gap.
            Task { [weak self] in
                guard let self, let connection = self.connection else { return }
                _ = try? await connection.request("_acpmux/watch", .object(["enabled": .bool(true)]))
                for entry in self.sources.values { entry.source?.linkUp() }
            }
        default:
            break
        }
    }
}

/// `AgentSessionSource` over acpmux: attach with the event stream, page
/// history back, then stream live records; intents become acpmux calls.
@MainActor
public final class AcpmuxSessionSource: AgentSessionSource {
    public private(set) var summary: AgentSessionSummary
    let sessionID: String
    private weak var hub: AcpmuxHub?
    private let records: AcpmuxRecords
    private var continuations: [AsyncStream<AgentSessionEvent>.Continuation] = []
    private var replay: [AgentSessionEvent] = []
    private var lastSeq = 0
    private var attached = false
    private var attaching = false
    /// Records that arrive while attaching are applied after the attach page.
    private var held: [JSONValue] = []
    private var questions: [String: AgentQuestion] = [:]
    /// The history page size and the most records to keep on attach.
    static let pageSize = 400
    static let maxHistory = 2000

    init(hub: AcpmuxHub, sessionID: String, summary: AgentSessionSummary) {
        self.hub = hub
        self.sessionID = sessionID
        self.summary = summary
        records = AcpmuxRecords(sessionID: sessionID)
        if hub.isReady { linkUp() }
    }

    public func events() -> AsyncStream<AgentSessionEvent> {
        let (stream, continuation) = AsyncStream<AgentSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        for event in replay { continuation.yield(event) }
        continuations.append(continuation)
        return stream
    }

    public func send(_ intent: AgentClientIntent) {
        guard let hub else { return }
        let session = JSONValue.string(sessionID)
        Task {
            do {
                switch intent {
                case .prompt(let text, _, let steer):
                    let meta: JSONValue = .object(["acpmux": .object(["promptId": .string(UUID().uuidString.lowercased()), "steer": .bool(steer)])])
                    _ = try await hub.request("session/prompt", .object([
                        "sessionId": session, "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]), "_meta": meta,
                    ]))
                case .cancel:
                    try await hub.notify("session/cancel", .object(["sessionId": session]))
                case .respondPermission(let permissionID, let optionID):
                    try await hub.respond(sessionID: sessionID, permissionID: permissionID, optionID: optionID)
                case .answerQuestion(let questionID, let answer):
                    guard let question = questions[questionID] else { return }
                    try await hub.answer(question, with: answer)
                case .setModel(let id):
                    _ = try await hub.request("session/set_model", .object(["sessionId": session, "modelId": .string(id)]))
                case .setMode(let id):
                    _ = try await hub.request("session/set_mode", .object(["sessionId": session, "modeId": .string(id)]))
                case .setConfigOption(let id, let value):
                    _ = try await hub.request("session/set_config_option", .object(["sessionId": session, "configId": .string(id), "value": .string(value)]))
                case .removeQueued(let promptID):
                    _ = try await hub.request("_acpmux/queue_remove", .object(["sessionId": session, "promptId": .string(promptID)]))
                }
            } catch {
                self.emit(.clientError(AcpmuxSessionSource.message(error)))
            }
        }
    }

    /// Display copy for a refused call.
    static func message(_ error: any Error) -> String {
        if let error = error as? AcpmuxConnection.RPCError {
            switch error.reason {
            case "permission.person_required": return "Approve this on your Mac. A phone can only decline."
            case "trust.pending", "trust.untrusted": return "Trust this folder on your Mac first."
            default: return error.message
            }
        }
        return LinkController.reason(error)
    }

    func linkDown() {
        attached = false
        attaching = false
        emit(.status(.disconnected))
    }

    func linkUp() {
        guard !attaching, let hub, hub.isReady else { return }
        attaching = true
        Task { await attach(hub) }
    }

    private func attach(_ hub: AcpmuxHub) async {
        defer { attaching = false }
        do {
            var params: [String: JSONValue] = [
                "sessionId": .string(sessionID),
                "limit": .number(Double(Self.pageSize)),
                "kinds": .array([.string("transcript")]),
                "eventStream": .bool(true),
            ]
            if lastSeq > 0 { params["afterSeq"] = .number(Double(lastSeq)) }
            let result = try await hub.request("_acpmux/attach", .object(params))
            var page = result["events"]?.arrayValue ?? []
            // First attach: page older records back until the history starts or the cap.
            if lastSeq == 0, result["hasMore"] == .bool(true) {
                while page.count < Self.maxHistory, let oldest = page.first?["seq"]?.numberValue {
                    let older = try await hub.request("_acpmux/events", .object([
                        "sessionId": .string(sessionID), "beforeSeq": .number(oldest),
                        "limit": .number(Double(Self.pageSize)), "kinds": .array([.string("transcript")]),
                    ]))
                    let events = older["events"]?.arrayValue ?? []
                    page = events + page
                    if events.isEmpty || older["hasMore"] != .bool(true) { break }
                }
            }
            if let detail = result["session"], let session = AcpmuxSession(detail) {
                summary.status = session.summaryStatus
                if !session.name.isEmpty { summary.name = session.name }
            }
            attached = true
            for record in page { receive(record: record) }
            let pending = held
            held = []
            for record in pending { receive(record: record) }
            // Permissions still open (records may be older than the page).
            for entry in result["session"]?["pending"]?.arrayValue ?? [] {
                if let id = entry["permissionId"]?.stringValue, let request = entry["request"],
                   let event = records.permission(id, request: request) { emitPermission(event) }
            }
            emit(.status(summary.status))
        } catch {
            emit(.clientError(Self.message(error)))
        }
    }

    func receive(record: JSONValue) {
        guard attached else {
            held.append(record)
            return
        }
        let seq = Int(record["seq"]?.numberValue ?? 0)
        guard seq == 0 || seq > lastSeq else { return }
        if seq > 0 { lastSeq = seq }
        for event in records.map(record) {
            switch event {
            case .permissionRequest, .question:
                emitPermission(event)
            default:
                emit(event)
            }
        }
    }

    private var seenPermissions: Set<String> = []

    private func emitPermission(_ event: AgentSessionEvent) {
        let id: String
        switch event {
        case .permissionRequest(let request): id = request.id
        case .question(let question):
            id = question.id
            questions[question.id] = question
        default: return
        }
        guard seenPermissions.insert(id).inserted else { return }
        emit(event)
    }

    private func emit(_ event: AgentSessionEvent) {
        if case .clientError = event {} else { replay.append(event) }
        for continuation in continuations { continuation.yield(event) }
    }
}
