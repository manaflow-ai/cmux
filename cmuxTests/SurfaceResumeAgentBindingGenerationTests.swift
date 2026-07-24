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
            #expect(restoredPanel.surface.debugInitialCommand() != nil)
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
                SurfaceResumeBindingSnapshot(
                    name: "Codex",
                    kind: "codex",
                    command: "codex resume \(sessionID)",
                    cwd: "/tmp/repo",
                    checkpointId: sessionID,
                    source: "agent-hook",
                    autoResume: true,
                    updatedAt: 1_777_777_778
                ),
        ])
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
