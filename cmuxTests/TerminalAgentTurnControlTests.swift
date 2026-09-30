import AppKit
import CmuxAgentJournal
import CmuxSettings
import CmuxTerminal
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent turn interrupt target")
struct AgentTurnInterruptTargetTests {
    @Test func resolvesOnlyRunningSupportedAgents() {
        #expect(AgentTurnInterruptTarget.resolve(statusKeyedStates: ["claude_code": .running]) == .claudeCode)
        #expect(AgentTurnInterruptTarget.resolve(statusKeyedStates: ["codex": .running]) == .codex)
        #expect(AgentTurnInterruptTarget.resolve(statusKeyedStates: ["claude_code": .idle]) == nil)
        #expect(AgentTurnInterruptTarget.resolve(statusKeyedStates: ["claude_code": .needsInput]) == nil)
        // Agents whose interrupt key is unverified get no button.
        #expect(AgentTurnInterruptTarget.resolve(statusKeyedStates: ["opencode": .running]) == nil)
        #expect(AgentTurnInterruptTarget.resolve(statusKeyedStates: [:]) == nil)
    }

    @Test func multipleRunningAgentsRequireForegroundOwnership() {
        let states: [String: AgentHibernationLifecycleState] = [
            "claude_code": .running,
            "codex": .running,
        ]
        #expect(AgentTurnInterruptTarget.resolve(statusKeyedStates: states) == nil)
        #expect(AgentTurnInterruptTarget.resolve(
            statusKeyedStates: states,
            foregroundStatusKey: "codex"
        ) == .codex)
        #expect(AgentTurnInterruptTarget.resolve(
            statusKeyedStates: states,
            foregroundStatusKey: "opencode"
        ) == nil)
        #expect(AgentTurnInterruptTarget.resolve(
            statusKeyedStates: ["claude_code": .running, "opencode": .running],
            foregroundStatusKey: "claude_code"
        ) == .claudeCode)
    }

    /// The journal settles the session it has running on the surface, found
    /// from its own fold rather than the hook store.
    @Test func journalInterruptSettlesTheRunningSessionOnTheSurface() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-turn-control-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("journal.sqlite3", isDirectory: false)
        let center = AgentJournalLifecycleCenter(databaseURL: url)
        let surface = UUID()
        let workspace = UUID()
        let started = AgentJournalEventDraft(
            eventId: "turn-started",
            kind: .turnStarted,
            occurredAtMs: 1,
            source: "claude",
            agentKey: "claude_code",
            sessionId: "session-1",
            workspaceId: workspace.uuidString,
            surfaceId: surface.uuidString
        )
        let json = try #require(String(data: JSONEncoder().encode(started), encoding: .utf8))
        #expect(center.handleAppendCommand(json) == "OK 1")

        let receipt = center.recordUserInterrupt(
            surfaceId: surface,
            workspaceId: workspace,
            agentKey: "claude_code",
            source: "claude",
            boundary: .init(sessionSequences: ["session-1": 1], observedHeadSequence: 1)
        )
        await receipt.wait()

        let store = try AgentJournalStore(databaseURL: url)
        let interrupt = try store.events(afterSequence: 1, limit: 10)
            .map(\.draft)
            .first { $0.nativeEvent == AgentJournalEventDraft.userInterruptNativeEvent }
        store.close()
        let settled = try #require(interrupt, "The interrupt is journaled for the running session")
        #expect(settled.sessionId == "session-1")
        #expect(settled.kind == .turnCompleted)
        #expect(settled.surfaceId == surface.uuidString)
    }

    @Test func queuedPreToolUseIsReconciledBeforeInterruptCompletion() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-turn-control-ordering-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("journal.sqlite3", isDirectory: false)
        let gate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let center = AgentJournalLifecycleCenter(databaseURL: url, consumerStart: {
            for await _ in gate.stream { return }
        })
        let surface = UUID()
        let workspace = UUID()
        func draft(id: String, occurredAtMs: Int64, nativeEvent: String) -> AgentJournalEventDraft {
            AgentJournalEventDraft(
                eventId: id,
                kind: .turnStarted,
                occurredAtMs: occurredAtMs,
                source: "claude",
                agentKey: "claude_code",
                sessionId: "session-1",
                workspaceId: workspace.uuidString,
                surfaceId: surface.uuidString,
                nativeEvent: nativeEvent
            )
        }
        func append(_ draft: AgentJournalEventDraft) throws {
            let json = try #require(String(data: JSONEncoder().encode(draft), encoding: .utf8))
            #expect(center.handleAppendCommand(json).hasPrefix("OK "))
        }

        try append(draft(id: "turn-started", occurredAtMs: 1_000, nativeEvent: "UserPromptSubmit"))
        let receipt = center.recordUserInterrupt(
            surfaceId: surface,
            workspaceId: workspace,
            agentKey: "claude_code",
            source: "claude",
            boundary: .init(sessionSequences: ["session-1": 1], observedHeadSequence: 1)
        )
        try append(draft(id: "pre-tool-use", occurredAtMs: 1_001, nativeEvent: "PreToolUse"))
        gate.continuation.yield(())
        gate.continuation.finish()
        await receipt.wait()

        let store = try AgentJournalStore(databaseURL: url)
        let events = try store.events(afterSequence: 0, limit: 10)
        store.close()
        #expect(events.map(\.draft.nativeEvent) == ["UserPromptSubmit", "PreToolUse"])

        let reducer = AgentLifecycleReducer()
        var state = AgentLifecycleReducerState()
        for event in events {
            reducer.apply(event, to: &state)
        }
        #expect(
            state.combinedPhase(surfaceId: surface.uuidString, agentKey: "claude_code") == .running,
            "PreToolUse advanced the captured session, so the interrupt must not overwrite it idle"
        )
    }

    @Test func committedPreToolUseGapBeforeLaterIngressPreventsInterruptCompletion() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-turn-control-commit-gap-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("journal.sqlite3", isDirectory: false)
        let gate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let center = AgentJournalLifecycleCenter(databaseURL: url, consumerStart: {
            for await _ in gate.stream { return }
        })
        let surface = UUID()
        let otherSurface = UUID()
        let workspace = UUID()
        func draft(
            id: String,
            occurredAtMs: Int64,
            nativeEvent: String,
            surfaceId: UUID = surface,
            sessionId: String = "session-1"
        ) -> AgentJournalEventDraft {
            AgentJournalEventDraft(
                eventId: id,
                kind: .turnStarted,
                occurredAtMs: occurredAtMs,
                source: "claude",
                agentKey: "claude_code",
                sessionId: sessionId,
                workspaceId: workspace.uuidString,
                surfaceId: surfaceId.uuidString,
                nativeEvent: nativeEvent
            )
        }
        let started = draft(id: "turn-started", occurredAtMs: 1_000, nativeEvent: "UserPromptSubmit")
        let startedJSON = try #require(String(data: JSONEncoder().encode(started), encoding: .utf8))
        #expect(center.handleAppendCommand(startedJSON) == "OK 1")
        let receipt = center.recordUserInterrupt(
            surfaceId: surface,
            workspaceId: workspace,
            agentKey: "claude_code",
            source: "claude",
            boundary: .init(sessionSequences: ["session-1": 1], observedHeadSequence: 1)
        )

        // This is the socket-worker commit/enqueue gap: sequence 2 is durable,
        // but its `.ingest` operation has not reached the consumer yet. The
        // unrelated sequence 3 does reach the consumer before settlement, so
        // a maximum-only cursor would skip sequence 2 permanently.
        let hookStore = try AgentJournalStore(databaseURL: url)
        _ = try hookStore.append(
            draft(id: "pre-tool-use", occurredAtMs: 1_001, nativeEvent: "PreToolUse")
        )
        hookStore.close()
        let unrelated = draft(
            id: "unrelated-turn",
            occurredAtMs: 1_002,
            nativeEvent: "UserPromptSubmit",
            surfaceId: otherSurface,
            sessionId: "session-2"
        )
        let unrelatedJSON = try #require(String(data: JSONEncoder().encode(unrelated), encoding: .utf8))
        #expect(center.handleAppendCommand(unrelatedJSON) == "OK 3")
        gate.continuation.yield(())
        gate.continuation.finish()
        await receipt.wait()

        let store = try AgentJournalStore(databaseURL: url)
        let events = try store.events(afterSequence: 0, limit: 10)
        store.close()
        #expect(events.map(\.draft.eventId) == ["turn-started", "pre-tool-use", "unrelated-turn"])

        let reducer = AgentLifecycleReducer()
        var state = AgentLifecycleReducerState()
        for event in events {
            reducer.apply(event, to: &state)
        }
        #expect(
            state.combinedPhase(surfaceId: surface.uuidString, agentKey: "claude_code") == .running,
            "a committed hook must win even when later ingress advances the observed head"
        )
    }

    @Test func clickBoundaryExcludesHookQueuedBeforeInterruptRequest() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-turn-control-click-boundary-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("journal.sqlite3", isDirectory: false)
        let center = AgentJournalLifecycleCenter(databaseURL: url)
        let surface = UUID()
        let workspace = UUID()
        func draft(id: String, occurredAtMs: Int64, nativeEvent: String) -> AgentJournalEventDraft {
            AgentJournalEventDraft(
                eventId: id,
                kind: .turnStarted,
                occurredAtMs: occurredAtMs,
                source: "claude",
                agentKey: "claude_code",
                sessionId: "session-1",
                workspaceId: workspace.uuidString,
                surfaceId: surface.uuidString,
                nativeEvent: nativeEvent
            )
        }

        // Admission completion proves sequence 1 reached the consumer, so the
        // memory-only capture below is the exact generation visible at click.
        _ = await center.admitNotification(
            draft(id: "turn-started", occurredAtMs: 1_000, nativeEvent: "UserPromptSubmit")
        )
        let clickBoundary = center.captureUserInterruptSessionBoundary(
            surfaceId: surface,
            agentKey: "claude_code"
        )
        #expect(clickBoundary.sessionSequences == ["session-1": 1])
        #expect(clickBoundary.observedHeadSequence == 1)

        // Escape may cause this hook to commit and enqueue before the request
        // itself. It must not become part of the already captured click.
        let resumed = draft(id: "pre-tool-use", occurredAtMs: 1_001, nativeEvent: "PreToolUse")
        let resumedJSON = try #require(String(data: JSONEncoder().encode(resumed), encoding: .utf8))
        #expect(center.handleAppendCommand(resumedJSON) == "OK 2")
        let receipt = center.recordUserInterrupt(
            surfaceId: surface,
            workspaceId: workspace,
            agentKey: "claude_code",
            source: "claude",
            boundary: clickBoundary
        )
        await receipt.wait()

        let store = try AgentJournalStore(databaseURL: url)
        let events = try store.events(afterSequence: 0, limit: 10)
        store.close()
        #expect(events.map(\.draft.eventId) == ["turn-started", "pre-tool-use"])
    }

    @Test func clickBoundaryNeverPairsANewHeadWithAStaleSessionGeneration() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-turn-control-snapshot-order-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("journal.sqlite3", isDirectory: false)
        let cursorAdvanced = DispatchSemaphore(value: 0)
        let resumeReconciliation = DispatchSemaphore(value: 0)
        let center = AgentJournalLifecycleCenter(
            databaseURL: url,
            reconciliationCursorDidAdvance: { event in
                guard event.draft.eventId == "pre-tool-use" else { return }
                cursorAdvanced.signal()
                _ = resumeReconciliation.wait(timeout: .now() + 5)
            }
        )
        let surface = UUID()
        let workspace = UUID()
        func draft(id: String, occurredAtMs: Int64, nativeEvent: String) -> AgentJournalEventDraft {
            AgentJournalEventDraft(
                eventId: id,
                kind: .turnStarted,
                occurredAtMs: occurredAtMs,
                source: "claude",
                agentKey: "claude_code",
                sessionId: "session-1",
                workspaceId: workspace.uuidString,
                surfaceId: surface.uuidString,
                nativeEvent: nativeEvent
            )
        }

        _ = await center.admitNotification(
            draft(id: "turn-started", occurredAtMs: 1_000, nativeEvent: "UserPromptSubmit")
        )
        let initial = center.captureUserInterruptSessionBoundary(
            surfaceId: surface,
            agentKey: "claude_code"
        )
        #expect(initial.sessionSequences == ["session-1": 1])
        #expect(initial.observedHeadSequence == 1)

        let resumed = Task {
            await center.admitNotification(
                draft(id: "pre-tool-use", occurredAtMs: 1_001, nativeEvent: "PreToolUse")
            )
        }
        try #require(cursorAdvanced.wait(timeout: .now() + 5) == .success)
        defer { resumeReconciliation.signal() }

        #expect(
            center.captureUserInterruptSessionBoundary(
                surfaceId: surface,
                agentKey: "claude_code"
            ) == initial,
            "the click snapshot must stay on the old head until its new session generation is published"
        )
        resumeReconciliation.signal()
        _ = await resumed.value

        let settled = center.captureUserInterruptSessionBoundary(
            surfaceId: surface,
            agentKey: "claude_code"
        )
        #expect(settled.sessionSequences == ["session-1": 2])
        #expect(settled.observedHeadSequence == 2)
    }

    @Test func reconciliationScanStopsAtItsCapturedHeadDuringUnrelatedAppends() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-turn-control-scan-bound-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("journal.sqlite3", isDirectory: false)
        let surface = UUID()
        let otherSurface = UUID()
        let workspace = UUID()
        let writer = try AgentJournalStore(databaseURL: url)
        defer { writer.close() }
        let pageReads = OSAllocatedUnfairLock(initialState: 0)
        let center = AgentJournalLifecycleCenter(
            databaseURL: url,
            reconciliationPageRead: {
                let read = pageReads.withLock { count in
                    count += 1
                    return count
                }
                // Keep committing new unrelated work after every page. The cap
                // makes a regression fail an assertion instead of hanging the suite.
                guard read <= 4 else { return }
                let traffic = AgentJournalEventDraft(
                    eventId: "unrelated-traffic-\(read)",
                    kind: .turnStarted,
                    occurredAtMs: Int64(2_000 + read),
                    source: "claude",
                    agentKey: "claude_code",
                    sessionId: "other-session",
                    workspaceId: workspace.uuidString,
                    surfaceId: otherSurface.uuidString,
                    nativeEvent: "UserPromptSubmit"
                )
                _ = try? writer.append(traffic)
            }
        )
        let started = AgentJournalEventDraft(
            eventId: "turn-started",
            kind: .turnStarted,
            occurredAtMs: 1_000,
            source: "claude",
            agentKey: "claude_code",
            sessionId: "session-1",
            workspaceId: workspace.uuidString,
            surfaceId: surface.uuidString,
            nativeEvent: "UserPromptSubmit"
        )
        _ = await center.admitNotification(started)
        let boundary = center.captureUserInterruptSessionBoundary(
            surfaceId: surface,
            agentKey: "claude_code"
        )
        _ = try writer.append(
            AgentJournalEventDraft(
                eventId: "durable-unrelated",
                kind: .turnStarted,
                occurredAtMs: 1_001,
                source: "claude",
                agentKey: "claude_code",
                sessionId: "other-session",
                workspaceId: workspace.uuidString,
                surfaceId: otherSurface.uuidString,
                nativeEvent: "UserPromptSubmit"
            )
        )

        let receipt = center.recordUserInterrupt(
            surfaceId: surface,
            workspaceId: workspace,
            agentKey: "claude_code",
            source: "claude",
            boundary: boundary
        )
        await receipt.wait()

        #expect(pageReads.withLock { $0 } == 1)
        let events = try writer.events(afterSequence: 0, limit: 20)
        #expect(events.contains { $0.draft.eventId == "unrelated-traffic-1" })
        #expect(!events.contains { $0.draft.eventId == "unrelated-traffic-2" })
        #expect(events.contains {
            $0.draft.nativeEvent == AgentJournalEventDraft.userInterruptNativeEvent
                && $0.draft.sessionId == "session-1"
        })
    }

    @Test func onlyClaudeSettlesItsTurnInTheJournal() {
        #expect(AgentTurnInterruptTarget.claudeCode.settlesTurnInJournal)
        #expect(!AgentTurnInterruptTarget.codex.settlesTurnInJournal)
    }
}

@MainActor
@Suite("Terminal agent Stop button", .serialized)
struct TerminalAgentTurnControlTests {
    private let setting = AgentActionsCatalogSection().turnControl

    @Test
    func stopShowsOnlyWhileEnabledAndRunning() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        setting.set(true, in: .standard)
        defer { setting.removeValue(in: .standard) }
        let view = fixture.panel.hostedView.agentTurnControlView

        #expect(view.isHidden, "No agent is running yet")
        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panel.id, lifecycle: .running)
        #expect(!view.isHidden, "A running Claude turn shows Stop")
        #expect(view.target == .claudeCode)

        setting.set(false, in: .standard)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        #expect(view.isHidden, "Turning the setting off hides Stop mid-turn")
        setting.set(true, in: .standard)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        #expect(!view.isHidden)

        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panel.id, lifecycle: .idle)
        #expect(view.isHidden, "An idle agent has no turn to stop")
        _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: fixture.panel.id)
    }

    @Test
    func stopIsHiddenByDefault() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        setting.removeValue(in: .standard)
        fixture.workspace.setAgentLifecycle(key: "codex", panelId: fixture.panel.id, lifecycle: .running)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "codex", panelId: fixture.panel.id) }
        #expect(fixture.panel.hostedView.agentTurnControlView.isHidden)
    }

    @Test
    func clickingStopTwiceQuicklySendsOneEscape() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        setting.set(true, in: .standard)
        defer { setting.removeValue(in: .standard) }
        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panel.id, lifecycle: .running)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: fixture.panel.id) }
        let before = fixture.panel.surface.debugPendingSocketInputForTesting()
        let stopButton = try #require(stopButton(in: fixture.panel.hostedView.agentTurnControlView))

        stopButton.performClick(nil)

        stopButton.performClick(nil)

        let after = fixture.panel.surface.debugPendingSocketInputForTesting()
        #expect(after.keyEvents == before.keyEvents + 1, "A quick second click sends no second Escape")
    }

    @Test
    func staleStopClickSendsNothing() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        setting.set(true, in: .standard)
        defer { setting.removeValue(in: .standard) }
        let before = fixture.panel.surface.debugPendingSocketInputForTesting()

        // The agent finished before the click landed.
        fixture.panel.interruptAgentTurn(.claudeCode)

        let after = fixture.panel.surface.debugPendingSocketInputForTesting()
        #expect(after.keyEvents == before.keyEvents, "No Escape reaches a pane whose agent is not running")
    }

    @Test(arguments: [
        TerminalSurface.NamedKeySendResult.inputQueueFull,
        .surfaceUnavailable,
        .processExited,
    ])
    func rejectedInterruptInputDoesNotSettleTheJournal(
        result: TerminalSurface.NamedKeySendResult
    ) throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        fixture.workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panel.id,
            lifecycle: .running
        )
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: fixture.panel.id) }
        var journaled = false

        fixture.panel.interruptAgentTurn(
            .claudeCode,
            sendNamedKey: { _ in result },
            recordUserInterrupt: { journaled = true }
        )

        #expect(!journaled)
    }

    @Test(arguments: [
        TerminalSurface.NamedKeySendResult.sent,
        .queued,
    ])
    func acceptedInterruptInputSettlesTheJournal(
        result: TerminalSurface.NamedKeySendResult
    ) throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        fixture.workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panel.id,
            lifecycle: .running
        )
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: fixture.panel.id) }
        var journaled = false

        fixture.panel.interruptAgentTurn(
            .claudeCode,
            sendNamedKey: { _ in result },
            recordUserInterrupt: { journaled = true }
        )

        #expect(journaled)
    }

    private func makeWorkspaceFixture() throws -> (
        windowID: UUID,
        workspace: Workspace,
        panel: TerminalPanel
    ) {
        let appDelegate = try #require(AppDelegate.shared)
        let windowID = appDelegate.createMainWindow()
        do {
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
            let workspace = try #require(manager.selectedWorkspace)
            let panelID = try #require(workspace.focusedPanelId)
            let panel = try #require(workspace.terminalPanel(for: panelID))
            panel.surface.releaseHostedSurfaceForTesting()
            return (windowID, workspace, panel)
        } catch {
            closeWindow(windowID)
            throw error
        }
    }

    private func closeWindow(_ windowID: UUID) {
        let identifier = "cmux.main.\(windowID.uuidString)"
        NSApp.windows.first { $0.identifier?.rawValue == identifier }?.performClose(nil)
    }

    private func stopButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton { return button }
        for subview in view.subviews {
            if let button = stopButton(in: subview) { return button }
        }
        return nil
    }
}
