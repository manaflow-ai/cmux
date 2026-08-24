import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SurfaceResumeAgentBindingGenerationTests {
    @Test("A stale cached session cannot authorize the current binding")
    func staleCachedSessionCannotAuthorizeCurrentBinding() throws {
        try withFixture { source, defaults, index in
            let currentSessionID = "codex-current-dead-session"
            let bindingIndex = codexBindingIndex(
                sessionID: currentSessionID,
                workspaceID: source.id,
                panelID: try #require(source.focusedPanelId)
            )

            let snapshot = source.sessionSnapshot(
                includeScrollback: false,
                restorableAgentIndex: index,
                surfaceResumeBindingIndex: bindingIndex
            )

            #expect(snapshot.panels.first?.terminal?.wasAgentRunning == false)
            try expectNoResumeLaunch(snapshot: snapshot, defaults: defaults)
        }
    }

    @Test("An exact live runtime generation authorizes a newer binding")
    func exactLiveRuntimeGenerationAuthorizesNewerBinding() throws {
        try withFixture { source, defaults, index in
            let panelID = try #require(source.focusedPanelId)
            let currentSessionID = "codex-current-live-session"
            source.recordAgentPID(
                key: "codex.\(currentSessionID)",
                pid: getpid(),
                panelId: panelID,
                refreshPorts: false
            )

            let snapshot = source.sessionSnapshot(
                includeScrollback: false,
                restorableAgentIndex: index,
                surfaceResumeBindingIndex: codexBindingIndex(
                    sessionID: currentSessionID,
                    workspaceID: source.id,
                    panelID: panelID
                )
            )

            #expect(snapshot.panels.first?.terminal?.wasAgentRunning == true)
            let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
            defer { restored.teardownAllPanels() }
            restored.restoreSessionSnapshot(snapshot)
            let restoredPanelID = try #require(restored.focusedPanelId)
            let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))
            #expect(restoredPanel.surface.debugInitialCommand() == nil)
            #expect(restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)
        }
    }

    @Test("An agent binding without a restorable generation does not launch")
    func agentBindingWithoutRestorableGenerationDoesNotLaunch() throws {
        let defaultsName = "cmux-binding-without-generation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { source.teardownAllPanels() }
        let panelID = try #require(source.focusedPanelId)
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: codexBindingIndex(
                sessionID: "codex-missing-generation",
                workspaceID: source.id,
                panelID: panelID
            )
        )

        #expect(snapshot.panels.first?.terminal?.wasAgentRunning == false)
        try expectNoResumeLaunch(snapshot: snapshot, defaults: defaults)
    }

    @Test("A restored Codex binding remains restorable across generations")
    func restoredCodexBindingRemainsRestorableAcrossGenerations() throws {
        try withFixture { source, defaults, index in
            let sourcePanelID = try #require(source.focusedPanelId)
            let sessionID = "a22293b7-bcef-4707-8439-2f538c8517a4"
            let expectedRestoreInput =
                " \(AgentRestoreLaunch.cliStartupExecutableToken) restore codex \(sessionID)\n"
            source.updatePanelShellActivityState(panelId: sourcePanelID, state: .commandRunning)
            source.recordAgentPID(
                key: "codex.\(sessionID)",
                pid: getpid(),
                panelId: sourcePanelID,
                refreshPorts: false
            )

            let sourceSnapshot = source.sessionSnapshot(
                includeScrollback: false,
                restorableAgentIndex: index,
                surfaceResumeBindingIndex: codexBindingIndex(
                    sessionID: sessionID,
                    workspaceID: source.id,
                    panelID: sourcePanelID
                )
            )
            let sourceTerminal = try #require(sourceSnapshot.panels.first?.terminal)
            #expect(sourceTerminal.wasAgentRunning == true)
            #expect(sourceTerminal.resumeBinding?.restoreStartupInput() == expectedRestoreInput)

            let firstRestore = Workspace(agentSessionAutoResumeDefaults: defaults)
            defer { firstRestore.teardownAllPanels() }
            firstRestore.restoreSessionSnapshot(sourceSnapshot)
            let firstPanelID = try #require(firstRestore.focusedPanelId)
            #expect(
                firstRestore.restoredAgentResumeStatesByPanelId[firstPanelID]
                    == .awaitingAutoResumeCommand
            )
            let queuedLaunchSnapshot = firstRestore.sessionSnapshot(
                includeScrollback: false,
                restorableAgentIndex: .empty,
                surfaceResumeBindingIndex: SurfaceResumeBindingIndex(bindingsByPanel: [:])
            )
            #expect(queuedLaunchSnapshot.panels.first?.terminal?.wasAgentRunning == false)
            #expect(
                queuedLaunchSnapshot.panels.first?.terminal?.resumeBinding?.checkpointId
                    == sessionID
            )
            firstRestore.updatePanelShellActivityState(panelId: firstPanelID, state: .commandRunning)
            #expect(
                firstRestore.restoredAgentResumeStatesByPanelId[firstPanelID]
                    == .autoResumeCommandRunning
            )

            // Codex does not publish a fresh hook record after this restore-verb
            // launch. The shell callback is the only fresh evidence that the
            // restored command is running when the next autosave reconciles.
            let secondGenerationSnapshot = firstRestore.sessionSnapshot(
                includeScrollback: false,
                restorableAgentIndex: .empty,
                surfaceResumeBindingIndex: SurfaceResumeBindingIndex(bindingsByPanel: [:])
            )
            let secondGenerationTerminal = try #require(
                secondGenerationSnapshot.panels.first?.terminal
            )
            #expect(secondGenerationTerminal.wasAgentRunning == true)
            #expect(
                secondGenerationTerminal.resumeBinding?.checkpointId == sessionID
            )
            #expect(
                secondGenerationTerminal.resumeBinding?.restoreStartupInput()
                    == expectedRestoreInput
            )

            let secondRestore = Workspace(agentSessionAutoResumeDefaults: defaults)
            defer { secondRestore.teardownAllPanels() }
            secondRestore.restoreSessionSnapshot(secondGenerationSnapshot)
            let secondPanelID = try #require(secondRestore.focusedPanelId)
            #expect(
                secondRestore.restoredAgentResumeStatesByPanelId[secondPanelID]
                    == .awaitingAutoResumeCommand
            )
            secondRestore.updatePanelShellActivityState(panelId: secondPanelID, state: .commandRunning)

            let thirdGenerationSnapshot = secondRestore.sessionSnapshot(
                includeScrollback: false,
                restorableAgentIndex: .empty,
                surfaceResumeBindingIndex: SurfaceResumeBindingIndex(bindingsByPanel: [:])
            )
            let thirdGenerationTerminal = try #require(
                thirdGenerationSnapshot.panels.first?.terminal
            )
            #expect(thirdGenerationTerminal.wasAgentRunning == true)
            #expect(thirdGenerationTerminal.resumeBinding?.checkpointId == sessionID)
            #expect(
                thirdGenerationTerminal.resumeBinding?.restoreStartupInput()
                    == expectedRestoreInput
            )
        }
    }

    @Test("A restored Grok binding relaunches through cmux restore across generations")
    func restoredGrokBindingUsesRestoreVerbAcrossGenerations() throws {
        let defaultsName = "cmux-grok-binding-generation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)
        let sessionID = "019fbf20-689d-76f3-8e7f-1220929e8140"
        let expectedRestoreInput =
            " \(AgentRestoreLaunch.cliStartupExecutableToken) restore grok \(sessionID)\n"
        let sourceBinding = grokBinding(sessionID: sessionID)
        #expect(source.setSurfaceResumeBinding(sourceBinding, panelId: sourcePanelID))
        source.updatePanelShellActivityState(panelId: sourcePanelID, state: .commandRunning)
        source.recordAgentPID(
            key: "grok.\(sessionID)",
            pid: getpid(),
            panelId: sourcePanelID,
            refreshPorts: false
        )

        let sourceSnapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: grokBindingIndex(
                sessionID: sessionID,
                workspaceID: source.id,
                panelID: sourcePanelID
            )
        )
        #expect(sourceSnapshot.panels.first?.terminal?.wasAgentRunning == true)

        let firstRestore = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { firstRestore.teardownAllPanels() }
        firstRestore.restoreSessionSnapshot(sourceSnapshot)
        let firstPanelID = try #require(firstRestore.focusedPanelId)
        let firstPanel = try #require(firstRestore.terminalPanel(for: firstPanelID))
        #expect(firstPanel.surface.debugInitialInputForTesting() == expectedRestoreInput)
        #expect(firstRestore.restoredAgentResumeStatesByPanelId[firstPanelID] == .awaitingAutoResumeCommand)

        firstRestore.updatePanelShellActivityState(panelId: firstPanelID, state: .commandRunning)
        #expect(firstRestore.setSurfaceResumeBinding(
            grokBinding(sessionID: sessionID, updatedAt: 1_888_888_889),
            panelId: firstPanelID
        ))

        let secondGenerationSnapshot = firstRestore.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: SurfaceResumeBindingIndex(bindingsByPanel: [:])
        )
        let secondGenerationTerminal = try #require(
            secondGenerationSnapshot.panels.first?.terminal
        )
        #expect(secondGenerationTerminal.wasAgentRunning == true)
        #expect(secondGenerationTerminal.resumeBinding?.restoreStartupInput() == expectedRestoreInput)

        let secondRestore = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { secondRestore.teardownAllPanels() }
        secondRestore.restoreSessionSnapshot(secondGenerationSnapshot)
        let secondPanelID = try #require(secondRestore.focusedPanelId)
        let secondPanel = try #require(secondRestore.terminalPanel(for: secondPanelID))
        let secondRestoreInput = try #require(secondPanel.surface.debugInitialInputForTesting())
        #expect(secondRestoreInput == expectedRestoreInput)
        #expect(!secondRestoreInput.contains("grok -r"))
    }

    @Test("A replacement binding cannot inherit restored-command liveness")
    func replacementBindingCannotInheritRestoredCommandLiveness() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let restoredSessionID = "a22293b7-bcef-4707-8439-2f538c8517a4"
        let restoredBinding = codexBinding(sessionID: restoredSessionID)

        #expect(workspace.setSurfaceResumeBinding(restoredBinding, panelId: panelID))
        workspace.restoredAgentLifecycle.setSnapshot(
            SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: restoredSessionID,
                workingDirectory: "/tmp/repo",
                launchCommand: nil
            ),
            panelId: panelID
        )
        workspace.restoredAgentLifecycle.setResumeState(.autoResumeCommandRunning, panelId: panelID)

        let sameSessionRefresh = SurfaceResumeBindingSnapshot(
            name: "Codex",
            kind: "codex",
            command: "/opt/codex/bin/codex resume \(restoredSessionID)",
            cwd: "/tmp/refreshed-repo",
            checkpointId: restoredSessionID,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_777_777_779
        )
        #expect(workspace.setSurfaceResumeBinding(sameSessionRefresh, panelId: panelID))
        #expect(
            workspace.restoredAgentResumeStatesByPanelId[panelID]
                == .autoResumeCommandRunning
        )
        #expect(workspace.restoredAgentSnapshotsByPanelId[panelID]?.sessionId == restoredSessionID)

        let replacementSessionID = "13a40ce0-f096-4c56-885b-592af90407c4"
        #expect(workspace.setSurfaceResumeBinding(
            codexBinding(sessionID: replacementSessionID),
            panelId: panelID
        ))
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelID] == nil)
        #expect(workspace.restoredAgentSnapshotsByPanelId[panelID] == nil)
    }

    private func withFixture(
        _ body: (
            Workspace,
            UserDefaults,
            RestorableAgentSessionIndex
        ) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-binding-generation-\(UUID().uuidString)", isDirectory: true)
        let hookStateDirectory = root.appendingPathComponent("hook-state", isDirectory: true)
        let previousHookStateDirectory = getenv("CMUX_AGENT_HOOK_STATE_DIR").map { String(cString: $0) }
        setenv("CMUX_AGENT_HOOK_STATE_DIR", hookStateDirectory.path, 1)
        defer {
            if let previousHookStateDirectory {
                setenv("CMUX_AGENT_HOOK_STATE_DIR", previousHookStateDirectory, 1)
            } else {
                unsetenv("CMUX_AGENT_HOOK_STATE_DIR")
            }
            try? fileManager.removeItem(at: root)
        }

        let defaultsName = "cmux-binding-generation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { source.teardownAllPanels() }
        let panelID = try #require(source.focusedPanelId)
        try writeCodexHookRecord(
            sessionID: "codex-stale-cached-session",
            workspaceID: source.id,
            panelID: panelID,
            root: root,
            fileManager: fileManager
        )
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processArgumentsProvider: { _ in nil },
            processPresenceProvider: { _ in .absent }
        )
        try body(source, defaults, index)
    }

    private func expectNoResumeLaunch(
        snapshot: SessionWorkspaceSnapshot,
        defaults: UserDefaults
    ) throws {
        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { restored.teardownAllPanels() }
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelID = try #require(restored.focusedPanelId)
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))
        #expect(restoredPanel.surface.debugInitialCommand() == nil)
        #expect(!restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)
    }

    private func codexBindingIndex(
        sessionID: String,
        workspaceID: UUID,
        panelID: UUID
    ) -> SurfaceResumeBindingIndex {
        SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: workspaceID, panelId: panelID):
                codexBinding(sessionID: sessionID),
        ])
    }

    private func grokBindingIndex(
        sessionID: String,
        workspaceID: UUID,
        panelID: UUID
    ) -> SurfaceResumeBindingIndex {
        SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: workspaceID, panelId: panelID):
                grokBinding(sessionID: sessionID),
        ])
    }

    private func codexBinding(sessionID: String) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            name: "Codex",
            kind: "codex",
            command: "codex resume \(sessionID)",
            cwd: "/tmp/repo",
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_777_777_778
        )
    }

    private func grokBinding(
        sessionID: String,
        updatedAt: TimeInterval = 1_888_888_888
    ) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            name: "Grok",
            kind: "grok",
            command: "grok -r \(sessionID) --no-alt-screen",
            cwd: "/tmp/repo",
            checkpointId: sessionID,
            source: "agent-hook",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "grok",
                executablePath: "/usr/local/bin/grok",
                arguments: ["/usr/local/bin/grok", "--no-alt-screen"],
                workingDirectory: "/tmp/repo"
            ),
            autoResume: true,
            updatedAt: updatedAt
        )
    }

    private func writeCodexHookRecord(
        sessionID: String,
        workspaceID: UUID,
        panelID: UUID,
        root: URL,
        fileManager: FileManager
    ) throws {
        let storeURL = RestorableAgentKind.codex.hookStoreFileURL(homeDirectory: root.path)
        try fileManager.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": workspaceID.uuidString,
            "surfaceId": panelID.uuidString,
            "cwd": "/tmp/repo",
            "pid": 987_654_321,
            "isRestorable": true,
            "updatedAt": 1_777_777_777,
            "launchCommand": [
                "launcher": "codex",
                "executablePath": "/usr/local/bin/codex",
                "arguments": ["/usr/local/bin/codex"],
                "workingDirectory": "/tmp/repo",
                "capturedAt": 1_777_777_777,
                "source": "test",
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: ["version": 1, "sessions": [sessionID: record]],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: storeURL, options: .atomic)
    }
}
