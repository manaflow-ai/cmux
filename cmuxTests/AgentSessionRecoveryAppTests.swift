import CMUXAgentLaunch
import Darwin
import CmuxAgentJournal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Incident 2026-09-26: cmux died with `sr claude proxy` sessions open and the
/// relaunch brought none back, though the journal and hook store knew them all.
@Suite(.serialized)
struct AgentSessionRecoveryAppTests {
    @Test
    func sessionsKilledWithTheAppResumeThroughTheirLauncher() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let journalURL = root.appendingPathComponent("journal.sqlite3")
        let store = try AgentJournalStore(databaseURL: journalURL)
        func append(_ kind: AgentJournalEventKind, _ session: String) throws {
            _ = try store.append(AgentJournalEventDraft(
                kind: kind,
                occurredAtMs: Int64(now.addingTimeInterval(-120).timeIntervalSince1970 * 1000),
                source: "claude",
                agentKey: "claude_code",
                sessionId: session,
                workspaceId: UUID().uuidString,
                surfaceId: UUID().uuidString
            ))
        }
        try append(.sessionStarted, "0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11")
        try append(.turnStarted, "0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11")
        try append(.sessionStarted, "plain")
        try append(.sessionStarted, "finished")
        try append(.sessionEnded, "finished")
        try append(.sessionStarted, "already-open")
        try append(.sessionStarted, "no-transcript")
        try append(.sessionStarted, "no-pid")
        try append(.sessionStarted, "missing-pid-start")
        store.close()

        func record(
            _ id: String,
            cwd: String,
            launch: AgentLaunchCommand,
            hasTranscript: Bool = true,
            pid: Int? = 999_999,
            pidStartSeconds: Int64? = 1
        ) throws -> RestorableAgentHookSessionRecord {
            let transcript = root.appendingPathComponent("\(id).jsonl")
            if hasTranscript { try Data("{}\n".utf8).write(to: transcript) }
            return RestorableAgentHookSessionRecord(
                sessionId: id,
                workspaceId: UUID().uuidString,
                surfaceId: UUID().uuidString,
                cwd: cwd,
                transcriptPath: transcript.path,
                pid: pid,
                pidStartSeconds: pidStartSeconds,
                launchCommand: launch,
                isRestorable: true,
                updatedAt: now.timeIntervalSince1970
            )
        }
        let proxied = AgentLaunchCommand(
            launcher: "claude",
            arguments: ["claude"],
            launcherPrefix: ["sr", "claude", "proxy", "--account", "me@example.com"]
        )
        let plain = AgentLaunchCommand(launcher: "claude", arguments: ["claude"])
        var file = RestorableAgentHookSessionStoreFile()
        file.sessions = [
            "0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11": try record("0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11", cwd: "/Users/me/Projects/my app", launch: proxied),
            "plain": try record("plain", cwd: "/Users/me/Projects/plain", launch: plain),
            "finished": try record("finished", cwd: "/tmp", launch: plain),
            "already-open": try record("already-open", cwd: "/tmp", launch: plain),
            "no-transcript": try record("no-transcript", cwd: "/tmp", launch: plain, hasTranscript: false),
            // A hook that never saw the agent's pid still leaves a resumable session.
            "no-pid": try record("no-pid", cwd: "/tmp", launch: plain, pid: nil),
            // A PID without its process generation is stale evidence. Use
            // this test process so the pre-fix liveness check suppresses it.
            "missing-pid-start": try record(
                "missing-pid-start",
                cwd: "/tmp",
                launch: plain,
                pid: Int(getpid()),
                pidStartSeconds: nil
            ),
        ]
        try JSONEncoder().encode(file).write(to: root.appendingPathComponent("claude-hook-sessions.json"))

        let recovery = AgentSessionRecovery(
            journalURL: journalURL,
            homeDirectory: root.path,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": root.path]
        )
        let candidates = recovery.candidates(openSessionIds: ["already-open"], now: now)
        #expect(Set(candidates.map(\.sessionId)) == ["0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11", "plain", "no-pid", "missing-pid-start"])

        let proxiedCandidate = try #require(candidates.first { $0.sessionId == "0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11" })
        let proxiedCommand = try #require(AgentSessionRecovery.resumeCommand(for: proxiedCandidate))
        // The launcher argv runs inside the portable `/bin/sh -c` wrapper that
        // keeps cmux's Claude shim on PATH for the re-exec'd agent.
        #expect(proxiedCommand.hasPrefix("/bin/sh -c "))
        #expect(proxiedCommand.contains("CMUX_CLAUDE_WRAPPER_SHIM"))
        for word in ["sr", "claude", "proxy", "--account", "me@example.com", "--resume", "0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11"] {
            #expect(proxiedCommand.contains(word))
        }
        #expect(AgentSessionRecovery.workspaceTitle(for: proxiedCandidate) == "my app")

        let plainCandidate = try #require(candidates.first { $0.sessionId == "plain" })
        let plainCommand = try #require(AgentSessionRecovery.resumeCommand(for: plainCandidate))
        // Without a launcher prefix, recovery resumes through the restore verb.
        #expect(plainCommand.hasSuffix(" restore claude plain"))
    }

    /// A routed Claude session resumes through `cmux restore`, the path a
    /// normal restore takes, from a panel carrying its restore record. That
    /// path checks the launcher on PATH, authorizes the wrapper, and reapplies
    /// the observed permission mode.
    @Test
    func routedSessionsResumeThroughTheRestoreVerb() throws {
        let candidate = AgentRecoveryCandidate(
            kind: "claude",
            sessionId: "0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11",
            workspaceId: nil,
            cwd: "/tmp",
            launchCommand: AgentLaunchCommand(
                launcher: "claude",
                arguments: ["claude", "--model", "opus"],
                environment: [
                    SubrouterClaudeResumeRouting.environmentKey: "sr claude proxy --resume",
                    SubrouterClaudeResumeRouting.launchBoundEnvironmentKey: "sr claude proxy --resume",
                ],
                launcherPrefix: ["sr", "claude", "proxy", "--account", "me@example.com"]
            ),
            permissionMode: "acceptEdits",
            lastActivity: Date()
        )
        let launch = try #require(AgentSessionRecovery.launch(for: candidate))
        guard case let .restoreVerb(input, agent) = launch else {
            Issue.record("Expected the restore verb, got \(launch)")
            return
        }
        #expect(input.hasSuffix(" restore claude 0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11\n"))
        #expect(agent.sessionId == candidate.sessionId)
        #expect(agent.permissionMode == "acceptEdits")
        #expect(agent.launchCommand?.launcherPrefix == candidate.launchCommand?.launcherPrefix)
    }

    /// Closing a Claude pane kills the agent before its own end hook reports,
    /// so the journal kept the session open and the next crash recovery
    /// reopened a pane the user had closed.
    @MainActor
    @Test
    func closedClaudePaneIsNotRecoveredAfterACrash() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-recovery-close-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let closedID = "5d1c7a52-0d0e-4b1f-9a4e-2f0f7a9c1e01"
        let killedID = "5d1c7a52-0d0e-4b1f-9a4e-2f0f7a9c1e02"
        let now = Date()
        let journalURL = root.appendingPathComponent("journal.sqlite3")
        let store = try AgentJournalStore(databaseURL: journalURL)
        for id in [closedID, killedID] {
            _ = try store.append(AgentJournalEventDraft(
                kind: .sessionStarted,
                occurredAtMs: Int64(now.addingTimeInterval(-60).timeIntervalSince1970 * 1000),
                source: "claude",
                agentKey: "claude_code",
                sessionId: id,
                workspaceId: UUID().uuidString,
                surfaceId: UUID().uuidString
            ))
        }
        store.close()

        var file = RestorableAgentHookSessionStoreFile()
        for id in [closedID, killedID] {
            let transcript = root.appendingPathComponent("\(id).jsonl")
            try Data("{}\n".utf8).write(to: transcript)
            file.sessions[id] = RestorableAgentHookSessionRecord(
                sessionId: id,
                workspaceId: UUID().uuidString,
                surfaceId: UUID().uuidString,
                cwd: "/tmp",
                transcriptPath: transcript.path,
                pid: nil,
                launchCommand: AgentLaunchCommand(launcher: "claude", arguments: ["claude"]),
                isRestorable: true,
                updatedAt: now.timeIntervalSince1970
            )
        }
        try JSONEncoder().encode(file).write(to: root.appendingPathComponent("claude-hook-sessions.json"))

        let center = AgentJournalLifecycleCenter(databaseURL: journalURL)
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        workspace.agentSessionCloseJournal = AgentSessionCloseJournal(center: center)
        let keptPanel = try #require(workspace.focusedPanelId)
        let closedPanel = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false)).id
        #expect(closedPanel != keptPanel)
        // What the Claude session-start hook leaves on the surface.
        workspace.surfaceResumeBindingsByPanelId[closedPanel] = SurfaceResumeBindingSnapshot(
            name: "Claude Code", kind: "claude", command: "claude --resume \(closedID)",
            checkpointId: closedID, source: "agent-hook", updatedAt: now.timeIntervalSince1970
        )

        #expect(workspace.closePanel(closedPanel, force: true))

        // The close is journaled on the center's consumer; wait for it to land.
        let reader = AgentJournalSessionTailReader(databaseURL: journalURL)
        func closedHasEnded() -> Bool {
            let tails = (try? reader.sessionTails(occurredAtOrAfterMs: 0)) ?? []
            return tails.first { $0.sessionId == closedID }?.hasEnded == true
        }
        for _ in 0..<100 where !closedHasEnded() {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(closedHasEnded())

        // cmux now crashes; the next launch recovers only the session that
        // died with the app.
        let recovery = AgentSessionRecovery(
            journalURL: journalURL,
            homeDirectory: root.path,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": root.path]
        )
        let recovered = recovery.candidates(openSessionIds: [], activeSince: now.addingTimeInterval(-600), now: now)
        #expect(recovered.map(\.sessionId) == [killedID])
    }

    /// Recovery used to start every lost session at once, so a heavy user's
    /// relaunch spawned dozens of agents together. Only a few start now; the
    /// rest open their workspace and resume on its first visit.
    @MainActor
    @Test
    func recoveryStartsOnlyAFewSessionsAtOnce() throws {
        let manager = TabManager()
        let existing = Set(manager.tabs.map(\.id))
        defer {
            for workspace in manager.tabs where !existing.contains(workspace.id) {
                workspace.teardownAllPanels()
            }
        }
        let now = Date()
        let candidates = (1...6).map { index in
            AgentRecoveryCandidate(
                kind: "claude",
                sessionId: "6a0f2c1e-1d3b-4c55-8e0a-7b9d2f4c1a0\(index)",
                workspaceId: nil,
                cwd: "/tmp",
                launchCommand: AgentLaunchCommand(launcher: "claude", arguments: ["claude"]),
                lastActivity: now.addingTimeInterval(-Double(index) * 60)
            )
        }

        let reopened = AgentSessionRecovery.reopen(candidates, in: manager, alreadyOpen: [])

        #expect(Set(reopened) == Set(candidates.map(\.sessionId)))
        let recovered = manager.tabs.filter { !existing.contains($0.id) }
        #expect(recovered.count == candidates.count)
        #expect(manager.pendingBackgroundWorkspaceLoadIds.count == AgentRecoveryStartPlan.defaultImmediateLimit)
        // Only the sessions picked to start now are released; the rest hold
        // their terminal until their workspace is first shown.
        func isHeld(_ workspace: Workspace) -> Bool {
            workspace.focusedTerminalPanel?.surface.isAwaitingStartupRestoreAdmission == true
        }
        let held = recovered.filter(isHeld)
        #expect(held.count == candidates.count - AgentRecoveryStartPlan.defaultImmediateLimit)
        let visited = try #require(held.first)
        manager.selectedTabId = visited.id
        #expect(!isHeld(visited))
        #expect(visited.startupRestorePanelIdsAwaitingFirstVisit.isEmpty)
        // Every recovered panel carries its session, so a second recovery
        // skips the ones that have not started yet.
        let carried = Set(recovered.flatMap { $0.restoredAgentSnapshotsByPanelId.values.map(\.sessionId) })
        #expect(carried == Set(candidates.map(\.sessionId)))
    }

    /// Closing a Claude pane in the Dock must journal its end the same way a
    /// workspace pane does, or crash recovery brings the closed pane back.
    @MainActor
    @Test
    func closedDockClaudePaneJournalsItsEnd() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-recovery-dock-close-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "5d1c7a52-0d0e-4b1f-9a4e-2f0f7a9c1e03"
        // A second pane whose hook binding the Dock keeps aside while process
        // detection shows a tmux binding.
        let managedSessionID = "5d1c7a52-0d0e-4b1f-9a4e-2f0f7a9c1e04"
        let journalURL = root.appendingPathComponent("journal.sqlite3")
        let store = try AgentJournalStore(databaseURL: journalURL)
        for id in [sessionID, managedSessionID] {
            _ = try store.append(AgentJournalEventDraft(
                kind: .sessionStarted,
                occurredAtMs: Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1000),
                source: "claude",
                agentKey: "claude_code",
                sessionId: id,
                workspaceId: UUID().uuidString,
                surfaceId: UUID().uuidString
            ))
        }
        store.close()

        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { dock.closeAllPanels() }
        dock.agentSessionCloseJournal = AgentSessionCloseJournal(
            center: AgentJournalLifecycleCenter(databaseURL: journalURL)
        )
        let pane = try #require(dock.bonsplitController.allPaneIds.first)
        let panelID = try #require(dock.newSurface(kind: .terminal, inPane: pane, focus: false))
        let tabID = try #require(dock.surfaceId(forPanelId: panelID))
        // What the Claude session-start hook leaves on the surface.
        dock.surfaceResumeBindingsByPanelId[panelID] = SurfaceResumeBindingSnapshot(
            name: "Claude Code", kind: "claude", command: "claude --resume \(sessionID)",
            checkpointId: sessionID, source: "agent-hook", updatedAt: Date().timeIntervalSince1970
        )

        let managedPanelID = try #require(dock.newSurface(kind: .terminal, inPane: pane, focus: false))
        let managedTabID = try #require(dock.surfaceId(forPanelId: managedPanelID))
        dock.managedAgentResumeBindingsByPanelId[managedPanelID] = SurfaceResumeBindingSnapshot(
            name: "Claude Code", kind: "claude", command: "claude --resume \(managedSessionID)",
            checkpointId: managedSessionID, source: "agent-hook", updatedAt: Date().timeIntervalSince1970
        )

        dock.forceCloseDockTabIds.formUnion([tabID, managedTabID])
        defer { dock.forceCloseDockTabIds.subtract([tabID, managedTabID]) }
        #expect(dock.bonsplitController.closeTab(tabID))
        #expect(dock.bonsplitController.closeTab(managedTabID))
        dock.reconcilePanels()
        #expect(dock.panels[panelID] == nil)
        #expect(dock.panels[managedPanelID] == nil)

        let reader = AgentJournalSessionTailReader(databaseURL: journalURL)
        func hasEnded() -> Bool {
            let tails = (try? reader.sessionTails(occurredAtOrAfterMs: 0)) ?? []
            return [sessionID, managedSessionID].allSatisfy { id in
                tails.first { $0.sessionId == id }?.hasEnded == true
            }
        }
        for _ in 0..<100 where !hasEnded() {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(hasEnded())
    }

    /// A Dock keeps its agent-hook binding aside while process detection makes
    /// a tmux binding effective. Closing a stale pane for that same session
    /// must not end the session still carried by the other pane.
    @MainActor
    @Test
    func closingStaleDockPanePreservesManagedSessionCarriedElsewhere() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-recovery-dock-carried-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let carriedSessionID = "5d1c7a52-0d0e-4b1f-9a4e-2f0f7a9c1e05"
        let barrierSessionID = "5d1c7a52-0d0e-4b1f-9a4e-2f0f7a9c1e06"
        let journalURL = root.appendingPathComponent("journal.sqlite3")
        let store = try AgentJournalStore(databaseURL: journalURL)
        for id in [carriedSessionID, barrierSessionID] {
            _ = try store.append(AgentJournalEventDraft(
                kind: .sessionStarted,
                occurredAtMs: Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000),
                source: "claude",
                agentKey: "claude_code",
                sessionId: id,
                workspaceId: UUID().uuidString,
                surfaceId: UUID().uuidString
            ))
        }
        store.close()

        let previousApp = AppDelegate.shared
        let app = AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.tabManager = manager
        defer {
            app.tabManager = nil
            manager.finalizeAllWorkspacesForWindowClose()
            AppDelegate.shared = previousApp
        }
        let workspace = try #require(manager.selectedWorkspace)
        let dock = try #require(workspace.dockSplit)
        dock.agentSessionCloseJournal = AgentSessionCloseJournal(
            center: AgentJournalLifecycleCenter(databaseURL: journalURL)
        )
        let pane = try #require(dock.bonsplitController.allPaneIds.first)

        let stalePanelID = try #require(dock.newSurface(kind: .terminal, inPane: pane, focus: false))
        let staleTabID = try #require(dock.surfaceId(forPanelId: stalePanelID))
        dock.managedAgentResumeBindingsByPanelId[stalePanelID] = SurfaceResumeBindingSnapshot(
            name: "Claude Code", kind: "claude", command: "claude --resume \(carriedSessionID)",
            checkpointId: carriedSessionID, source: "agent-hook", updatedAt: Date().timeIntervalSince1970
        )

        let carrierPanelID = try #require(dock.newSurface(kind: .terminal, inPane: pane, focus: false))
        dock.surfaceResumeBindingsByPanelId[carrierPanelID] = SurfaceResumeBindingSnapshot(
            name: "tmux", kind: "tmux", command: "tmux attach -t agent",
            checkpointId: nil, source: "process-detected", updatedAt: Date().timeIntervalSince1970
        )
        dock.managedAgentResumeBindingsByPanelId[carrierPanelID] = SurfaceResumeBindingSnapshot(
            name: "Claude Code", kind: "claude", command: "claude --resume \(carriedSessionID)",
            checkpointId: carriedSessionID, source: "agent-hook", updatedAt: Date().timeIntervalSince1970
        )

        let barrierPanelID = try #require(dock.newSurface(kind: .terminal, inPane: pane, focus: false))
        let barrierTabID = try #require(dock.surfaceId(forPanelId: barrierPanelID))
        dock.surfaceResumeBindingsByPanelId[barrierPanelID] = SurfaceResumeBindingSnapshot(
            name: "Claude Code", kind: "claude", command: "claude --resume \(barrierSessionID)",
            checkpointId: barrierSessionID, source: "agent-hook", updatedAt: Date().timeIntervalSince1970
        )

        // Close the stale pane first. The barrier closes second, so observing
        // its end proves the journal consumer already handled any stale end.
        dock.forceCloseDockTabIds.formUnion([staleTabID, barrierTabID])
        defer { dock.forceCloseDockTabIds.subtract([staleTabID, barrierTabID]) }
        #expect(dock.bonsplitController.closeTab(staleTabID))
        dock.reconcilePanels()
        #expect(dock.bonsplitController.closeTab(barrierTabID))
        dock.reconcilePanels()

        let reader = AgentJournalSessionTailReader(databaseURL: journalURL)
        func barrierHasEnded() -> Bool {
            let tails = (try? reader.sessionTails(occurredAtOrAfterMs: 0)) ?? []
            return tails.first { $0.sessionId == barrierSessionID }?.hasEnded == true
        }
        for _ in 0..<100 where !barrierHasEnded() {
            try await Task.sleep(for: .milliseconds(50))
        }
        let tails = try reader.sessionTails(occurredAtOrAfterMs: 0)
        #expect(tails.first { $0.sessionId == barrierSessionID }?.hasEnded == true)
        #expect(tails.first { $0.sessionId == carriedSessionID }?.hasEnded != true)
    }

    @Test
    func restoreRejectsMalformedSessionIDsBeforeReadingAppState() {
        let invalidValues: [Any] = [
            "one-session",
            [String](),
            [1],
            NSNull(),
        ]
        for value in invalidValues {
            let result = TerminalController.shared.v2AgentRecoveryRestore(
                params: ["session_ids": value]
            )
            guard case let .err(code, _, _) = result else {
                Issue.record("Expected invalid_params for malformed session_ids")
                continue
            }
            #expect(code == "invalid_params")
        }
    }
}
