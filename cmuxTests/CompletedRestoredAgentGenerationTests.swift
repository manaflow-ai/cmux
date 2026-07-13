import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct CompletedRestoredAgentGenerationTests {
    @Test
    func sameSessionNewProcessGenerationSupersedesCompletion() {
        let panelId = UUID()
        let snapshot = agentSnapshot(
            sessionId: "same-session",
            workingDirectory: "/tmp/same-session",
            capturedAt: 90
        )
        let oldIdentity = AgentPIDProcessIdentity(pid: 321, startSeconds: 90, startMicroseconds: 0)
        let newIdentity = AgentPIDProcessIdentity(pid: 321, startSeconds: 101, startMicroseconds: 0)
        let lifecycle = RestoredAgentLifecycleCoordinator(dateProvider: { 100 })
        lifecycle.snapshotsByPanelId[panelId] = snapshot
        lifecycle.resumeStatesByPanelId[panelId] = .observedAgentCommandRunning
        lifecycle.markCompleted(
            panelId: panelId,
            observation: indexEntry(snapshot: snapshot, updatedAt: 95, identity: oldIdentity),
            runtimeProcessIdentities: []
        )

        let staleGenerationAccepted = lifecycle.reconcileCompletedAgent(
            panelId: panelId,
            observation: indexEntry(snapshot: snapshot, updatedAt: 110, identity: oldIdentity),
            currentProcessIdentity: { _ in oldIdentity }
        )
        #expect(!staleGenerationAccepted)
        #expect(lifecycle.resumeStatesByPanelId[panelId] == .completedAgentExit)

        let exitedStaleGenerationAccepted = lifecycle.reconcileCompletedAgent(
            panelId: panelId,
            observation: indexEntry(snapshot: snapshot, updatedAt: 110, identity: oldIdentity),
            currentProcessIdentity: { _ in nil }
        )
        #expect(!exitedStaleGenerationAccepted)
        #expect(lifecycle.resumeStatesByPanelId[panelId] == .completedAgentExit)

        let newGenerationAccepted = lifecycle.reconcileCompletedAgent(
            panelId: panelId,
            observation: indexEntry(snapshot: snapshot, updatedAt: 95, identity: newIdentity),
            currentProcessIdentity: { _ in newIdentity }
        )
        #expect(newGenerationAccepted)
        #expect(lifecycle.resumeStatesByPanelId[panelId] == .observedAgentCommandRunning)
    }

    @Test
    func newerHookTimestampWithoutLiveAgentDoesNotSupersedeCompletion() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let sessionId = "completed-agent-stale-hook"
        let oldWorkingDirectory = "/tmp/completed-agent-stale-hook-old"
        workspace.restoredAgentSnapshotsByPanelId[panelId] = agentSnapshot(
            sessionId: sessionId,
            workingDirectory: oldWorkingDirectory,
            capturedAt: Date.now.timeIntervalSince1970 - 60
        )
        workspace.restoredAgentResumeStatesByPanelId[panelId] = .observedAgentCommandRunning
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        try #require(workspace.restoredAgentResumeStatesByPanelId[panelId] == .completedAgentExit)

        let fixture = try makeIndexFixture(
            workspaceId: workspace.id,
            panelId: panelId,
            sessionId: sessionId,
            updatedAt: Date.now.timeIntervalSince1970 + 60
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: fixture.index
        )

        #expect(snapshot.panels.first?.terminal?.agent == nil)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .completedAgentExit)
        #expect(workspace.restoredAgentSnapshotsByPanelId[panelId]?.sessionId == sessionId)
        #expect(!workspace.allowsAgentContinuation(forPanelId: panelId))
    }

    @Test
    func transferredCompletionGenerationAcceptsAgentStartedBeforeAttach() throws {
        let panelId = UUID()
        let snapshot = agentSnapshot(
            sessionId: "detached-agent-restarted",
            workingDirectory: "/tmp/detached-agent-restarted",
            capturedAt: 90
        )
        let source = RestoredAgentLifecycleCoordinator(dateProvider: { 100 })
        source.snapshotsByPanelId[panelId] = snapshot
        source.resumeStatesByPanelId[panelId] = .observedAgentCommandRunning
        source.markCompleted(
            panelId: panelId,
            observation: nil,
            runtimeProcessIdentities: []
        )
        let transferredGeneration = try #require(source.completedGeneration(panelId: panelId))

        let destination = RestoredAgentLifecycleCoordinator(dateProvider: { 200 })
        destination.seedTransferredState(
            panelId: panelId,
            snapshot: snapshot,
            resumeState: .completedAgentExit,
            completedGeneration: transferredGeneration
        )
        let replacementIdentity = AgentPIDProcessIdentity(
            pid: 654,
            startSeconds: 150,
            startMicroseconds: 0
        )

        let accepted = destination.reconcileCompletedAgent(
            panelId: panelId,
            observation: indexEntry(
                snapshot: snapshot,
                updatedAt: 160,
                identity: replacementIdentity
            ),
            currentProcessIdentity: { _ in replacementIdentity }
        )

        #expect(accepted)
        #expect(destination.resumeStatesByPanelId[panelId] == .observedAgentCommandRunning)
    }

    @Test
    func workspaceTransferPreservesCompletionGenerationAndShellActivity() throws {
        let source = Workspace()
        let panelId = try #require(source.focusedPanelId)
        let snapshot = agentSnapshot(
            sessionId: "workspace-transfer-completed-agent",
            workingDirectory: "/tmp/workspace-transfer-completed-agent",
            capturedAt: Date.now.timeIntervalSince1970 - 60
        )
        source.restoredAgentSnapshotsByPanelId[panelId] = snapshot
        source.restoredAgentResumeStatesByPanelId[panelId] = .observedAgentCommandRunning
        source.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        source.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        let sourceGeneration = try #require(source.restoredAgentLifecycle.completedGeneration(panelId: panelId))

        let detached = try #require(source.detachSurface(panelId: panelId))
        #expect(detached.shellActivityState == .promptIdle)
        #expect(detached.restoredAgentCompletedGeneration?.completedAt == sourceGeneration.completedAt)

        let destination = Workspace()
        let destinationPaneId = try #require(destination.bonsplitController.focusedPaneId)
        #expect(
            destination.attachDetachedSurface(
                detached,
                inPane: destinationPaneId,
                focus: false
            ) == panelId
        )
        #expect(destination.panelShellActivityStates[panelId] == .promptIdle)
        #expect(
            destination.restoredAgentLifecycle.completedGeneration(panelId: panelId)?.completedAt
                == sourceGeneration.completedAt
        )
    }

    @Test
    func delayedIndexRefreshAfterNewAgentExitDoesNotReviveIt() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let completedSessionId = "completed-before-delayed-refresh"
        workspace.restoredAgentSnapshotsByPanelId[panelId] = agentSnapshot(
            sessionId: completedSessionId,
            workingDirectory: "/tmp/completed-before-delayed-refresh",
            capturedAt: Date.now.timeIntervalSince1970 - 60
        )
        workspace.restoredAgentResumeStatesByPanelId[panelId] = .observedAgentCommandRunning
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        try #require(workspace.restoredAgentResumeStatesByPanelId[panelId] == .completedAgentExit)

        let fixture = try makeIndexFixture(
            workspaceId: workspace.id,
            panelId: panelId,
            sessionId: "new-agent-that-already-exited",
            updatedAt: Date.now.timeIntervalSince1970 + 60
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: fixture.index
        )

        #expect(snapshot.panels.first?.terminal?.agent == nil)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .completedAgentExit)
        #expect(workspace.restoredAgentSnapshotsByPanelId[panelId]?.sessionId == completedSessionId)
        #expect(!workspace.allowsAgentContinuation(forPanelId: panelId))
    }

    private func agentSnapshot(
        sessionId: String,
        workingDirectory: String,
        capturedAt: TimeInterval
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/usr/local/bin/claude",
                arguments: ["/usr/local/bin/claude", "--resume", sessionId],
                workingDirectory: workingDirectory,
                capturedAt: capturedAt,
                source: "test"
            )
        )
    }

    private func indexEntry(
        snapshot: SessionRestorableAgentSnapshot,
        updatedAt: TimeInterval,
        identity: AgentPIDProcessIdentity
    ) -> RestorableAgentSessionIndex.Entry {
        RestorableAgentSessionIndex.Entry(
            snapshot: snapshot,
            lifecycle: .running,
            updatedAt: updatedAt,
            processIDs: [Int(identity.pid)],
            agentProcessIDs: [Int(identity.pid)],
            agentProcessIdentities: [Int(identity.pid): identity]
        )
    }

    private func makeIndexFixture(
        workspaceId: UUID,
        panelId: UUID,
        sessionId: String,
        updatedAt: TimeInterval
    ) throws -> (root: URL, workingDirectory: URL, index: RestorableAgentSessionIndex) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-completed-agent-generation-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("claude-config", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let transcriptURL = configDirectory
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(expectedClaudeProjectDirectoryName(workingDirectory.path), isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try writeClaudeTranscript(sessionId: sessionId, transcriptURL: transcriptURL)
        try writeClaudeHookStore(
            root: root,
            sessionId: sessionId,
            workspaceId: workspaceId,
            panelId: panelId,
            workingDirectory: workingDirectory.path,
            configDirectory: configDirectory.path,
            transcriptPath: transcriptURL.path,
            updatedAt: updatedAt
        )
        return (
            root,
            workingDirectory,
            RestorableAgentSessionIndex.load(homeDirectory: root.path)
        )
    }

    private func expectedClaudeProjectDirectoryName(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func writeClaudeTranscript(sessionId: String, transcriptURL: URL) throws {
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"last-prompt","sessionId":"\(sessionId)"}

        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    private func writeClaudeHookStore(
        root: URL,
        sessionId: String,
        workspaceId: UUID,
        panelId: UUID,
        workingDirectory: String,
        configDirectory: String,
        transcriptPath: String,
        updatedAt: TimeInterval
    ) throws {
        let stateDirectory = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": panelId.uuidString,
            "cwd": workingDirectory,
            "pid": NSNull(),
            "isRestorable": true,
            "updatedAt": updatedAt,
            "transcriptPath": transcriptPath,
            "launchCommand": [
                "launcher": "claude",
                "executablePath": "/usr/local/bin/claude",
                "arguments": ["/usr/local/bin/claude"],
                "workingDirectory": workingDirectory,
                "environment": ["CLAUDE_CONFIG_DIR": configDirectory],
                "capturedAt": updatedAt,
                "source": "test",
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: ["version": 1, "sessions": [sessionId: record]],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: stateDirectory.appendingPathComponent("claude-hook-sessions.json"))
    }
}
