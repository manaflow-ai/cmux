#if os(macOS)
import CNMProtocol
import Foundation

/// Text conversations with Chief, the manager agent on this Mac. Chief is an
/// ACP session per conversation; its turns become message bubbles.
final class ConversationStore: @unchecked Sendable {
    typealias Emit = @Sendable (RPCMethod, JSONValue) -> Void

    static let me = Participant(id: "me", name: "Me", kind: .me)
    static let chief = Participant(id: "chief", name: "Chief", kind: .chief)

    private struct Stored: Codable {
        var info: ConversationInfo
        var messages: [ConversationMessage]
    }

    private final class Brain: @unchecked Sendable {
        var process: ACPProcess?
        var acpSessionID: String?
        var reply = ""
        var primed = false
        var queue: [String] = []
        var busy = false
    }

    private let lock = NSLock()
    private var conversations: [String: Stored] = [:]
    private var brains: [String: Brain] = [:]
    private let environment: HostEnvironment
    private let fileURL: URL
    private let chiefDirectory: URL
    private let agents: AgentManager
    private let hostName: String
    private let contextProvider: @Sendable () -> String
    var emit: Emit?

    init(environment: HostEnvironment, agents: AgentManager, hostName: String, contextProvider: @escaping @Sendable () -> String) {
        self.environment = environment
        self.agents = agents
        self.hostName = hostName
        self.contextProvider = contextProvider
        fileURL = environment.supportDirectory.appendingPathComponent("conversations.json")
        chiefDirectory = environment.supportDirectory.appendingPathComponent("chief", isDirectory: true)
        try? FileManager.default.createDirectory(at: chiefDirectory, withIntermediateDirectories: true)
        load()
        if conversations.isEmpty { seedMain() }
    }

    // MARK: Queries

    func list() -> [ConversationInfo] {
        lock.withLock { conversations.values.map(\.info) }
            .sorted { ($0.pinned ? 1 : 0, $0.updatedAt) > ($1.pinned ? 1 : 0, $1.updatedAt) }
    }

    func messages(_ params: ConversationIDParams) throws -> [ConversationMessage] {
        try lock.withLock {
            guard let stored = conversations[params.conversation] else { throw RPCError(code: -32040, message: "No such conversation") }
            var messages = stored.messages
            if let before = params.before { messages = messages.filter { $0.sentAt < before } }
            if let limit = params.limit { messages = Array(messages.suffix(max(0, limit))) }
            return messages
        }
    }

    // MARK: Mutations

    func create(_ params: ConversationCreateParams) -> ConversationInfo {
        let now = Date()
        let info = ConversationInfo(
            id: "cv_" + String(UUID().uuidString.lowercased().prefix(12)),
            title: params.title ?? "Chief",
            participants: [Self.me, Self.chief],
            lastMessage: nil, unreadCount: 0, pinned: false, updatedAt: now
        )
        lock.withLock { conversations[info.id] = Stored(info: info, messages: []) }
        save()
        emitChanged(info.id)
        if let text = params.firstMessage, !text.isEmpty {
            _ = try? send(ConversationSendParams(conversation: info.id, text: text, clientID: params.clientID ?? UUID().uuidString))
        }
        return lock.withLock { conversations[info.id]!.info }
    }

    func send(_ params: ConversationSendParams) throws -> ConversationMessage {
        let message = ConversationMessage(
            id: "m_" + String(UUID().uuidString.lowercased().prefix(16)),
            conversation: params.conversation, sender: Self.me.id, text: params.text,
            sentAt: Date(), clientID: params.clientID
        )
        try lock.withLock {
            guard var stored = conversations[params.conversation] else { throw RPCError(code: -32040, message: "No such conversation") }
            // A new thread takes its name from its first message, so the list
            // isn't a column of "Chief" rows.
            if stored.info.id != "cv_chief", stored.info.title == Self.chief.name,
               !stored.messages.contains(where: { $0.sender == Self.me.id })
            {
                stored.info.title = Self.title(from: params.text)
                conversations[params.conversation] = stored
            }
        }
        insert(message, unread: false)
        think(conversation: params.conversation, text: params.text)
        return message
    }

    func markRead(_ id: String, unread: Bool = false) {
        lock.withLock {
            guard var stored = conversations[id] else { return }
            stored.info.unreadCount = unread ? max(1, stored.info.unreadCount) : 0
            conversations[id] = stored
        }
        save()
        emitChanged(id)
    }

    func delete(_ id: String) {
        let brain = lock.withLock { () -> Brain? in
            conversations.removeValue(forKey: id)
            return brains.removeValue(forKey: id)
        }
        brain?.process?.terminate()
        save()
        emit?(.conversationChanged, ["id": .string(id), "deleted": true])
    }

    func pin(_ id: String, _ pinned: Bool) {
        lock.withLock { conversations[id]?.info.pinned = pinned }
        save()
        emitChanged(id)
    }

    func react(_ params: ConversationReactParams) {
        let updated: ConversationMessage? = lock.withLock {
            guard var stored = conversations[params.conversation],
                  let index = stored.messages.firstIndex(where: { $0.id == params.message })
            else { return nil }
            if let reaction = params.reaction {
                stored.messages[index].reactions[Self.me.id] = reaction
            } else {
                stored.messages[index].reactions.removeValue(forKey: Self.me.id)
            }
            conversations[params.conversation] = stored
            return stored.messages[index]
        }
        save()
        if let updated, let value = try? JSONValue.encode(updated) { emit?(.conversationMessage, value) }
    }

    // MARK: Chief

    private func think(conversation: String, text: String) {
        let brain = lock.withLock { () -> Brain in
            if let brain = brains[conversation] { return brain }
            let brain = Brain()
            brains[conversation] = brain
            return brain
        }
        let startNow: Bool = lock.withLock {
            brain.queue.append(text)
            if brain.busy { return false }
            brain.busy = true
            return true
        }
        guard startNow else { return }
        Task { await self.drain(conversation, brain) }
    }

    private func drain(_ conversation: String, _ brain: Brain) async {
        while true {
            let next: String? = lock.withLock {
                if brain.queue.isEmpty {
                    brain.busy = false
                    return nil
                }
                let joined = brain.queue.joined(separator: "\n")
                brain.queue.removeAll()
                return joined
            }
            guard let next else { return }
            markReadByChief(conversation)
            setTyping(conversation, true)
            let reply = await answer(conversation, brain, next)
            setTyping(conversation, false)
            for bubble in Self.bubbles(from: reply) {
                post(conversation, text: bubble)
            }
        }
    }

    private func answer(_ conversation: String, _ brain: Brain, _ text: String) async -> String {
        do {
            let (process, acpID) = try await ensureBrain(brain)
            let primed = lock.withLock { () -> Bool in
                defer { brain.primed = true }
                brain.reply = ""
                return brain.primed
            }
            var prompt = ""
            if !primed { prompt += Self.instructions(hostName: hostName) + "\n\n" }
            prompt += "[Context — \(contextProvider())]\n\n" + text
            _ = try await process.request("session/prompt", [
                "sessionId": .string(acpID),
                "prompt": [["type": "text", "text": .string(prompt)]],
            ], timeout: .seconds(600))
            let reply = lock.withLock { brain.reply }.trimmingCharacters(in: .whitespacesAndNewlines)
            return await performActions(in: reply)
        } catch {
            lock.withLock {
                brain.process?.terminate()
                brain.process = nil
                brain.acpSessionID = nil
                brain.primed = false
            }
            return "I couldn't think just now: \(error.localizedDescription)"
        }
    }

    private func ensureBrain(_ brain: Brain) async throws -> (ACPProcess, String) {
        if let process = lock.withLock({ brain.process }), process.isRunning, let id = lock.withLock({ brain.acpSessionID }) {
            return (process, id)
        }
        guard let claude = HarnessSpec.builtIn.first(where: { $0.id == "claude" }),
              let command = claude.candidates.first(where: { environment.which($0[0]) != nil && ($0[0] != "npx" || environment.which("claude") != nil) })
        else {
            throw RPCError(code: -32041, message: "Claude Code isn't installed on \(hostName), and Chief runs on it.")
        }
        let process = try ACPProcess(command: command, cwd: chiefDirectory.path, environment: environment.shellEnvironment)
        process.onNotification = { [weak self] method, params in
            guard method == "session/update",
                  params["update"]?["sessionUpdate"]?.stringValue == "agent_message_chunk",
                  let text = params["update"]?["content"]?["text"]?.stringValue
            else { return }
            self?.lock.withLock { brain.reply += text }
        }
        process.onRequest = { method, _ in
            if method == "session/request_permission" {
                return ["outcome": ["outcome": "cancelled"]]
            }
            throw RPCError.methodNotFound
        }
        let id: String
        do {
            _ = try await process.request("initialize", [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
            ], timeout: .seconds(90))
            let result = try await process.request("session/new", ["cwd": .string(chiefDirectory.path), "mcpServers": []], timeout: .seconds(90))
            guard let sessionID = result["sessionId"]?.stringValue else { throw RPCError(code: -32042, message: "Chief did not start") }
            id = sessionID
        } catch {
            process.terminate()
            throw error
        }
        lock.withLock {
            brain.process = process
            brain.acpSessionID = id
            brain.primed = false
        }
        return (process, id)
    }

    static func instructions(hostName: String) -> String {
        """
        You are Chief, the user's manager agent on their Mac "\(hostName)", reached from their iPhone \
        in a text-message conversation. Reply like a sharp colleague texting: short, plain, no headings, \
        no tables, markdown only for inline `code`. Separate distinct thoughts with a blank line; each \
        becomes its own message bubble. Do not use tools yourself.
        To start a coding agent on the Mac for the user, put one line in your reply exactly like:
        /spawn <claude|codex> <absolute project path> :: <task for the agent>
        The line is removed from your message and the agent starts; tell the user you started it.
        """
    }

    /// Runs `/spawn` lines and returns the reply without them.
    private func performActions(in reply: String) async -> String {
        var kept: [String] = []
        var notes: [String] = []
        for line in reply.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("/spawn ") else {
                kept.append(line)
                continue
            }
            let body = trimmed.dropFirst("/spawn ".count)
            let parts = body.components(separatedBy: " :: ")
            let head = parts[0].split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count >= 2, head.count == 2 else { continue }
            let task = parts.dropFirst().joined(separator: " :: ")
            do {
                let info = try await agents.create(AgentCreateParams(
                    harness: head[0], cwd: head[1], prompt: [["type": "text", "text": .string(task)]]
                ))
                notes.append("▸ Started \(info.harness) in \((info.cwd as NSString).lastPathComponent)")
            } catch {
                notes.append("▸ Couldn't start \(head[0]): \(error.localizedDescription)")
            }
        }
        return (kept.joined(separator: "\n") + (notes.isEmpty ? "" : "\n\n" + notes.joined(separator: "\n")))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 32 else { return trimmed.isEmpty ? chief.name : trimmed }
        let cut = trimmed.prefix(32)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }

    /// Splits a reply on blank lines, keeping fenced code together.
    static func bubbles(from reply: String) -> [String] {
        var bubbles: [String] = []
        var current: [String] = []
        var inFence = false
        for line in reply.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            if !inFence, line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { bubbles.append(current.joined(separator: "\n")) }
                current = []
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { bubbles.append(current.joined(separator: "\n")) }
        return bubbles.isEmpty ? ["…"] : bubbles
    }

    // MARK: Plumbing

    private func post(_ conversation: String, text: String) {
        let message = ConversationMessage(
            id: "m_" + String(UUID().uuidString.lowercased().prefix(16)),
            conversation: conversation, sender: Self.chief.id, text: text, sentAt: Date()
        )
        insert(message, unread: true)
    }

    private func insert(_ message: ConversationMessage, unread: Bool) {
        lock.withLock {
            guard var stored = conversations[message.conversation] else { return }
            stored.messages.append(message)
            stored.info.lastMessage = message
            stored.info.updatedAt = message.sentAt
            if unread { stored.info.unreadCount += 1 }
            conversations[message.conversation] = stored
        }
        save()
        if let value = try? JSONValue.encode(message) { emit?(.conversationMessage, value) }
        emitChanged(message.conversation)
    }

    /// Chief has read the user's messages: they show "Read <time>".
    private func markReadByChief(_ conversation: String) {
        let now = Date()
        let updated: [ConversationMessage] = lock.withLock {
            guard var stored = conversations[conversation] else { return [] }
            var changed: [ConversationMessage] = []
            for index in stored.messages.indices where stored.messages[index].sender == Self.me.id && stored.messages[index].readAt == nil {
                stored.messages[index].readAt = now
                changed.append(stored.messages[index])
            }
            conversations[conversation] = stored
            return changed
        }
        guard !updated.isEmpty else { return }
        save()
        for message in updated {
            if let value = try? JSONValue.encode(message) { emit?(.conversationMessage, value) }
        }
    }

    private func setTyping(_ conversation: String, _ typing: Bool) {
        if let value = try? JSONValue.encode(ConversationTyping(conversation: conversation, sender: Self.chief.id, typing: typing)) {
            emit?(.conversationTyping, value)
        }
    }

    private func emitChanged(_ id: String) {
        guard let info = lock.withLock({ conversations[id]?.info }), let value = try? JSONValue.encode(info) else { return }
        emit?(.conversationChanged, value)
    }

    private func seedMain() {
        let now = Date()
        let info = ConversationInfo(
            id: "cv_chief", title: "Chief", participants: [Self.me, Self.chief],
            lastMessage: nil, unreadCount: 1, pinned: true, updatedAt: now
        )
        let hello = ConversationMessage(
            id: "m_hello", conversation: info.id, sender: Self.chief.id,
            text: "Hi, I'm Chief. I run your agents on \(hostName). Text me what you need.",
            sentAt: now
        )
        var stored = Stored(info: info, messages: [hello])
        stored.info.lastMessage = hello
        conversations[info.id] = stored
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder.cnm.decode([Stored].self, from: data)
        else { return }
        for item in stored { conversations[item.info.id] = item }
    }

    private func save() {
        let snapshot = lock.withLock { Array(conversations.values) }
        if let data = try? JSONEncoder.cnm.encode(snapshot) { try? data.write(to: fileURL, options: .atomic) }
    }
}
#endif
