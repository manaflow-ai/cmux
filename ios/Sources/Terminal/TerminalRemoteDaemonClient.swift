import Foundation
import OSLog

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "terminal.remote-client")

protocol TerminalRemoteDaemonTransport: Sendable {
    func writeLine(_ line: String) async throws
    func readLine() async throws -> String
}

struct TerminalRemoteDaemonHello: Decodable, Equatable, Sendable {
    let name: String
    let version: String
    let instanceID: String?
    let workspaceCount: Int?
    let changeSeq: UInt64?
    let capabilities: [String]

    init(
        name: String,
        version: String,
        instanceID: String?,
        workspaceCount: Int? = nil,
        changeSeq: UInt64? = nil,
        capabilities: [String]
    ) {
        self.name = name
        self.version = version
        self.instanceID = instanceID
        self.workspaceCount = workspaceCount
        self.changeSeq = changeSeq
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case version
        case instanceID = "instance_id"
        case workspaceCount = "workspace_count"
        case changeSeq = "change_seq"
        case capabilities
    }
}

struct TerminalRemoteDaemonAttachmentStatus: Decodable, Equatable, Sendable {
    let attachmentID: String
    let cols: Int
    let rows: Int
    let mode: String?
    let updatedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case attachmentID = "attachment_id"
        case cols
        case rows
        case mode
        case updatedAt = "updated_at"
    }
}

struct TerminalRemoteDaemonSessionStatus: Decodable, Equatable, Sendable {
    let sessionID: String
    let attachments: [TerminalRemoteDaemonAttachmentStatus]
    let effectiveCols: Int
    let effectiveRows: Int
    let lastKnownCols: Int
    let lastKnownRows: Int
    /// Monotonic counter bumped by the daemon on every effective-size
    /// change. Optional for back-compat with older daemons; clients that
    /// need strict ordering should treat nil as "not reported / always
    /// apply the first one seen".
    let gridGeneration: UInt64?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case attachments
        case effectiveCols = "effective_cols"
        case effectiveRows = "effective_rows"
        case lastKnownCols = "last_known_cols"
        case lastKnownRows = "last_known_rows"
        case gridGeneration = "grid_generation"
    }
}

struct TerminalRemoteDaemonTerminalOpenResult: Decodable, Equatable, Sendable {
    let sessionID: String
    let attachmentID: String
    let attachments: [TerminalRemoteDaemonAttachmentStatus]
    let effectiveCols: Int
    let effectiveRows: Int
    let lastKnownCols: Int
    let lastKnownRows: Int
    let offset: UInt64
    /// See TerminalRemoteDaemonSessionStatus.gridGeneration.
    let gridGeneration: UInt64?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case attachmentID = "attachment_id"
        case attachments
        case effectiveCols = "effective_cols"
        case effectiveRows = "effective_rows"
        case lastKnownCols = "last_known_cols"
        case lastKnownRows = "last_known_rows"
        case offset
        case gridGeneration = "grid_generation"
    }
}

struct TerminalRemoteDaemonTerminalReadResult: Decodable, Equatable, Sendable {
    let sessionID: String
    let offset: UInt64
    let baseOffset: UInt64
    let truncated: Bool
    let eof: Bool
    let data: Data

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case offset
        case baseOffset = "base_offset"
        case truncated
        case eof
        case data
    }

    init(
        sessionID: String,
        offset: UInt64,
        baseOffset: UInt64,
        truncated: Bool,
        eof: Bool,
        data: Data
    ) {
        self.sessionID = sessionID
        self.offset = offset
        self.baseOffset = baseOffset
        self.truncated = truncated
        self.eof = eof
        self.data = data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        offset = try container.decode(UInt64.self, forKey: .offset)
        baseOffset = try container.decode(UInt64.self, forKey: .baseOffset)
        truncated = try container.decode(Bool.self, forKey: .truncated)
        eof = try container.decode(Bool.self, forKey: .eof)

        let encodedData = try container.decode(String.self, forKey: .data)
        guard let decodedData = Data(base64Encoded: encodedData) else {
            throw DecodingError.dataCorruptedError(
                forKey: .data,
                in: container,
                debugDescription: "terminal.read data was not valid base64"
            )
        }
        data = decodedData
    }
}

struct TerminalRemoteDaemonWorkspacePane: Decodable, Equatable, Sendable {
    let id: String
    let sessionID: String?
    let title: String?
    let directory: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case title
        case directory
    }
}

struct TerminalRemoteDaemonWorkspaceEntry: Decodable, Equatable, Sendable {
    let id: String
    let title: String
    let directory: String
    let focusedPaneID: String?
    let paneCount: Int
    let createdAt: Int64
    let lastActivityAt: Int64
    let sessionID: String?
    let preview: String?
    let unreadCount: Int?
    let pinned: Bool?
    let panes: [TerminalRemoteDaemonWorkspacePane]?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case directory
        case focusedPaneID = "focused_pane_id"
        case paneCount = "pane_count"
        case createdAt = "created_at"
        case lastActivityAt = "last_activity_at"
        case sessionID = "session_id"
        case preview
        case unreadCount = "unread_count"
        case pinned
        case panes
    }
}

/// Response from `workspace.create` (daemon returns minted workspace_id).
struct TerminalRemoteDaemonWorkspaceCreateResult: Decodable, Equatable, Sendable {
    let workspaceID: String
    let changeSeq: UInt64

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case changeSeq = "change_seq"
    }
}

/// Response from `workspace.open_pane` — daemon-minted session_id and
/// pane_id for a fresh shell in the given workspace. This is the
/// canonical way clients obtain a session_id without inventing one.
struct TerminalRemoteDaemonWorkspaceOpenPaneResult: Decodable, Equatable, Sendable {
    let workspaceID: String
    let paneID: String
    let sessionID: String
    let attachmentID: String
    let offset: UInt64
    let effectiveCols: Int
    let effectiveRows: Int
    /// See TerminalRemoteDaemonSessionStatus.gridGeneration.
    let gridGeneration: UInt64?

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case paneID = "pane_id"
        case sessionID = "session_id"
        case attachmentID = "attachment_id"
        case offset
        case effectiveCols = "effective_cols"
        case effectiveRows = "effective_rows"
        case gridGeneration = "grid_generation"
    }
}

struct TerminalRemoteDaemonWorkspaceListResult: Decodable, Equatable, Sendable {
    let workspaces: [TerminalRemoteDaemonWorkspaceEntry]
    let selectedWorkspaceID: String?
    let changeSeq: UInt64

    private enum CodingKeys: String, CodingKey {
        case workspaces
        case selectedWorkspaceID = "selected_workspace_id"
        case changeSeq = "change_seq"
    }
}

struct TerminalRemoteDaemonSessionListEntry: Decodable, Equatable, Sendable {
    let sessionID: String
    let attachmentCount: Int
    let effectiveCols: Int
    let effectiveRows: Int

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case attachmentCount = "attachment_count"
        case effectiveCols = "effective_cols"
        case effectiveRows = "effective_rows"
    }
}

struct TerminalRemoteDaemonSessionListResult: Decodable, Equatable, Sendable {
    let sessions: [TerminalRemoteDaemonSessionListEntry]
}

struct TerminalRemoteDaemonSessionHistoryResult: Decodable, Equatable, Sendable {
    let sessionID: String
    let history: String
    let nextOffset: UInt64?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case history
        case nextOffset = "next_offset"
    }

    init(sessionID: String, history: String, nextOffset: UInt64? = nil) {
        self.sessionID = sessionID
        self.history = history
        self.nextOffset = nextOffset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        history = try container.decode(String.self, forKey: .history)
        nextOffset = try container.decodeIfPresent(UInt64.self, forKey: .nextOffset)
    }
}

struct TerminalNotificationsPayload: Sendable, Equatable {
    struct CommandFinished: Sendable, Equatable {
        let exitCode: Int?
    }
    struct Notification: Sendable, Equatable {
        let title: String?
        let body: String?
    }
    let bell: Bool
    let commandFinished: CommandFinished?
    let notification: Notification?
}

enum TerminalPushEvent: Sendable {
    case output(
        data: Data,
        offset: UInt64,
        baseOffset: UInt64,
        truncated: Bool,
        eof: Bool,
        seq: UInt64,
        notifications: TerminalNotificationsPayload?
    )
    case eof
    /// Daemon-authoritative rendering grid. Emitted unconditionally by
    /// the daemon on every attach/resize/detach/open (and also inlined
    /// in RPC responses), so this is the single source of truth for
    /// how big the local Ghostty surface should be. Clients apply it
    /// directly; any remaining container area is letterboxed.
    case viewSize(cols: Int, rows: Int)
}

protocol TerminalRemoteDaemonPushSubscribing: Sendable {
    func setPushHandler(sessionID: String, handler: @escaping @Sendable (TerminalPushEvent) -> Void) async
    func removePushHandler(sessionID: String) async
    func terminalSubscribe(sessionID: String, offset: UInt64?) async throws -> TerminalRemoteDaemonTerminalReadResult
}

enum TerminalRemoteDaemonClientError: LocalizedError, Equatable {
    case invalidJSON(String)
    case missingResult
    case rpc(code: String, message: String)
    case rpcTimeout
    case transportClosed

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let line):
            return "Invalid daemon response: \(line)"
        case .missingResult:
            return "Daemon response was missing a result payload."
        case .rpc(let code, let message):
            return "Daemon RPC failed (\(code)): \(message)"
        case .rpcTimeout:
            return "RPC call timed out waiting for a response."
        case .transportClosed:
            return "Daemon transport closed."
        }
    }
}

/// State for an in-flight RPC request slot. The slot is created
/// synchronously in `sendRequest` before the transport.writeLine await
/// so a response that arrives while the caller is between writeLine and
/// the continuation install can be buffered (`.arrived`) and consumed as
/// soon as the caller suspends on its continuation. Without this, the
/// dispatcher's `response for unknown id` drop path was racing every
/// RPC under load and under the in-memory test transport.
private enum PendingRequestSlot {
    case reserved
    case awaiting(CheckedContinuation<String, Error>)
    case arrived(String)
}

actor TerminalRemoteDaemonClient {
    private let transport: any TerminalRemoteDaemonTransport
    private let decoder: JSONDecoder
    private let rpcTimeoutSeconds: TimeInterval
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequestSlot] = [:]
    private var pushHandlers: [String: @Sendable (TerminalPushEvent) -> Void] = [:]
    private var workspaceEventHandler: (@Sendable (String) -> Void)?
    /// Buffered workspace.* push lines that arrived before the handler was
    /// installed. The daemon pushes a workspace.changed snapshot the moment
    /// it accepts a connection (so reconnects don't have to wait for the
    /// client's explicit subscribe roundtrip), and the handler is set later
    /// in the subscribe loop. Without this buffer, that early push gets
    /// dropped and we fall back to the slower path.
    private var pendingWorkspaceEvents: [String] = []
    private var dispatcher: Task<Void, Never>?
    private var transportFailure: Error?
    /// Continuations suspended on `awaitClose`. Resumed exactly once by
    /// `failPending` when the dispatcher notices the transport dropped.
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(transport: any TerminalRemoteDaemonTransport, rpcTimeoutSeconds: TimeInterval = 30) {
        self.transport = transport
        self.rpcTimeoutSeconds = rpcTimeoutSeconds
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func isClosed() -> Bool {
        transportFailure != nil
    }

    /// Suspends until the dispatcher observes the transport close. Returns
    /// immediately if the transport already failed. Replaces the previous
    /// 5s polling hello-probe with an event-driven wait.
    func awaitClose() async {
        if transportFailure != nil { return }
        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
        }
    }

    func setPushHandler(sessionID: String, handler: @escaping @Sendable (TerminalPushEvent) -> Void) {
        pushHandlers[sessionID] = handler
        ensureDispatcher()
    }

    func removePushHandler(sessionID: String) {
        pushHandlers.removeValue(forKey: sessionID)
    }

    func setWorkspaceEventHandler(_ handler: @escaping @Sendable (String) -> Void) {
        workspaceEventHandler = handler
        // Drain anything the daemon pushed before this handler was wired
        // (the post-auth workspace.changed snapshot is the common case).
        let buffered = pendingWorkspaceEvents
        pendingWorkspaceEvents.removeAll(keepingCapacity: false)
        for line in buffered { handler(line) }
        ensureDispatcher()
    }

    func clearWorkspaceEventHandler() {
        workspaceEventHandler = nil
    }

    func workspaceRename(workspaceID: String, title: String) async throws {
        _ = try await sendRequest(
            method: "workspace.rename",
            params: ["workspace_id": workspaceID, "title": title],
            as: TerminalRemoteDaemonGenericAck.self
        )
    }

    func workspacePin(workspaceID: String, pinned: Bool) async throws {
        _ = try await sendRequest(
            method: "workspace.pin",
            params: ["workspace_id": workspaceID, "pinned": pinned],
            as: TerminalRemoteDaemonGenericAck.self
        )
    }

    /// Configures the daemon-side APNs forwarder (Phase 4.3). `endpoint` is
    /// the Next.js relay URL the daemon POSTs to; `bearerToken` authenticates
    /// those POSTs; `deviceTokens` is the list of APNs device tokens the
    /// relay should deliver to.
    func configureNotifications(
        endpoint: String,
        bearerToken: String,
        deviceTokens: [String]
    ) async throws {
        _ = try await sendRequest(
            method: "daemon.configure_notifications",
            params: [
                "endpoint": endpoint,
                "bearer_token": bearerToken,
                "device_tokens": deviceTokens,
            ],
            as: TerminalRemoteDaemonGenericAck.self
        )
    }

    func terminalSubscribe(sessionID: String, offset: UInt64?) async throws -> TerminalRemoteDaemonTerminalReadResult {
        var params: [String: Any] = ["session_id": sessionID]
        if let offset {
            params["offset"] = offset
        }
        return try await sendRequest(
            method: "terminal.subscribe",
            params: params,
            as: TerminalRemoteDaemonTerminalReadResult.self
        )
    }

    static func decodeHello(from line: String) throws -> TerminalRemoteDaemonHello {
        let decoder = JSONDecoder()
        return try decodeResponse(from: line, decoder: decoder, as: TerminalRemoteDaemonHello.self)
    }

    func sendHello() async throws -> TerminalRemoteDaemonHello {
        try await sendRequest(method: "hello", params: [:], as: TerminalRemoteDaemonHello.self)
    }

    func ensureSession(sessionID: String?) async throws -> TerminalRemoteDaemonSessionStatus {
        var params: [String: Any] = [:]
        if let sessionID, !sessionID.isEmpty {
            params["session_id"] = sessionID
        }
        return try await sendRequest(method: "session.open", params: params, as: TerminalRemoteDaemonSessionStatus.self)
    }

    func sessionAttach(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int
    ) async throws -> TerminalRemoteDaemonSessionStatus {
        try await sendRequest(
            method: "session.attach",
            params: [
                "session_id": sessionID,
                "attachment_id": attachmentID,
                "cols": cols,
                "rows": rows,
            ],
            as: TerminalRemoteDaemonSessionStatus.self
        )
    }

    func sessionResize(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int
    ) async throws -> TerminalRemoteDaemonSessionStatus {
        try await sendRequest(
            method: "session.resize",
            params: [
                "session_id": sessionID,
                "attachment_id": attachmentID,
                "cols": cols,
                "rows": rows,
            ],
            as: TerminalRemoteDaemonSessionStatus.self
        )
    }

    func sessionDetach(
        sessionID: String,
        attachmentID: String
    ) async throws -> TerminalRemoteDaemonSessionStatus {
        try await sendRequest(
            method: "session.detach",
            params: [
                "session_id": sessionID,
                "attachment_id": attachmentID,
            ],
            as: TerminalRemoteDaemonSessionStatus.self
        )
    }

    func sessionClose(sessionID: String) async throws {
        _ = try await sendRequest(
            method: "session.close",
            params: ["session_id": sessionID],
            as: TerminalRemoteDaemonCloseResult.self
        )
    }

    func workspaceList() async throws -> TerminalRemoteDaemonWorkspaceListResult {
        try await sendRequest(method: "workspace.list", params: [:], as: TerminalRemoteDaemonWorkspaceListResult.self)
    }

    func workspaceSubscribe() async throws -> TerminalRemoteDaemonWorkspaceListResult {
        try await sendRequest(method: "workspace.subscribe", params: [:], as: TerminalRemoteDaemonWorkspaceListResult.self)
    }

    func workspaceCreate(title: String, directory: String? = nil) async throws -> TerminalRemoteDaemonWorkspaceCreateResult {
        var params: [String: Any] = ["title": title]
        if let directory { params["directory"] = directory }
        return try await sendRequest(
            method: "workspace.create",
            params: params,
            as: TerminalRemoteDaemonWorkspaceCreateResult.self
        )
    }

    func workspaceOpenPane(
        workspaceID: String,
        command: String,
        cols: Int,
        rows: Int,
        parentPaneID: String? = nil,
        direction: String? = nil
    ) async throws -> TerminalRemoteDaemonWorkspaceOpenPaneResult {
        var params: [String: Any] = [
            "workspace_id": workspaceID,
            "command": command,
            "cols": max(1, cols),
            "rows": max(1, rows),
        ]
        if let parentPaneID { params["parent_pane_id"] = parentPaneID }
        if let direction { params["direction"] = direction }
        return try await sendRequest(
            method: "workspace.open_pane",
            params: params,
            as: TerminalRemoteDaemonWorkspaceOpenPaneResult.self
        )
    }

    func sessionList() async throws -> TerminalRemoteDaemonSessionListResult {
        try await sendRequest(method: "session.list", params: [:], as: TerminalRemoteDaemonSessionListResult.self)
    }

    func sessionHistory(sessionID: String, format: String = "plain") async throws -> TerminalRemoteDaemonSessionHistoryResult {
        try await sendRequest(
            method: "session.history",
            params: ["session_id": sessionID, "format": format],
            as: TerminalRemoteDaemonSessionHistoryResult.self
        )
    }

    func terminalOpen(
        command: String,
        cols: Int,
        rows: Int,
        sessionID: String? = nil
    ) async throws -> TerminalRemoteDaemonTerminalOpenResult {
        var params: [String: Any] = [
            "command": command,
            "cols": cols,
            "rows": rows,
        ]
        if let sessionID {
            params["session_id"] = sessionID
        }
        return try await sendRequest(
            method: "terminal.open",
            params: params,
            as: TerminalRemoteDaemonTerminalOpenResult.self
        )
    }

    func terminalWrite(sessionID: String, data: Data) async throws {
        _ = try await sendRequest(
            method: "terminal.write",
            params: [
                "session_id": sessionID,
                "write_id": "ios-\(UUID().uuidString.lowercased())",
                "data": data.base64EncodedString(),
            ],
            as: TerminalRemoteDaemonTerminalWriteResult.self
        )
    }

    func terminalRead(
        sessionID: String,
        offset: UInt64,
        maxBytes: Int,
        timeoutMilliseconds: Int
    ) async throws -> TerminalRemoteDaemonTerminalReadResult {
        try await sendRequest(
            method: "terminal.read",
            params: [
                "session_id": sessionID,
                "offset": offset,
                "max_bytes": maxBytes,
                "timeout_ms": timeoutMilliseconds,
            ],
            as: TerminalRemoteDaemonTerminalReadResult.self
        )
    }

    private func sendRequest<ResponsePayload: Decodable>(
        method: String,
        params: [String: Any],
        as responseType: ResponsePayload.Type
    ) async throws -> ResponsePayload {
        if let transportFailure {
            throw transportFailure
        }
        ensureDispatcher()

        let requestID = nextRequestID
        nextRequestID += 1

        let encoded: String
        do {
            encoded = try encodeRequestLine(id: requestID, method: method, params: params)
        } catch {
            throw error
        }

        // Reserve the slot synchronously so the dispatcher can either
        // resume an installed continuation or buffer the response into
        // `.arrived` if it beats sendRequest to the slot swap.
        pendingRequests[requestID] = .reserved

        do {
            try await transport.writeLine(encoded)
        } catch {
            pendingRequests.removeValue(forKey: requestID)
            throw error
        }

        let timeoutTask = Task { [weak self, rpcTimeoutSeconds] in
            try? await Task.sleep(nanoseconds: UInt64(rpcTimeoutSeconds * 1_000_000_000))
            await self?.timeoutPending(id: requestID)
        }
        defer { timeoutTask.cancel() }

        let responseLine: String = try await withCheckedThrowingContinuation { continuation in
            switch pendingRequests[requestID] {
            case .arrived(let line):
                pendingRequests.removeValue(forKey: requestID)
                continuation.resume(returning: line)
            case .reserved:
                pendingRequests[requestID] = .awaiting(continuation)
            case .awaiting, nil:
                // failPending swept the slot (or the state got into an
                // unexpected shape). Either way, surface the failure.
                continuation.resume(throwing: transportFailure ?? TerminalRemoteDaemonClientError.transportClosed)
            }
        }

        return try Self.decodeResponse(from: responseLine, decoder: decoder, as: responseType)
    }

    private func ensureDispatcher() {
        guard dispatcher == nil, transportFailure == nil else { return }
        dispatcher = Task { [weak self] in
            await self?.runDispatcher()
        }
    }

    private func runDispatcher() async {
        while !Task.isCancelled {
            let line: String
            do {
                line = try await transport.readLine()
            } catch {
                failPending(error: error)
                return
            }
            dispatch(line: line)
        }
    }

    private func dispatch(line: String) {
        guard let data = line.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let json = raw as? [String: Any] else {
            log.debug("dispatcher: dropping non-JSON line: \(String(line.prefix(120)), privacy: .public)")
            return
        }

        if let requestID = (json["id"] as? Int) ?? (json["id"] as? NSNumber)?.intValue {
            switch pendingRequests[requestID] {
            case .awaiting(let continuation):
                pendingRequests.removeValue(forKey: requestID)
                continuation.resume(returning: line)
            case .reserved:
                // Response raced ahead of sendRequest's continuation
                // install; buffer it so the caller can consume on resume.
                pendingRequests[requestID] = .arrived(line)
            case .arrived, nil:
                log.debug("dispatcher: response for unknown id \(requestID, privacy: .public)")
            }
            return
        }

        guard let event = json["event"] as? String else {
            log.debug("dispatcher: line missing id and event: \(String(line.prefix(120)), privacy: .public)")
            return
        }

        if event.hasPrefix("workspace.") {
            if let handler = workspaceEventHandler {
                handler(line)
            } else {
                // Buffer for the handler to drain when it's eventually
                // installed. Cap the queue so a misbehaving daemon can't
                // grow unbounded memory.
                if pendingWorkspaceEvents.count < 32 {
                    pendingWorkspaceEvents.append(line)
                }
            }
            return
        }

        guard let sessionID = json["session_id"] as? String else {
            log.debug("dispatcher: event \(event, privacy: .public) missing session_id")
            return
        }
        guard let handler = pushHandlers[sessionID] else {
            log.debug("dispatcher: no push handler for session \(sessionID, privacy: .public) event \(event, privacy: .public)")
            return
        }

        switch event {
        case "terminal.output":
            guard let pushEvent = Self.parseTerminalOutputEvent(json: json) else {
                log.debug("dispatcher: malformed terminal.output for \(sessionID, privacy: .public)")
                return
            }
            handler(pushEvent)
        case "terminal.eof":
            handler(.eof)
        case "session.view_size":
            // Top-level cols/rows. Daemon broadcasts unconditionally on
            // every attach/resize/detach/open; client applies directly
            // (see session_service.broadcastViewSize).
            let cols = (json["cols"] as? Int) ?? (json["cols"] as? NSNumber)?.intValue ?? 0
            let rows = (json["rows"] as? Int) ?? (json["rows"] as? NSNumber)?.intValue ?? 0
            guard cols > 0, rows > 0 else {
                log.debug("dispatcher: malformed session.view_size for \(sessionID, privacy: .public)")
                return
            }
            handler(.viewSize(cols: cols, rows: rows))
        default:
            log.debug("dispatcher: ignoring unknown event \(event, privacy: .public) for \(sessionID, privacy: .public)")
        }
    }

    private static func parseTerminalOutputEvent(json: [String: Any]) -> TerminalPushEvent? {
        let dataString = (json["data"] as? String) ?? ""
        let decoded = dataString.isEmpty ? Data() : Data(base64Encoded: dataString) ?? Data()
        guard let offset = (json["offset"] as? UInt64) ?? (json["offset"] as? NSNumber)?.uint64Value else {
            return nil
        }
        let baseOffset = (json["base_offset"] as? UInt64) ?? (json["base_offset"] as? NSNumber)?.uint64Value ?? 0
        let truncated = (json["truncated"] as? Bool) ?? false
        let eof = (json["eof"] as? Bool) ?? false
        let seq = (json["seq"] as? UInt64) ?? (json["seq"] as? NSNumber)?.uint64Value ?? 0
        let notifications = parseNotificationsPayload(json["notifications"])
        return .output(
            data: decoded,
            offset: offset,
            baseOffset: baseOffset,
            truncated: truncated,
            eof: eof,
            seq: seq,
            notifications: notifications
        )
    }

    private static func parseNotificationsPayload(_ raw: Any?) -> TerminalNotificationsPayload? {
        guard let dict = raw as? [String: Any] else { return nil }
        let bell = (dict["bell"] as? Bool) ?? false
        var commandFinished: TerminalNotificationsPayload.CommandFinished?
        if let cf = dict["command_finished"] as? [String: Any] {
            let exit: Int?
            if let n = cf["exit_code"] as? Int {
                exit = n
            } else if let n = cf["exit_code"] as? NSNumber {
                exit = n.intValue
            } else {
                exit = nil
            }
            commandFinished = .init(exitCode: exit)
        }
        var notification: TerminalNotificationsPayload.Notification?
        if let n = dict["notification"] as? [String: Any] {
            notification = .init(
                title: n["title"] as? String,
                body: n["body"] as? String
            )
        }
        if !bell && commandFinished == nil && notification == nil {
            return nil
        }
        return .init(bell: bell, commandFinished: commandFinished, notification: notification)
    }

    private func timeoutPending(id: Int) {
        // Only time out slots that actually have a continuation parked on
        // them. Reserved/arrived slots are mid-handoff and sendRequest
        // will finish them as soon as it reacquires the actor.
        guard case .awaiting(let continuation) = pendingRequests[id] else { return }
        pendingRequests.removeValue(forKey: id)
        continuation.resume(throwing: TerminalRemoteDaemonClientError.rpcTimeout)
    }

    private func failPending(error: Error) {
        if transportFailure == nil {
            transportFailure = error
        }
        let snapshot = pendingRequests
        pendingRequests.removeAll()
        for (_, slot) in snapshot {
            if case .awaiting(let continuation) = slot {
                continuation.resume(throwing: error)
            }
            // .reserved and .arrived slots are picked up by sendRequest's
            // continuation closure, which will see transportFailure is
            // now set and throw via the `.awaiting, nil` fallback path.
        }
        let closeSnapshot = closeWaiters
        closeWaiters.removeAll()
        for waiter in closeSnapshot {
            waiter.resume()
        }
    }

    private func encodeRequestLine(id: Int, method: String, params: [String: Any]) throws -> String {
        let payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeResponse<ResponsePayload: Decodable>(
        from line: String,
        decoder: JSONDecoder,
        as responseType: ResponsePayload.Type
    ) throws -> ResponsePayload {
        guard let data = line.data(using: .utf8) else {
            throw TerminalRemoteDaemonClientError.invalidJSON(line)
        }

        let envelope: TerminalRemoteDaemonResponseEnvelope<ResponsePayload>
        do {
            envelope = try decoder.decode(TerminalRemoteDaemonResponseEnvelope<ResponsePayload>.self, from: data)
        } catch {
            log.error("RPC decode error: \(String(describing: error), privacy: .public) for type \(String(describing: responseType), privacy: .public) line: \(String(line.prefix(200)), privacy: .public)")
            throw TerminalRemoteDaemonClientError.invalidJSON(line)
        }

        if envelope.ok {
            guard let result = envelope.result else {
                throw TerminalRemoteDaemonClientError.missingResult
            }
            return result
        }

        if let error = envelope.error {
            throw TerminalRemoteDaemonClientError.rpc(code: error.code, message: error.message)
        }

        throw TerminalRemoteDaemonClientError.rpc(code: "unknown", message: "Server returned an error without details")
    }
}

extension TerminalRemoteDaemonClient: TerminalRemoteDaemonSessionClient {}

extension TerminalRemoteDaemonClient: TerminalRemoteDaemonPushSubscribing {}

private struct TerminalRemoteDaemonResponseEnvelope<Result: Decodable>: Decodable {
    let id: Int
    let ok: Bool
    let result: Result?
    let error: TerminalRemoteDaemonRPCErrorPayload?
}

private struct TerminalRemoteDaemonRPCErrorPayload: Decodable {
    let code: String
    let message: String
}

private struct TerminalRemoteDaemonCloseResult: Decodable {
    let sessionID: String
    let closed: Bool

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case closed
    }
}

private struct TerminalRemoteDaemonGenericAck: Decodable {}

private struct TerminalRemoteDaemonTerminalWriteResult: Decodable {
    let sessionID: String
    let written: Int

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case written
    }
}
