#if os(macOS)
import CNMProtocol
import CNMTransport
import Foundation

/// Serves phones on any `PeerLink`: routes control requests to the terminal,
/// agent and conversation services and fans their notifications out.
public final class HostServer: @unchecked Sendable {
    public let hostName: String
    public let hostID: String
    public static let version = "0.1.0"

    private let environment: HostEnvironment
    private let agents: AgentManager
    private var conversations: ConversationStore!
    private let lock = NSLock()
    private var peers: [ObjectIdentifier: RPCPeer] = [:]
    private var terminals: [UInt32: PTYTerminal] = [:]
    /// terminal id → peers attached to it.
    private var viewers: [UInt32: Set<ObjectIdentifier>] = [:]
    /// Random start: ids from a previous run of the host must not be reused,
    /// or a phone would mistake a new shell for one that died with it.
    private var nextTerminalID = UInt32.random(in: 1_000...2_000_000_000)
    private var log: @Sendable (String) -> Void

    public init(hostName: String, hostID: String, environment: HostEnvironment, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.hostName = hostName
        self.hostID = hostID
        self.environment = environment
        self.log = log
        agents = AgentManager(environment: environment)
        conversations = ConversationStore(
            environment: environment, agents: agents, hostName: hostName,
            contextProvider: { [weak self] in self?.chiefContext() ?? "" }
        )
        agents.emit = { [weak self] method, params in self?.broadcast(method, params) }
        conversations.emit = { [weak self] method, params in self?.broadcast(method, params) }
    }

    public var connectedPeerCount: Int { lock.withLock { peers.count } }

    /// Closes every phone link and ends every shell and agent this host started.
    public func shutdown() {
        let (links, shells): ([RPCPeer], [PTYTerminal]) = lock.withLock {
            defer {
                peers.removeAll()
                viewers.removeAll()
            }
            return (Array(peers.values), Array(terminals.values))
        }
        for peer in links { peer.close() }
        for shell in shells { shell.terminate() }
        agents.shutdown()
    }

    /// Serves one link until it closes.
    public func serve(_ link: PeerLink) {
        let peer = RPCPeer(link: link)
        let key = ObjectIdentifier(peer)
        lock.withLock { peers[key] = peer }
        log("phone connected: \(link.remotePeerID)")
        peer.start(
            onRequest: { [weak self] method, params in
                guard let self else { throw RPCError.internalError }
                return try await self.handle(method, params, from: key)
            },
            onBulk: { [weak self] frame in self?.handleBulk(frame) },
            orderedPrefixes: ["terminal."]
        )
        Task { [weak self] in
            for await state in link.states {
                if case .connected(let route) = state { self?.log("link \(link.remotePeerID) connected via \(route)") }
            }
            self?.drop(key)
            self?.log("phone disconnected: \(link.remotePeerID)")
        }
    }

    private func drop(_ key: ObjectIdentifier) {
        lock.withLock {
            peers.removeValue(forKey: key)
            for id in viewers.keys { viewers[id]?.remove(key) }
        }
    }

    private func broadcast(_ method: RPCMethod, _ params: JSONValue) {
        let targets = lock.withLock { Array(peers.values) }
        for peer in targets { peer.notify(method, params: params) }
    }

    // MARK: Routing

    private func handle(_ method: String, _ params: JSONValue?, from key: ObjectIdentifier) async throws -> JSONValue {
        let params = params ?? .null
        switch RPCMethod(rawValue: method) {
        case .hello:
            return try .encode(HostHello(
                name: hostName, version: Self.version, hostID: hostID,
                capabilities: ["terminal", "agent", "conversation"], homeDirectory: environment.homeDirectory
            ))
        case .projectList:
            return try .encode(projects())

        case .terminalList:
            return try .encode(lock.withLock { terminals.values.map(\.info) }.sorted { $0.id < $1.id })
        case .terminalCreate:
            let request = try params.decode(TerminalCreateParams.self)
            return try .encode(try createTerminal(request))
        case .terminalAttach:
            let request = try params.decode(TerminalSizeParams.self)
            return try .encode(try attachTerminal(request, key: key))
        case .terminalDetach:
            let request = try params.decode(TerminalIDParams.self)
            _ = lock.withLock { viewers[request.id]?.remove(key) }
            return .null
        case .terminalResize:
            let request = try params.decode(TerminalSizeParams.self)
            terminal(request.id)?.resize(cols: request.cols, rows: request.rows)
            return .null
        case .terminalClose:
            let request = try params.decode(TerminalIDParams.self)
            terminal(request.id)?.terminate()
            return .null
        case .terminalRename:
            let request = try params.decode(TerminalIDParams.self)
            if let title = request.title, let terminal = terminal(request.id) {
                terminal.rename(title)
                broadcast(.terminalChanged, try .encode(terminal.info))
            }
            return .null

        case .agentHarnesses:
            return try .encode(agents.harnesses())
        case .agentList:
            return try .encode(agents.list())
        case .agentCreate:
            return try .encode(try await agents.create(try params.decode(AgentCreateParams.self)))
        case .agentAttach:
            return try .encode(try agents.attach(try params.decode(AgentSessionParams.self).session))
        case .agentDetach:
            return .null
        case .agentPrompt:
            try await agents.prompt(try params.decode(AgentPromptParams.self))
            return .null
        case .agentCancel:
            agents.cancel(try params.decode(AgentSessionParams.self).session)
            return .null
        case .agentSetMode:
            let request = try params.decode(AgentSessionParams.self)
            try await agents.setMode(request.session, request.value ?? "")
            return .null
        case .agentSetModel:
            let request = try params.decode(AgentSessionParams.self)
            try await agents.setModel(request.session, request.value ?? "")
            return .null
        case .agentPermission:
            agents.respondPermission(try params.decode(AgentPermissionParams.self))
            return .null
        case .agentArchive:
            agents.archive(try params.decode(AgentSessionParams.self).session)
            return .null

        case .conversationList:
            return try .encode(conversations.list())
        case .conversationCreate:
            return try .encode(conversations.create(try params.decode(ConversationCreateParams.self)))
        case .conversationMessages:
            return try .encode(try conversations.messages(try params.decode(ConversationIDParams.self)))
        case .conversationSend:
            return try .encode(try conversations.send(try params.decode(ConversationSendParams.self)))
        case .conversationRead:
            let request = try params.decode(ConversationIDParams.self)
            // flag == false marks the conversation unread again.
            conversations.markRead(request.conversation, unread: request.flag == false)
            return .null
        case .conversationDelete:
            conversations.delete(try params.decode(ConversationIDParams.self).conversation)
            return .null
        case .conversationPin:
            let request = try params.decode(ConversationIDParams.self)
            conversations.pin(request.conversation, request.flag ?? true)
            return .null
        case .conversationReact:
            conversations.react(try params.decode(ConversationReactParams.self))
            return .null
        default:
            throw RPCError.methodNotFound
        }
    }

    // MARK: Terminals

    private func terminal(_ id: UInt32) -> PTYTerminal? { lock.withLock { terminals[id] } }

    private func createTerminal(_ request: TerminalCreateParams) throws -> TerminalInfo {
        let id = lock.withLock {
            defer { nextTerminalID += 1 }
            return nextTerminalID
        }
        let cwd = (request.cwd.map { ($0 as NSString).expandingTildeInPath }) ?? environment.homeDirectory
        let terminal = try PTYTerminal(
            id: id, cwd: cwd, cols: request.cols, rows: request.rows,
            command: request.command, environment: environment.shellEnvironment
        )
        terminal.onOutput = { [weak self] data in self?.fanOut(id, data) }
        terminal.onExit = { [weak self] _ in
            guard let self, let terminal = self.terminal(id), let value = try? JSONValue.encode(terminal.info) else { return }
            self.broadcast(.terminalChanged, value)
            // Keep an exited shell's last screen for a while, then free it.
            DispatchQueue.global().asyncAfter(deadline: .now() + 15 * 60) { [weak self] in
                guard let self else { return }
                let removed: Bool = self.lock.withLock {
                    guard self.terminals[id]?.running == false else { return false }
                    self.terminals.removeValue(forKey: id)
                    self.viewers.removeValue(forKey: id)
                    return true
                }
                if removed { self.broadcast(.terminalChanged, ["id": .number(Double(id)), "removed": true]) }
            }
        }
        lock.withLock { terminals[id] = terminal }
        broadcast(.terminalChanged, try .encode(terminal.info))
        return terminal.info
    }

    private func attachTerminal(_ request: TerminalSizeParams, key: ObjectIdentifier) throws -> TerminalInfo {
        guard let terminal = terminal(request.id), let peer = lock.withLock({ peers[key] }) else {
            throw RPCError(code: -32050, message: "No such terminal")
        }
        let size = try JSONEncoder().encode(["cols": terminal.info.cols, "rows": terminal.info.rows])
        var sendError: Error?
        // Replay and registration happen on the pty queue, so output read
        // after the snapshot goes to this viewer live and nothing is lost.
        terminal.withSnapshot { [self] snapshot in
            do {
                try peer.send(BulkFrame(kind: .replayBegin, terminal: request.id, payload: size))
                for chunk in Self.chunks(snapshot) {
                    try peer.send(BulkFrame(kind: .output, terminal: request.id, payload: chunk))
                }
                try peer.send(BulkFrame(kind: .replayEnd, terminal: request.id))
                _ = lock.withLock { viewers[request.id, default: []].insert(key) }
            } catch {
                sendError = error
            }
        }
        if let sendError { throw sendError }
        if request.cols != terminal.info.cols || request.rows != terminal.info.rows {
            terminal.resize(cols: request.cols, rows: request.rows)
        }
        return terminal.info
    }

    private func fanOut(_ id: UInt32, _ data: Data) {
        let targets: [RPCPeer] = lock.withLock {
            (viewers[id] ?? []).compactMap { peers[$0] }
        }
        for peer in targets {
            for chunk in Self.chunks(data) {
                try? peer.send(BulkFrame(kind: .output, terminal: id, payload: chunk))
            }
        }
    }

    private func handleBulk(_ frame: BulkFrame) {
        guard frame.kind == .input else { return }
        terminal(frame.terminal)?.write(frame.payload)
    }

    static func chunks(_ data: Data, size: Int = 16 * 1024) -> [Data] {
        guard data.count > size else { return data.isEmpty ? [] : [data] }
        return stride(from: data.startIndex, to: data.endIndex, by: size).map {
            data.subdata(in: $0..<min($0 + size, data.endIndex))
        }
    }

    // MARK: Projects

    /// Git repositories in the usual places, most recently modified first.
    private func projects() -> [ProjectInfo] {
        let home = environment.homeDirectory
        let roots = ["Development", "Developer", "Projects", "Code", "code", "src", "dev", "work", "repos", "GitHub", "cnm-projects"]
            .map { "\(home)/\($0)" }
        let fm = FileManager.default
        var found: [ProjectInfo] = []
        var seen = Set<String>()
        func consider(_ path: String) {
            guard !seen.contains(path), fm.fileExists(atPath: "\(path)/.git") else { return }
            seen.insert(path)
            let modified = (try? fm.attributesOfItem(atPath: "\(path)/.git"))?[.modificationDate] as? Date
            var branch: String?
            if let head = try? String(contentsOfFile: "\(path)/.git/HEAD", encoding: .utf8),
               head.hasPrefix("ref: refs/heads/")
            {
                branch = head.dropFirst("ref: refs/heads/".count).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            found.append(ProjectInfo(path: path, name: (path as NSString).lastPathComponent, branch: branch, lastUsedAt: modified))
        }
        for root in roots {
            consider(root)
            guard let children = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for child in children where !child.hasPrefix(".") {
                let path = "\(root)/\(child)"
                consider(path)
                if let grandchildren = try? fm.contentsOfDirectory(atPath: path), grandchildren.count < 80 {
                    for grandchild in grandchildren where !grandchild.hasPrefix(".") {
                        consider("\(path)/\(grandchild)")
                    }
                }
            }
        }
        return found.sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }.prefix(60).map { $0 }
    }

    private func chiefContext() -> String {
        let running = agents.list().filter { !$0.archived && $0.state != .exited }
        let agentText = running.isEmpty ? "no agents running" : running.prefix(8).map {
            "\($0.harness) in \(($0.cwd as NSString).lastPathComponent) (\($0.state.rawValue)): \($0.title)"
        }.joined(separator: "; ")
        let terminalCount = lock.withLock { terminals.values.filter(\.running).count }
        let projectText = projects().prefix(8).map(\.path).joined(separator: ", ")
        return "Mac \(hostName); \(agentText); \(terminalCount) terminals open; projects: \(projectText)"
    }
}
#endif
