import CNCore
import Foundation

extension MockEngine {
    func mutateAgent(_ id: String, _ change: (inout AgentSession) -> Void) throws {
        guard var s = agentSessions[id] else { throw notFound("session", id) }
        change(&s)
        s.updatedAt = now()
        agentSessions[id] = s
        broadcast(.agentSession, AgentSessionResult(session: s))
    }

    func setAgentStatus(_ id: String, _ status: AgentSessionStatus, preview: String? = nil, bumpUnread: Bool = false) {
        try? mutateAgent(id) {
            $0.status = status
            if let preview { $0.preview = preview }
            if bumpUnread { $0.unread += 1 }
        }
    }

    func upsert(_ sessionId: String, _ item: TranscriptItem) {
        var list = transcripts[sessionId] ?? []
        if let i = list.firstIndex(where: { $0.id == item.id }) { list[i] = item } else { list.append(item) }
        transcripts[sessionId] = list
        broadcast(.agentItem, AgentItemEvent(sessionId: sessionId, item: item))
    }

    func createAgent(_ p: AgentCreateParams) throws -> AgentSession {
        guard let harness = harnessList.first(where: { $0.id == p.harness }) else { throw notFound("harness", p.harness) }
        guard harness.available else { throw RPCError(code: .unavailable, message: "\(harness.name) is not installed on this Mac") }
        let t = now()
        let cwd = p.cwd ?? "~/src/cmux"
        let title = p.prompt.map { String($0.prefix(48)) } ?? "New \(harness.name) session"
        let session = AgentSession(id: makeId("s"), title: title, harness: harness.id, model: p.model ?? harness.models.first?.id,
                                   mode: harness.modes.first?.id, cwd: cwd, status: .idle, createdAt: t, updatedAt: t)
        agentSessions[session.id] = session
        transcripts[session.id] = [.notice(NoticeTranscriptItem(id: makeId("i"), level: .info, text: "Started \(harness.name) in \(cwd)"))]
        broadcast(.agentSession, AgentSessionResult(session: session))
        if let prompt = p.prompt, !prompt.isEmpty {
            try self.prompt(AgentPromptParams(sessionId: session.id, text: prompt))
        }
        return agentSessions[session.id] ?? session
    }

    func prompt(_ p: AgentPromptParams) throws {
        guard let session = agentSessions[p.sessionId] else { throw notFound("session", p.sessionId) }
        guard turnTasks[p.sessionId] == nil, session.status != .waiting else {
            throw RPCError(code: .unavailable, message: "The agent is still working; cancel the current turn first")
        }
        let attachments = (p.attachments ?? []).map { PromptAttachment(name: $0.name, mimeType: $0.mimeType) }
        upsert(p.sessionId, .user(UserTranscriptItem(id: makeId("i"), text: p.text, attachments: attachments)))
        setAgentStatus(p.sessionId, .running, preview: p.text)
        let sessionId = p.sessionId
        let script = fixtures.turnScript(for: p.text, cwd: session.cwd)
        turnTasks[sessionId] = Task { await self.runTurn(sessionId, script) }
    }

    func runTurn(_ sessionId: String, _ script: MockTurnScript) async {
        let started = now()
        do {
            // Thinking.
            let thoughtId = makeId("i")
            try await streamText(sessionId, script.thought, every: 28) { text, streaming in
                .thought(ThoughtTranscriptItem(id: thoughtId, text: text, streaming: streaming,
                                               durationMs: streaming ? nil : Int(self.now() - started)))
            }
            try await pause(250)

            // Tools.
            for tool in script.tools {
                try await runTool(sessionId, tool)
            }

            // Answer.
            let answerId = makeId("i")
            try await streamText(sessionId, script.answer, every: 22) { text, streaming in
                .assistant(AssistantTranscriptItem(id: answerId, text: text, streaming: streaming))
            }
            upsert(sessionId, .turnEnd(TurnEndTranscriptItem(id: makeId("i"), stopReason: "end_turn", durationMs: Int(now() - started))))
            turnTasks[sessionId] = nil
            setAgentStatus(sessionId, .idle, preview: String(script.answer.prefix(120)), bumpUnread: true)
        } catch {
            // Cancelled: cancelTurn already wrote the transcript.
        }

    }

    func streamText(_ sessionId: String, _ full: String, every ms: Double, _ make: (String, Bool) -> TranscriptItem) async throws {
        var shown = ""
        for piece in MockFixtures.tokenize(full) {
            shown += piece
            upsert(sessionId, make(shown, true))
            try await pause(ms)
        }
        upsert(sessionId, make(full, false))
    }

    func runTool(_ sessionId: String, _ tool: MockToolStep) async throws {
        let toolId = makeId("t")
        var item = ToolCallTranscriptItem(id: toolId, toolKind: tool.kind, title: tool.title, status: .pending,
                                          input: tool.input, locations: tool.locations)
        upsert(sessionId, .tool(item))
        if tool.needsPermission {
            let permissionId = makeId("p")
            var permission = PermissionTranscriptItem(id: permissionId, toolCallId: toolId, title: "Allow: \(tool.title)?",
                                                      options: MockFixtures.permissionOptions)
            upsert(sessionId, .permission(permission))
            setAgentStatus(sessionId, .waiting, preview: "Waiting for permission: \(tool.title)")
            let choice = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                permissionWaiters[sessionId] = c
            }
            try Task.checkCancellation()
            guard let choice else { throw CancellationError() }
            permission.resolved = choice
            upsert(sessionId, .permission(permission))
            setAgentStatus(sessionId, .running)
            if choice.hasPrefix("reject") {
                item.status = .failed
                item.output = "Permission denied by user"
                upsert(sessionId, .tool(item))
                return
            }
        }
        try await pause(300)
        item.status = .running
        upsert(sessionId, .tool(item))
        try await pause(tool.durationMs)
        item.status = tool.fails ? .failed : .completed
        item.output = tool.output
        item.diff = tool.diff
        upsert(sessionId, .tool(item))
    }

    func cancelTurn(_ sessionId: String) throws {
        guard agentSessions[sessionId] != nil else { throw notFound("session", sessionId) }
        turnTasks.removeValue(forKey: sessionId)?.cancel()
        permissionWaiters.removeValue(forKey: sessionId)?.resume(returning: nil)
        for item in transcripts[sessionId] ?? [] {
            switch item {
            case .assistant(var x) where x.streaming: x.streaming = false; upsert(sessionId, .assistant(x))
            case .thought(var x) where x.streaming: x.streaming = false; upsert(sessionId, .thought(x))
            case .tool(var x) where x.status == .running || x.status == .pending:
                x.status = .failed; x.output = "Cancelled"; upsert(sessionId, .tool(x))
            case .permission(var x) where x.resolved == nil:
                x.resolved = "reject_once"; upsert(sessionId, .permission(x))
            default: break
            }
        }
        upsert(sessionId, .notice(NoticeTranscriptItem(id: makeId("i"), level: .warning, text: "Turn cancelled")))
        upsert(sessionId, .turnEnd(TurnEndTranscriptItem(id: makeId("i"), stopReason: "cancelled", durationMs: 0)))
        setAgentStatus(sessionId, .idle, preview: "Cancelled")
    }

    func answerPermission(_ p: AgentPermissionParams) throws {
        guard agentSessions[p.sessionId] != nil else { throw notFound("session", p.sessionId) }
        guard let item = transcripts[p.sessionId]?.first(where: { $0.id == p.itemId }),
              case .permission(var permission) = item else { throw notFound("permission", p.itemId) }
        guard permission.resolved == nil else { throw RPCError(code: .badRequest, message: "Already answered") }
        if let waiter = permissionWaiters.removeValue(forKey: p.sessionId) {
            waiter.resume(returning: p.optionId)
            return
        }
        // A fixture permission with no live turn: finish the scripted turn.
        permission.resolved = p.optionId
        upsert(p.sessionId, .permission(permission))
        let sessionId = p.sessionId
        let toolCallId = permission.toolCallId
        let allowed = !p.optionId.hasPrefix("reject")
        setAgentStatus(sessionId, .running)
        turnTasks[sessionId] = Task { await self.finishFixturePermission(sessionId, toolCallId: toolCallId, allowed: allowed) }
    }

    func finishFixturePermission(_ sessionId: String, toolCallId: String, allowed: Bool) async {
        let started = now()
        do {
            if let item = transcripts[sessionId]?.first(where: { $0.id == toolCallId }), case .tool(var tool) = item {
                tool.status = allowed ? .running : .failed
                if !allowed { tool.output = "Permission denied by user" }
                upsert(sessionId, .tool(tool))
                if allowed {
                    try await pause(1200)
                    tool.status = .completed
                    tool.output = .string("Removed 3 stale build caches (412 MB)\n✓ dist/ cleaned")
                    upsert(sessionId, .tool(tool))
                }
            }
            let answerId = makeId("i")
            let text = allowed
                ? "Cleaned the stale caches. The auth middleware refactor is complete:\n\n- `requireSession` now validates the JWT once per request\n- refresh tokens rotate on every use\n- all **42** tests pass"
                : "Understood, I left the caches alone. The refactor itself is done and the tests pass; the stale caches only cost disk space."
            var shown = ""
            for piece in MockFixtures.tokenize(text) {
                shown += piece
                upsert(sessionId, .assistant(AssistantTranscriptItem(id: answerId, text: shown, streaming: true)))
                try await pause(22)
            }
            upsert(sessionId, .assistant(AssistantTranscriptItem(id: answerId, text: text, streaming: false)))
            upsert(sessionId, .turnEnd(TurnEndTranscriptItem(id: makeId("i"), stopReason: "end_turn", durationMs: Int(now() - started))))
            turnTasks[sessionId] = nil
            setAgentStatus(sessionId, .idle, preview: String(text.prefix(120)), bumpUnread: true)
        } catch {}
    }
}
