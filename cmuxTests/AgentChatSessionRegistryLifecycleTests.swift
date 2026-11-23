import CMUXAgentLaunch
import CmuxAgentChat
import CmuxFoundation
@testable import CmuxMobileHost
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentChatSessionRegistryLifecycleTests {
    @MainActor
    @Test("Idle notifications after Stop preserve idle state for Grok and Claude")
    func idleNotificationAfterStopAndSessionEndDoesNotReviveCompletedAgent() throws {
        let cases = [
            (source: "grok", extraFields: #"{"reason":"idle_prompt"}"#),
            (source: "claude", extraFields: #"{"notification_type":"idle_prompt"}"#),
        ]

        for (source, extraFields) in cases {
            let registry = AgentChatSessionRegistry()
            let sessionID = "\(source)-completed-session"
            let surfaceID = UUID().uuidString
            let times = (start: Date(timeIntervalSince1970: 100), prompt: Date(timeIntervalSince1970: 101), stop: Date(timeIntervalSince1970: 102), idle: Date(timeIntervalSince1970: 103), end: Date(timeIntervalSince1970: 104), lateIdle: Date(timeIntervalSince1970: 105))

            registry.noteHookEvent(WorkstreamEvent(
                sessionId: sessionID,
                hookEventName: .sessionStart,
                source: source,
                surfaceId: surfaceID,
                receivedAt: times.start
            ))
            registry.noteHookEvent(WorkstreamEvent(
                sessionId: sessionID,
                hookEventName: .userPromptSubmit,
                source: source,
                surfaceId: surfaceID,
                receivedAt: times.prompt
            ))
            let stopped = registry.noteHookEvent(WorkstreamEvent(
                sessionId: sessionID,
                hookEventName: .stop,
                source: source,
                surfaceId: surfaceID,
                receivedAt: times.stop
            ))
            #expect(stopped.state == .idle)

            let delayedIdle = registry.noteHookEvent(WorkstreamEvent(
                sessionId: sessionID,
                hookEventName: .notification,
                source: source,
                surfaceId: surfaceID,
                receivedAt: times.idle,
                extraFieldsJSON: extraFields,
                isIdleReminder: true
            ))
            #expect(delayedIdle.state == .idle)

            let ended = registry.noteHookEvent(WorkstreamEvent(
                sessionId: sessionID,
                hookEventName: .sessionEnd,
                source: source,
                surfaceId: surfaceID,
                receivedAt: times.end
            ))
            #expect(ended.state == .ended)

            let lateIdle = registry.noteHookEvent(WorkstreamEvent(
                sessionId: sessionID,
                hookEventName: .notification,
                source: source,
                surfaceId: surfaceID,
                receivedAt: times.lateIdle,
                extraFieldsJSON: extraFields,
                isIdleReminder: true
            ))
            #expect(lateIdle.state == .ended)

            let resumedSessionID = "\(source)-resumed-session"
            let resumed = AgentChatSessionRegistry()
            resumed.noteHookEvent(WorkstreamEvent(
                sessionId: resumedSessionID,
                hookEventName: .sessionStart,
                source: source,
                surfaceId: surfaceID,
                receivedAt: times.start
            ))
            resumed.noteHookEvent(WorkstreamEvent(
                sessionId: resumedSessionID,
                hookEventName: .stop,
                source: source,
                surfaceId: surfaceID,
                receivedAt: times.stop
            ))
            let resumedPrompt = resumed.noteHookEvent(WorkstreamEvent(
                sessionId: resumedSessionID,
                hookEventName: .userPromptSubmit,
                source: source,
                surfaceId: surfaceID,
                receivedAt: times.idle
            ))
            #expect(resumedPrompt.state == .working(since: times.idle))
            let lateAfterResume = resumed.noteHookEvent(WorkstreamEvent(
                sessionId: resumedSessionID,
                hookEventName: .notification,
                source: source,
                surfaceId: surfaceID,
                receivedAt: times.lateIdle,
                extraFieldsJSON: extraFields,
                isIdleReminder: true
            ))
            #expect(lateAfterResume.state == .working(since: times.idle))
        }
    }

    @MainActor
    @Test("Claude blocking PreToolUse stays needs input before its journal event")
    func claudeBlockingToolDoesNotFlashWorking() throws {
        let registry = AgentChatSessionRegistry()
        let sessionID = "claude-question-session"
        let surfaceID = UUID().uuidString

        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionStart,
            source: "claude",
            surfaceId: surfaceID,
            receivedAt: Date(timeIntervalSince1970: 100)
        ))

        let question = registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .preToolUse,
            source: "claude",
            surfaceId: surfaceID,
            toolName: "AskUserQuestion",
            receivedAt: Date(timeIntervalSince1970: 101)
        ))

        #expect(question.state == .needsInput(since: Date(timeIntervalSince1970: 101)))
    }

    @MainActor
    @Test("Terminal input optimistically clears needs input")
    func terminalInputMovesWaitingSessionToWorking() throws {
        let registry = AgentChatSessionRegistry()
        let sessionID = "waiting-session"
        let surfaceID = UUID().uuidString
        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionStart,
            source: "claude",
            surfaceId: surfaceID,
            receivedAt: Date(timeIntervalSince1970: 100)
        ))
        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .permissionRequest,
            source: "claude",
            surfaceId: surfaceID,
            receivedAt: Date(timeIntervalSince1970: 101)
        ))

        #expect(registry.noteUserInput(surfaceID: surfaceID, at: Date(timeIntervalSince1970: 102)) == 1)
        #expect(registry.record(sessionID: sessionID)?.state == .working(since: Date(timeIntervalSince1970: 102)))

        let corrected = registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .permissionRequest,
            source: "claude",
            surfaceId: surfaceID,
            receivedAt: Date(timeIntervalSince1970: 103)
        ))
        #expect(corrected.state == .needsInput(since: Date(timeIntervalSince1970: 103)))
    }

    @MainActor
    @Test("Feed v1 ids are decoded before chat records are indexed")
    func canonicalFeedIDIsDecodedBeforeChatBinding() throws {
        let sessionID = "thread-with-hyphens"
        let canonicalID = try #require(
            FeedWorkstreamIdentifier(agentID: "codex", sessionID: sessionID)?.rawValue
        )
        let registry = AgentChatSessionRegistry()

        let record = registry.noteHookEvent(WorkstreamEvent(
            sessionId: canonicalID,
            hookEventName: .sessionStart,
            source: "codex"
        ))

        #expect(record.sessionID == sessionID)
        #expect(record.hookStoreLookupSessionID == sessionID)
        #expect(record.hookStoreSessionID == nil)
    }

    /// Notes `names` in order on `registry` for one session, one second apart
    /// from `start`, and returns the state after the last one.
    @MainActor
    private func stateAfter(
        _ names: [WorkstreamEvent.HookEventName],
        tool: String? = "mcp__plugin__refresh",
        source: String = "claude",
        session: String,
        surface: String? = nil,
        on registry: AgentChatSessionRegistry,
        from start: TimeInterval
    ) -> ChatAgentState {
        var state = ChatAgentState.idle
        for (offset, name) in names.enumerated() {
            let isToolEvent = [.preToolUse, .postToolUse, .postToolUseFailure].contains(name)
            state = registry.noteHookEvent(WorkstreamEvent(
                sessionId: session,
                hookEventName: name,
                source: source,
                surfaceId: surface,
                toolName: isToolEvent ? tool : nil,
                receivedAt: Date(timeIntervalSince1970: start + TimeInterval(offset))
            )).state
        }
        return state
    }

    @MainActor
    @Test("Claude tool hooks after Stop leave the session idle until the next prompt")
    func claudeToolHooksAfterStopKeepTheSessionIdle() {
        let registry = AgentChatSessionRegistry()
        let session = "plugin-between-turns"
        #expect(stateAfter([.sessionStart, .userPromptSubmit, .preToolUse, .postToolUse, .stop], session: session, on: registry, from: 100) == .idle)

        // A plugin calls an MCP tool on a timer. No turn is running, so no
        // Stop follows these.
        for (offset, name) in [WorkstreamEvent.HookEventName.preToolUse, .postToolUse, .preToolUse, .postToolUseFailure, .todoWrite, .subagentStop].enumerated() {
            #expect(
                stateAfter([name], session: session, on: registry, from: 200 + TimeInterval(offset)) == .idle,
                "\(name.rawValue) after Stop"
            )
        }

        // The next prompt starts a turn, and its tool calls count again.
        #expect(stateAfter([.userPromptSubmit], session: session, on: registry, from: 300) == .working(since: Date(timeIntervalSince1970: 300)))
        // SessionStart (a resume, or a compaction) is not a prompt, so the
        // turn stays settled across it, as it does in the hook store.
        #expect(stateAfter([.stop, .sessionStart, .preToolUse], session: session, on: registry, from: 400) == .idle)
    }

    @MainActor
    @Test("A Claude tool hook with no Stop before it still marks the session working")
    func claudeToolHookWithoutAPriorStopMarksTheSessionWorking() {
        // First seen mid-turn, for example after the app relaunched.
        let registry = AgentChatSessionRegistry()
        #expect(
            stateAfter([.preToolUse], session: "seen-mid-turn", on: registry, from: 100)
                == .working(since: Date(timeIntervalSince1970: 100))
        )
    }

    @MainActor
    @Test("A permission prompt raised after Stop clears when its tool finishes")
    func permissionPromptAfterStopClearsWhenTheToolFinishes() {
        let registry = AgentChatSessionRegistry()
        let session = "plugin-permission"
        #expect(stateAfter([.userPromptSubmit, .stop, .preToolUse], session: session, on: registry, from: 100) == .idle)
        #expect(stateAfter([.permissionRequest], session: session, on: registry, from: 200) == .needsInput(since: Date(timeIntervalSince1970: 200)))
        // Another call starting must not hide the prompt that is still open.
        #expect(stateAfter([.preToolUse], session: session, on: registry, from: 201) == .needsInput(since: Date(timeIntervalSince1970: 200)))
        #expect(stateAfter([.postToolUse], session: session, on: registry, from: 202) == .idle)
        #expect(stateAfter([.preToolUse, .permissionRequest, .postToolUseFailure], session: session, on: registry, from: 300) == .idle)
    }

    @MainActor
    @Test("A permission prompt answered in the terminal after Stop ends idle")
    func permissionPromptAnsweredInTheTerminalAfterStopEndsIdle() {
        let registry = AgentChatSessionRegistry()
        let session = "plugin-permission-typed"
        let surface = UUID().uuidString
        #expect(
            stateAfter([.userPromptSubmit, .stop, .preToolUse, .permissionRequest], session: session, surface: surface, on: registry, from: 100)
                == .needsInput(since: Date(timeIntervalSince1970: 103))
        )
        // Typing the answer marks the session working ahead of the next hook.
        #expect(registry.noteUserInput(surfaceID: surface, at: Date(timeIntervalSince1970: 200)) == 1)
        #expect(registry.record(sessionID: session)?.state == .working(since: Date(timeIntervalSince1970: 200)))
        #expect(stateAfter([.postToolUse], session: session, surface: surface, on: registry, from: 201) == .idle)
    }

    @MainActor
    @Test("A session seeded from the hook store keeps its settled turn", arguments: [true, false])
    func hookStoreSeedCarriesTheSettledTurn(turnSettled: Bool) async throws {
        // After an app relaunch the registry starts from the hook store, which
        // records whether the last turn ended with Stop.
        let home = try temporaryHomeDirectory()
        let sessionID = "5f0c1a52-7d0e-4b0b-9a53-0d1c6a4f1e27"
        let surfaceID = UUID().uuidString
        try writeClaudeHookStore(
            home: home,
            sessionID: sessionID,
            workspaceID: UUID().uuidString,
            surfaceID: surfaceID,
            transcriptPath: "/Users/example/.claude/projects/-Users-example-project/\(sessionID).jsonl",
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            turnSettled: turnSettled
        )
        let registry = AgentChatSessionRegistry(hookStore: AgentChatHookSessionStore(homeDirectory: home))
        await registry.seedFromHookStores(agentSources: ["claude"])
        #expect(registry.record(sessionID: sessionID)?.state == .idle)

        let state = stateAfter([.preToolUse], session: sessionID, surface: surfaceID, on: registry, from: 200)
        #expect(state == (turnSettled ? .idle : .working(since: Date(timeIntervalSince1970: 200))))
    }

    @MainActor
    @Test("The hook store's settled turn reaches a record that exists before the seed")
    func hookStoreSeedCarriesTheSettledTurnOntoAResumedRecord() async throws {
        // On relaunch the resume path creates the record before the seed runs.
        let home = try temporaryHomeDirectory()
        let sessionID = "8a4de1f3-2b7c-4c55-b1a9-6f0e2d9c7b14"
        let surfaceID = UUID().uuidString
        let workspaceID = UUID().uuidString
        try writeClaudeHookStore(
            home: home,
            sessionID: sessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            transcriptPath: "/Users/example/.claude/projects/-Users-example-project/\(sessionID).jsonl",
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            turnSettled: true
        )
        let registry = AgentChatSessionRegistry(hookStore: AgentChatHookSessionStore(homeDirectory: home))
        registry.noteResumeInitiated(
            sessionID: sessionID,
            source: "claude",
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            workingDirectory: "/Users/example/project"
        )
        await registry.seedFromHookStores(agentSources: ["claude"])

        #expect(stateAfter([.preToolUse], session: sessionID, surface: surfaceID, on: registry, from: 200) == .idle)
    }

    @MainActor
    @Test("The hook store's settled turn reaches a resumed session whose SessionStart came first")
    func hookStoreSeedCarriesTheSettledTurnPastAnEarlierSessionStart() async throws {
        // The resumed process can report SessionStart while the seed is still
        // reading the store. SessionStart is no turn boundary, so the stored
        // one still applies.
        let home = try temporaryHomeDirectory()
        let sessionID = "c2b7f6d0-93a1-4e8e-8f3b-51d0a7e4c9aa"
        let surfaceID = UUID().uuidString
        let workspaceID = UUID().uuidString
        try writeClaudeHookStore(
            home: home,
            sessionID: sessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            transcriptPath: "/Users/example/.claude/projects/-Users-example-project/\(sessionID).jsonl",
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            turnSettled: true
        )
        let registry = AgentChatSessionRegistry(hookStore: AgentChatHookSessionStore(homeDirectory: home))
        registry.noteResumeInitiated(
            sessionID: sessionID,
            source: "claude",
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            workingDirectory: "/Users/example/project"
        )
        #expect(stateAfter([.sessionStart], session: sessionID, surface: surfaceID, on: registry, from: 150) == .idle)
        await registry.seedFromHookStores(agentSources: ["claude"])

        #expect(stateAfter([.preToolUse], session: sessionID, surface: surfaceID, on: registry, from: 200) == .idle)
    }

    @MainActor
    @Test("A prompt seen before the seed outranks the hook store's settled turn")
    func livePromptOutranksTheHookStoresSettledTurn() async throws {
        let home = try temporaryHomeDirectory()
        let sessionID = "0d5e8a77-41c2-4f6b-a2de-7b93c1f0e6d3"
        let surfaceID = UUID().uuidString
        try writeClaudeHookStore(
            home: home,
            sessionID: sessionID,
            workspaceID: UUID().uuidString,
            surfaceID: surfaceID,
            transcriptPath: "/Users/example/.claude/projects/-Users-example-project/\(sessionID).jsonl",
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            turnSettled: true
        )
        let registry = AgentChatSessionRegistry(hookStore: AgentChatHookSessionStore(homeDirectory: home))
        #expect(stateAfter([.userPromptSubmit], session: sessionID, surface: surfaceID, on: registry, from: 150) == .working(since: Date(timeIntervalSince1970: 150)))
        await registry.seedFromHookStores(agentSources: ["claude"])

        // The turn the prompt opened is still running: a tool result must not settle it.
        #expect(stateAfter([.preToolUse, .postToolUse], session: sessionID, surface: surfaceID, on: registry, from: 200) == .working(since: Date(timeIntervalSince1970: 150)))
    }

    @MainActor
    @Test("AskUserQuestion after Stop still needs input")
    func askUserQuestionAfterStopStillNeedsInput() {
        let registry = AgentChatSessionRegistry()
        #expect(
            stateAfter([.userPromptSubmit, .stop, .preToolUse], tool: "AskUserQuestion", session: "ask-after-stop", on: registry, from: 100)
                == .needsInput(since: Date(timeIntervalSince1970: 102))
        )
    }

    @MainActor
    @Test("Tool hooks after Stop still mark other agents working")
    func toolHooksAfterStopStillMarkOtherAgentsWorking() {
        let registry = AgentChatSessionRegistry()
        #expect(
            stateAfter([.userPromptSubmit, .stop, .preToolUse], source: "codex", session: "tool-after-stop", on: registry, from: 100)
                == .working(since: Date(timeIntervalSince1970: 102))
        )
    }

    @MainActor
    @Test func hookStoreSeedDoesNotRestoreStalePIDOntoExistingLiveRecord() async throws {
        let home = try temporaryHomeDirectory()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let (staleWorkspaceID, staleSurfaceID) = (UUID().uuidString, UUID().uuidString)
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptPath = "/Users/example/.claude/projects/-Users-example-project/\(sessionID).jsonl"
        try writeClaudeHookStore(
            home: home,
            sessionID: sessionID,
            workspaceID: staleWorkspaceID,
            surfaceID: staleSurfaceID,
            transcriptPath: transcriptPath,
            pid: 444
        )
        let registry = AgentChatSessionRegistry(
            hookStore: AgentChatHookSessionStore(homeDirectory: home)
        )

        registry.noteResumeInitiated(
            sessionID: sessionID,
            source: "claude",
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            workingDirectory: "/Users/example/project"
        )
        await registry.seedFromHookStores(agentSources: ["claude"])

        let record = try #require(registry.record(sessionID: sessionID))
        #expect(record.workspaceID == workspaceID)
        #expect(record.surfaceID == surfaceID)
        #expect(record.transcriptPath == transcriptPath)
        #expect(record.pid == nil)
        #expect(record.state == .idle)
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == sessionID)
    }

    @MainActor
    @Test func endedPendingClaudeObservationRevivesForNewIdleProcess() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 111,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])
        registry.update(sessionID: pendingID) { record in
            record.state = .ended
        }

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 222,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])

        let record = try #require(registry.record(sessionID: pendingID))
        #expect(record.state == .idle)
        #expect(record.pid == 222)
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == pendingID)
    }

    @MainActor
    @Test func transcriptBackedEndedPendingClaudeIsPreservedWhenNewIdleProcessAppears() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let nextPendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID, pid: 222)
        let transcriptPath = "/Users/example/.claude/projects/-Users-example-project/session.jsonl"

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 111,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])
        registry.update(sessionID: pendingID) { record in
            record.transcriptPath = transcriptPath
            record.state = .ended
        }

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 222,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])

        let ended = try #require(registry.record(sessionID: pendingID))
        let live = try #require(registry.record(sessionID: nextPendingID))
        #expect(ended.state == .ended)
        #expect(ended.transcriptPath == transcriptPath)
        #expect(live.state == .idle)
        #expect(live.pid == 222)
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == nextPendingID)
    }

    @MainActor
    @Test func stalePendingClaudeObservationDoesNotCreateNewLiveAlias() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let nextPendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID, pid: 222)
        let transcriptPath = "/Users/example/.claude/projects/-Users-example-project/session.jsonl"

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 111,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil,
                sampledAt: Date(timeIntervalSince1970: 100)
            ),
        ])
        registry.update(sessionID: pendingID) { record in
            record.transcriptPath = transcriptPath
            record.state = .ended
        }
        let endedAt = try #require(registry.record(sessionID: pendingID)?.endedAt)

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 222,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil,
                sampledAt: endedAt.addingTimeInterval(-1)
            ),
        ])

        let ended = try #require(registry.record(sessionID: pendingID))
        #expect(ended.state == .ended)
        #expect(ended.pid == 111)
        #expect(registry.record(sessionID: nextPendingID) == nil)
        #expect(registry.liveSession(surfaceID: surfaceID) == nil)
    }

    @MainActor
    @Test func hookBackedEndedPendingClaudeIsPreservedWhenNewIdleProcessAppears() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let nextPendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID, pid: 222)
        let realSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 111,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])
        registry.update(sessionID: pendingID) { record in
            record.rememberHookStoreSessionID(realSessionID)
            record.state = .ended
        }

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 222,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])

        let ended = try #require(registry.record(sessionID: pendingID))
        let live = try #require(registry.record(sessionID: nextPendingID))
        #expect(ended.state == .ended)
        #expect(ended.hookStoreSessionID == realSessionID)
        #expect(live.state == .idle)
        #expect(live.pid == 222)
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == nextPendingID)
    }

    @MainActor
    @Test func endedCodexObservationRevivesRealSessionID() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: sessionID,
                agentKind: .codex,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 111,
                workingDirectory: "/Users/example/project",
                transcriptPath: "/Users/example/.codex/sessions/rollout-\(sessionID).jsonl"
            ),
        ])
        registry.update(sessionID: sessionID) { record in
            record.state = .ended
        }

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: sessionID,
                agentKind: .codex,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 222,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])

        let record = try #require(registry.record(sessionID: sessionID))
        #expect(record.state == .idle)
        #expect(record.pid == 222)
        #expect(record.transcriptPath == "/Users/example/.codex/sessions/rollout-\(sessionID).jsonl")
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == sessionID)
    }

    @MainActor
    @Test func staleProcessObservationDoesNotReviveEndedSession() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: sessionID,
                agentKind: .codex,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 111,
                workingDirectory: "/Users/example/project",
                transcriptPath: "/Users/example/.codex/sessions/rollout-\(sessionID).jsonl",
                sampledAt: Date(timeIntervalSince1970: 100)
            ),
        ])
        registry.update(sessionID: sessionID) { record in
            record.state = .ended
        }
        let endedAt = try #require(registry.record(sessionID: sessionID)?.endedAt)

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: sessionID,
                agentKind: .codex,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 222,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil,
                sampledAt: endedAt.addingTimeInterval(-1)
            ),
        ])

        let record = try #require(registry.record(sessionID: sessionID))
        #expect(record.state == .ended)
        #expect(record.pid == 111)
        #expect(registry.liveSession(surfaceID: surfaceID) == nil)
    }

    @MainActor
    @Test func pendingClaudeAliasRefreshesFromRealHookStoreSessionID() async throws {
        let home = try temporaryHomeDirectory()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let realSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptPath = "/Users/example/.claude/projects/-Users-example-project/\(realSessionID).jsonl"
        try writeClaudeHookStore(
            home: home,
            sessionID: realSessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            transcriptPath: transcriptPath,
            pid: 222
        )
        let registry = AgentChatSessionRegistry(hookStore: AgentChatHookSessionStore(homeDirectory: home))

        registry.noteResumeInitiated(
            sessionID: pendingID,
            source: "claude",
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            workingDirectory: "/Users/example/project"
        )
        registry.noteHookEvent(WorkstreamEvent(
            sessionId: realSessionID,
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            transcriptPath: nil,
            cwd: "/Users/example/project",
            ppid: 333,
            receivedAt: Date(timeIntervalSince1970: 150)
        ))

        let refreshed = try #require(await registry.refreshBindingsFromHookStore(sessionID: pendingID))
        #expect(refreshed.transcriptPath == transcriptPath)
        #expect(refreshed.pid == 333)
    }

    @MainActor
    @Test func endedSessionWithMissingTranscriptIsNotListableForMobileChat() throws {
        let home = try temporaryHomeDirectory()
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:])
        )
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptURL = home
            .appendingPathComponent(".claude/projects/-Users-example-project", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        let record = AgentChatSessionRecord(
            sessionID: sessionID,
            agentKind: .claude,
            workspaceID: UUID().uuidString,
            surfaceID: UUID().uuidString,
            workingDirectory: "/Users/example/project",
            transcriptPath: transcriptURL.path,
            state: .ended,
            lastActivityAt: Date(),
            title: nil,
            pid: nil
        )

        #expect(!service.hasBoundedReadableTranscript(record))

        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}\n".write(to: transcriptURL, atomically: true, encoding: .utf8)

        #expect(service.hasBoundedReadableTranscript(record))
        _ = service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID, hookEventName: .sessionEnd, source: "claude",
            workspaceId: record.workspaceID, surfaceId: record.surfaceID,
            transcriptPath: transcriptURL.path, cwd: "/Users/example/project", ppid: nil,
            receivedAt: Date(timeIntervalSince1970: 250)
        ))
        let cachedRecord = try #require(service.sessionRecord(sessionID: sessionID))
        #expect(cachedRecord.state == .ended)
        #expect(service.shouldListEndedSession(cachedRecord))
    }

    @MainActor
    @Test func endedCodexSessionListabilityKeepsFallbackRowsWithoutScanningHistory() throws {
        let home = try temporaryHomeDirectory()
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:])
        )
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptURL = home
            .appendingPathComponent(".codex/sessions/2026/06/30", isDirectory: true)
            .appendingPathComponent("rollout-2026-06-30T00-00-00-\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}\n".write(to: transcriptURL, atomically: true, encoding: .utf8)
        let record = AgentChatSessionRecord(
            sessionID: sessionID,
            agentKind: .codex,
            workspaceID: UUID().uuidString,
            surfaceID: UUID().uuidString,
            workingDirectory: "/Users/example/project",
            transcriptPath: nil,
            state: .ended,
            lastActivityAt: Date(),
            title: nil,
            pid: nil
        )

        #expect(!service.hasBoundedReadableTranscript(record))
        #expect(service.shouldListEndedSession(record))
    }

    @MainActor
    @Test func pendingClaudeAliasUsesRealHookSessionIDForFallbackTranscript() throws {
        let home = try temporaryHomeDirectory()
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:])
        )
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let realSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptURL = home
            .appendingPathComponent(".claude/projects/-Users-example-project", isDirectory: true)
            .appendingPathComponent("\(realSessionID).jsonl")
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}\n".write(to: transcriptURL, atomically: true, encoding: .utf8)
        var record = AgentChatSessionRecord(
            sessionID: pendingID,
            agentKind: .claude,
            workspaceID: UUID().uuidString,
            surfaceID: surfaceID,
            workingDirectory: "/Users/example/project",
            transcriptPath: nil,
            state: .ended,
            lastActivityAt: Date(),
            title: nil,
            pid: nil
        )
        record.rememberHookStoreSessionID(realSessionID)

        #expect(service.hasBoundedReadableTranscript(record))
    }

    @MainActor
    @Test func restoreStyleInitializationRebuildsSurfaceLookup() throws {
        let surfaceID = UUID().uuidString
        let older = AgentChatSessionRecord(
            sessionID: "older",
            agentKind: .codex,
            workspaceID: UUID().uuidString,
            surfaceID: surfaceID,
            workingDirectory: "/Users/example/project",
            transcriptPath: "/tmp/older.jsonl",
            state: .ended,
            lastActivityAt: Date(timeIntervalSince1970: 100),
            title: nil,
            pid: nil
        )
        let newer = AgentChatSessionRecord(
            sessionID: "newer",
            agentKind: .claude,
            workspaceID: UUID().uuidString,
            surfaceID: surfaceID,
            workingDirectory: "/Users/example/project",
            transcriptPath: "/tmp/newer.jsonl",
            state: .ended,
            lastActivityAt: Date(timeIntervalSince1970: 200),
            title: nil,
            pid: nil
        )
        let registry = AgentChatSessionRegistry(restoredRecords: [older, newer])

        let resolved = try #require(registry.currentOrMostRecentSession(surfaceID: surfaceID))
        #expect(resolved.sessionID == newer.sessionID)
    }

    private func temporaryHomeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-chat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeClaudeHookStore(
        home: URL,
        sessionID: String,
        workspaceID: String,
        surfaceID: String,
        transcriptPath: String,
        pid: Int,
        turnSettled: Bool? = nil
    ) throws {
        let directory = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var session: [String: Any] = [
            "workspaceId": workspaceID,
            "surfaceId": surfaceID,
            "cwd": "/Users/example/project",
            "transcriptPath": transcriptPath,
            "pid": pid,
            "updatedAt": 140.0,
        ]
        if let turnSettled {
            session["turnSettled"] = turnSettled
        }
        let payload: [String: Any] = ["sessions": [sessionID: session]]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("claude-hook-sessions.json"))
    }
}
