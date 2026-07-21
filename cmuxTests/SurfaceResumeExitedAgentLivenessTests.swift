import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SurfaceResumeExitedAgentLivenessTests {
    @Test("Exited hook process does not auto-resume from an unknown shell state")
    @MainActor
    func exitedHookProcessDoesNotAutoResumeFromUnknownShellState() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-exited-agent-resume-\(UUID().uuidString)", isDirectory: true)
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

        let defaultsName = "cmux-exited-agent-resume-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { source.teardownAllPanels() }
        let panelID = try #require(source.focusedPanelId)
        let sessionID = "codex-exited-agent-session"
        try writeExitedCodexHookRecord(
            sessionID: sessionID,
            workspaceID: source.id,
            panelID: panelID,
            root: root,
            fileManager: fileManager
        )

        let agentIndex = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processArgumentsProvider: { _ in nil }
        )
        #expect(agentIndex.snapshot(workspaceId: source.id, panelId: panelID)?.sessionId == sessionID)
        #expect(!agentIndex.hasLiveProcess(workspaceId: source.id, panelId: panelID))

        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: panelID):
                SurfaceResumeBindingSnapshot(
                    name: "Codex",
                    kind: "codex",
                    command: "codex resume \(sessionID)",
                    cwd: "/tmp/repo",
                    checkpointId: sessionID,
                    source: "agent-hook",
                    autoResume: true,
                    updatedAt: 1_777_777_777
                ),
        ])
        source.updatePanelShellActivityState(panelId: panelID, state: .unknown)
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: agentIndex,
            surfaceResumeBindingIndex: bindingIndex
        )

        #expect(snapshot.panels.first?.terminal?.wasAgentRunning == false)

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { restored.teardownAllPanels() }
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelID = try #require(restored.focusedPanelId)
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))

        #expect(restoredPanel.surface.debugInitialCommand() == nil)
        #expect(!restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)
        #expect(
            restored.sessionSnapshot(includeScrollback: false)
                .panels.first?.terminal?.agent?.sessionId == sessionID
        )
    }

    private func writeExitedCodexHookRecord(
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
            withJSONObject: [
                "version": 1,
                "sessions": [sessionID: record],
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: storeURL, options: .atomic)
    }
}
