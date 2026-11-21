#if os(macOS)
import CNMProtocol
import Foundation

/// A harness the host knows how to start.
struct HarnessSpec: Sendable {
    var id: String
    var name: String
    /// Candidate commands, first one found on PATH wins.
    var candidates: [[String]]

    static let builtIn: [HarnessSpec] = [
        HarnessSpec(id: "claude", name: "Claude Code", candidates: [
            ["claude-agent-acp"], ["claude-code-acp"],
            ["npx", "-y", "@agentclientprotocol/claude-agent-acp@latest"],
        ]),
        HarnessSpec(id: "codex", name: "Codex", candidates: [["codex-acp"], ["npx", "-y", "@agentclientprotocol/codex-acp@latest"]]),
        HarnessSpec(id: "gemini", name: "Gemini CLI", candidates: [["gemini", "--experimental-acp"]]),
        HarnessSpec(id: "opencode", name: "OpenCode", candidates: [["opencode", "acp"]]),
    ]
}

/// Runs ACP agent sessions on this Mac and keeps their logs, so a phone can
/// attach, render the whole transcript and follow it live.
final class AgentManager: @unchecked Sendable {
    typealias Emit = @Sendable (RPCMethod, JSONValue) -> Void

    private final class Session: @unchecked Sendable {
        var info: AgentSessionInfo
        /// The log with consecutive text chunks merged; each event keeps the
        /// seq of the last raw event folded into it.
        var events: [AgentEvent] = []
        var nextSeq = 0
        var process: ACPProcess?
        var acpSessionID: String?
        /// While the agent replays history during `session/load`, its updates
        /// are already in our log; drop them.
        var replaying = false
        /// Set while the host stops an agent on purpose (shutdown), so its
        /// exit isn't logged as a crash.
        var stopping = false
        /// A restart in progress; other prompts wait for it.
        var restartTask: Task<Void, Error>?
        var permissionWaiters: [String: CheckedContinuation<String?, Never>] = [:]
        var prompting = false
        init(info: AgentSessionInfo) { self.info = info }
    }

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private let environment: HostEnvironment
    private let storeURL: URL
    var emit: Emit?

    init(environment: HostEnvironment) {
        self.environment = environment
        storeURL = environment.supportDirectory.appendingPathComponent("agents", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        loadPersisted()
    }

    // MARK: Harnesses

    func harnesses() -> [AgentHarness] {
        HarnessSpec.builtIn.map { spec in
            let command = resolve(spec)
            return AgentHarness(
                id: spec.id, name: spec.name, available: command != nil,
                detail: command?.joined(separator: " ")
            )
        }
    }

    private func resolve(_ spec: HarnessSpec) -> [String]? {
        for candidate in spec.candidates where environment.which(candidate[0]) != nil {
            if candidate[0] == "npx", spec.id == "claude", environment.which("claude") == nil { continue }
            if candidate[0] == "npx", spec.id == "codex", environment.which("codex") == nil { continue }
            return candidate
        }
        return nil
    }

    // MARK: Sessions

    func list() -> [AgentSessionInfo] {
        lock.withLock { sessions.values.map(\.info) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func attach(_ id: String) throws -> AgentAttachResult {
        try lock.withLock {
            guard let session = sessions[id] else { throw RPCError(code: -32030, message: "No such agent session") }
            return AgentAttachResult(info: session.info, events: session.events)
        }
    }

    func create(_ params: AgentCreateParams) async throws -> AgentSessionInfo {
        guard let spec = HarnessSpec.builtIn.first(where: { $0.id == params.harness }) else {
            throw RPCError(code: -32031, message: "Unknown agent \(params.harness)")
        }
        guard let command = resolve(spec) else {
            throw RPCError(code: -32032, message: "\(spec.name) is not installed on this Mac")
        }
        let now = Date()
        let id = "ag_" + UUID().uuidString.lowercased().prefix(12)
        let cwd = (params.cwd as NSString).expandingTildeInPath
        let title = params.prompt.flatMap(Self.promptText).map { String($0.prefix(60)) } ?? "New \(spec.name) chat"
        let session = Session(info: AgentSessionInfo(
            id: String(id), harness: spec.id, title: title, cwd: cwd, state: .starting,
            createdAt: now, updatedAt: now
        ))
        lock.withLock { sessions[session.info.id] = session }
        changed(session)

        try await start(session, command: command)
        if let prompt = params.prompt {
            Task { try? await self.prompt(AgentPromptParams(session: session.info.id, prompt: prompt)) }
        }
        return lock.withLock { session.info }
    }

    private func start(_ session: Session, command: [String], resume: String? = nil) async throws {
        let process: ACPProcess
        do {
            process = try ACPProcess(command: command, cwd: session.info.cwd, environment: environment.shellEnvironment)
        } catch {
            setState(session, .failed)
            throw RPCError(code: -32033, message: "Could not start the agent: \(error.localizedDescription)")
        }
        let sessionID = session.info.id
        process.onNotification = { [weak self] method, params in
            guard let self, method == "session/update", let update = params["update"] else { return }
            if let session = self.lock.withLock({ self.sessions[sessionID] }), self.lock.withLock({ session.replaying }) { return }
            self.handleUpdate(sessionID, update)
        }
        process.onRequest = { [weak self] method, params in
            guard let self else { throw RPCError.internalError }
            return try await self.handleAgentRequest(sessionID, method, params)
        }
        process.onExit = { [weak self] status, tail in
            guard let self else { return }
            guard let session = self.lock.withLock({ self.sessions[sessionID] }) else { return }
            // An old process exiting after a restart, or a deliberate stop.
            let current = self.lock.withLock { session.process === process && !session.stopping }
            guard current else { return }
            self.resumeWaiters(session)
            if session.info.state != .exited, session.info.state != .failed {
                let detail = tail.split(separator: "\n").suffix(3).joined(separator: "\n")
                self.append(session, .error, ["message": .string("The agent exited (\(status)). \(detail)")])
                self.setState(session, .exited)
            }
        }
        lock.withLock { session.process = process }

        do {
            let initialized = try await process.request("initialize", [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": true, "writeTextFile": true], "terminal": false],
                "clientInfo": ["name": "cmux-next-mobile", "version": "0.1"],
            ], timeout: .seconds(90))
            let canLoad = initialized["agentCapabilities"]?["loadSession"]?.boolValue == true
            var result: JSONValue = .null
            var acpID: String?
            if let resume, canLoad {
                // Same conversation, new process: the agent keeps its memory.
                lock.withLock { session.replaying = true }
                defer { lock.withLock { session.replaying = false } }
                do {
                    result = try await process.request("session/load", [
                        "sessionId": .string(resume), "cwd": .string(session.info.cwd), "mcpServers": [],
                    ], timeout: .seconds(120))
                    acpID = resume
                } catch {
                    // The old session is gone (file deleted, folder moved): start fresh.
                    append(session, .error, ["message": "Couldn't resume the earlier session; this chat continues in a fresh one."])
                    result = try await process.request("session/new", [
                        "cwd": .string(session.info.cwd), "mcpServers": [],
                    ], timeout: .seconds(90))
                    acpID = result["sessionId"]?.stringValue
                }
            } else {
                if resume != nil {
                    append(session, .error, ["message": "This agent can't resume its old session; it starts fresh with the same folder."])
                }
                result = try await process.request("session/new", [
                    "cwd": .string(session.info.cwd), "mcpServers": [],
                ], timeout: .seconds(90))
                acpID = result["sessionId"]?.stringValue
            }
            if let acpID { persistACPID(session.info.id, acpID) }
            lock.withLock {
                session.acpSessionID = acpID
                if let modes = result["modes"] {
                    session.info.modes = (modes["availableModes"]?.arrayValue ?? []).compactMap(Self.choice)
                    session.info.currentMode = modes["currentModeId"]?.stringValue
                }
                if let models = result["models"] {
                    session.info.models = (models["availableModels"]?.arrayValue ?? []).compactMap { value in
                        guard let id = value["modelId"]?.stringValue else { return nil }
                        return AgentChoice(id: id, name: value["name"]?.stringValue ?? id, detail: value["description"]?.stringValue)
                    }
                    session.info.currentModel = models["currentModelId"]?.stringValue
                }
            }
            setState(session, .idle)
        } catch {
            append(session, .error, ["message": .string("Could not start the agent: \(error.localizedDescription)")])
            setState(session, .failed)
            process.terminate()
            throw error
        }
    }

    private static func choice(_ value: JSONValue) -> AgentChoice? {
        guard let id = value["id"]?.stringValue else { return nil }
        return AgentChoice(id: id, name: value["name"]?.stringValue ?? id, detail: value["description"]?.stringValue)
    }

    static func promptText(_ blocks: [JSONValue]) -> String? {
        let text = blocks.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    func prompt(_ params: AgentPromptParams) async throws {
        guard let session = lock.withLock({ sessions[params.session] }) else {
            throw RPCError(code: -32030, message: "No such agent session")
        }
        if let pending = lock.withLock({ session.restartTask }) { try await pending.value }
        var (process, acpID) = lock.withLock { (session.process, session.acpSessionID) }
        if process?.isRunning != true || acpID == nil {
            // The agent ended (host restart, crash): bring it back first, once.
            guard let spec = HarnessSpec.builtIn.first(where: { $0.id == session.info.harness }), let command = resolve(spec) else {
                throw RPCError(code: -32034, message: "This agent is no longer installed on this Mac.")
            }
            let resumeID = acpID
            let restart: Task<Void, Error> = lock.withLock {
                if let running = session.restartTask { return running }
                let task = makeRestart(session, command: command, resume: resumeID)
                session.restartTask = task
                return task
            }
            defer { lock.withLock { session.restartTask = nil } }
            try await restart.value
            (process, acpID) = lock.withLock { (session.process, session.acpSessionID) }
        }
        guard let process, let acpID else {
            throw RPCError(code: -32034, message: "This agent is no longer running. Start a new chat.")
        }
        append(session, .userPrompt, ["prompt": .array(params.prompt)])
        lock.withLock {
            session.prompting = true
            if session.events.filter({ $0.kind == .userPrompt }).count == 1, session.info.title.hasPrefix("New "),
               let text = Self.promptText(params.prompt)
            {
                session.info.title = String(text.prefix(60))
            }
        }
        setState(session, .working)
        Task {
            do {
                let result = try await process.request("session/prompt", [
                    "sessionId": .string(acpID), "prompt": .array(params.prompt),
                ], timeout: .seconds(60 * 60 * 6))
                self.append(session, .turnEnded, ["stopReason": result["stopReason"] ?? "end_turn"])
            } catch {
                self.append(session, .error, ["message": .string(error.localizedDescription)])
                self.append(session, .turnEnded, ["stopReason": "error"])
            }
            self.lock.withLock { session.prompting = false }
            if session.info.state != .exited { self.setState(session, .idle) }
        }
    }

    private func makeRestart(_ session: Session, command: [String], resume: String?) -> Task<Void, Error> {
        Task { [self] in
            setState(session, .starting)
            try await start(session, command: command, resume: resume)
        }
    }

    func cancel(_ id: String) {
        guard let session = lock.withLock({ sessions[id] }) else { return }
        let (process, acpID, waiters) = lock.withLock { () -> (ACPProcess?, String?, [CheckedContinuation<String?, Never>]) in
            defer { session.permissionWaiters.removeAll() }
            return (session.process, session.acpSessionID, Array(session.permissionWaiters.values))
        }
        for waiter in waiters { waiter.resume(returning: nil) }
        if let process, let acpID { process.notify("session/cancel", ["sessionId": .string(acpID)]) }
    }

    func setMode(_ id: String, _ mode: String) async throws {
        guard let session = lock.withLock({ sessions[id] }) else { throw RPCError(code: -32030, message: "No such agent session") }
        let (process, acpID) = lock.withLock { (session.process, session.acpSessionID) }
        guard let process, let acpID else { throw RPCError(code: -32034, message: "Not running") }
        _ = try await process.request("session/set_mode", ["sessionId": .string(acpID), "modeId": .string(mode)])
        lock.withLock { session.info.currentMode = mode }
        changed(session)
    }

    func setModel(_ id: String, _ model: String) async throws {
        guard let session = lock.withLock({ sessions[id] }) else { throw RPCError(code: -32030, message: "No such agent session") }
        let (process, acpID) = lock.withLock { (session.process, session.acpSessionID) }
        guard let process, let acpID else { throw RPCError(code: -32034, message: "Not running") }
        _ = try await process.request("session/set_model", ["sessionId": .string(acpID), "modelId": .string(model)])
        lock.withLock { session.info.currentModel = model }
        changed(session)
    }

    func respondPermission(_ params: AgentPermissionParams) {
        guard let session = lock.withLock({ sessions[params.session] }) else { return }
        let waiter = lock.withLock { session.permissionWaiters.removeValue(forKey: params.request) }
        waiter?.resume(returning: params.optionID)
    }

    /// Open permission requests answer "cancelled" so the agent (and the
    /// phone's card) never wait forever.
    private func resumeWaiters(_ session: Session) {
        let waiters: [CheckedContinuation<String?, Never>] = lock.withLock {
            defer { session.permissionWaiters.removeAll() }
            return Array(session.permissionWaiters.values)
        }
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    /// Stops every running agent (the host is shutting down).
    func shutdown() {
        let all = lock.withLock { Array(sessions.values) }
        for session in all {
            lock.withLock { session.stopping = true }
            resumeWaiters(session)
            session.process?.terminate()
        }
    }

    func archive(_ id: String) {
        guard let session = lock.withLock({ sessions[id] }) else { return }
        resumeWaiters(session)
        lock.withLock { session.info.archived = true }
        session.process?.terminate()
        changed(session)
    }

    // MARK: Agent → client

    private func handleAgentRequest(_ sessionID: String, _ method: String, _ params: JSONValue) async throws -> JSONValue {
        guard let session = lock.withLock({ sessions[sessionID] }) else { throw RPCError.internalError }
        switch method {
        case "session/request_permission":
            let requestID = UUID().uuidString.lowercased()
            var payload = params.objectValue ?? [:]
            payload["requestID"] = .string(requestID)
            setState(session, .awaitingPermission)
            let choice: String? = await withCheckedContinuation { continuation in
                lock.withLock { session.permissionWaiters[requestID] = continuation }
                append(session, .permissionRequest, .object(payload))
            }
            append(session, .permissionResolved, ["requestID": .string(requestID), "optionId": choice.map(JSONValue.string) ?? .null])
            setState(session, .working)
            if let choice {
                return ["outcome": ["outcome": "selected", "optionId": .string(choice)]]
            }
            return ["outcome": ["outcome": "cancelled"]]
        case "fs/read_text_file":
            guard let path = params["path"]?.stringValue else { throw RPCError.invalidParams }
            var text = try String(contentsOfFile: path, encoding: .utf8)
            if let line = params["line"]?.intValue {
                let lines = text.components(separatedBy: "\n")
                let start = max(0, line - 1)
                let limit = max(0, params["limit"]?.intValue ?? lines.count)
                text = lines.dropFirst(start).prefix(limit).joined(separator: "\n")
            }
            return ["content": .string(text)]
        case "fs/write_text_file":
            guard let path = params["path"]?.stringValue, let content = params["content"]?.stringValue else {
                throw RPCError.invalidParams
            }
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return .null
        default:
            throw RPCError.methodNotFound
        }
    }

    private func handleUpdate(_ sessionID: String, _ update: JSONValue) {
        guard let session = lock.withLock({ sessions[sessionID] }) else { return }
        let kind = update["sessionUpdate"]?.stringValue
        if kind == "current_mode_update", let mode = update["currentModeId"]?.stringValue {
            lock.withLock { session.info.currentMode = mode }
            changed(session)
        }
        if kind == "agent_message_chunk", let text = update["content"]?["text"]?.stringValue {
            lock.withLock {
                let previous = session.info.preview ?? ""
                session.info.preview = String((previous + text).suffix(160))
            }
        }
        append(session, .update, update)
    }

    // MARK: Log

    private func append(_ session: Session, _ kind: AgentEvent.Kind, _ payload: JSONValue) {
        let event: AgentEvent = lock.withLock {
            let event = AgentEvent(session: session.info.id, seq: session.nextSeq, kind: kind, at: Date(), payload: payload)
            session.nextSeq += 1
            Self.fold(event, into: &session.events)
            session.info.updatedAt = event.at
            if kind == .userPrompt { session.info.preview = nil }
            return event
        }
        if let value = try? JSONValue.encode(event) { emit?(.agentEvent, value) }
        persist(session, event: event)
    }

    /// Appends `event`, merging a streamed text chunk into the previous event
    /// when both are chunks of the same kind (phones fold them the same way).
    static func fold(_ event: AgentEvent, into events: inout [AgentEvent]) {
        let chunkKinds: Set<String> = ["agent_message_chunk", "agent_thought_chunk"]
        if event.kind == .update,
           let kind = event.payload["sessionUpdate"]?.stringValue, chunkKinds.contains(kind),
           let text = event.payload["content"]?["text"]?.stringValue,
           var last = events.last, last.kind == .update,
           last.payload["sessionUpdate"]?.stringValue == kind,
           let previous = last.payload["content"]?["text"]?.stringValue
        {
            last.payload = ["sessionUpdate": .string(kind), "content": ["type": "text", "text": .string(previous + text)]]
            last.seq = event.seq
            last.at = event.at
            events[events.count - 1] = last
        } else {
            events.append(event)
        }
    }

    private func setState(_ session: Session, _ state: AgentSessionInfo.State) {
        lock.withLock { session.info.state = state }
        changed(session)
    }

    private func changed(_ session: Session) {
        let info = lock.withLock { session.info }
        if let value = try? JSONValue.encode(info) { emit?(.agentChanged, value) }
        persistInfo(info)
    }

    private func persistACPID(_ id: String, _ acpID: String) {
        try? acpID.write(to: storeURL.appendingPathComponent("\(id).acp"), atomically: true, encoding: .utf8)
    }

    private func persistInfo(_ info: AgentSessionInfo) {
        let url = storeURL.appendingPathComponent("\(info.id).json")
        if let data = try? JSONEncoder.cnm.encode(info) { try? data.write(to: url, options: .atomic) }
    }

    private func persist(_ session: Session, event: AgentEvent) {
        let url = storeURL.appendingPathComponent("\(session.info.id).jsonl")
        guard var data = try? JSONEncoder.cnm.encode(event) else { return }
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func loadPersisted() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: storeURL, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var info = try? JSONDecoder.cnm.decode(AgentSessionInfo.self, from: data)
            else { continue }
            if info.state != .failed { info.state = .exited }
            let session = Session(info: info)
            session.acpSessionID = try? String(contentsOf: file.deletingPathExtension().appendingPathExtension("acp"), encoding: .utf8)
            if let log = try? Data(contentsOf: file.deletingPathExtension().appendingPathExtension("jsonl")) {
                let raw = log.split(separator: 0x0A).compactMap { try? JSONDecoder.cnm.decode(AgentEvent.self, from: Data($0)) }
                for event in raw { Self.fold(event, into: &session.events) }
                session.nextSeq = (raw.last?.seq ?? -1) + 1
            }
            sessions[info.id] = session
        }
    }
}
#endif
