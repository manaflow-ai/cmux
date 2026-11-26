import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CodexStaleTurnRestoreIntentTests {
    @Test("An exited Codex owner with an unfinished turn preserves restore intent")
    func staleTurnPreservesAutoresumeIntent() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-codex-stale-turn-intent-\(UUID().uuidString)", isDirectory: true)
        let hookDirectory = root.appendingPathComponent("hook-state", isDirectory: true)
        let environment = ["CMUX_AGENT_HOOK_STATE_DIR": hookDirectory.path]
        let defaultsName = "cmux-codex-stale-turn-intent-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer {
            try? fileManager.removeItem(at: root)
            defaults.removePersistentDomain(forName: defaultsName)
        }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let source = Workspace(
            agentSessionAutoResumeDefaults: defaults,
            restorableAgentIndexProvider: { .empty }
        )
        defer { source.teardownAllPanels() }
        let panelID = try #require(source.focusedPanelId)
        let sessionID = "codex-stale-turn-intent"
        try writeHookRecord(
            sessionID: sessionID,
            workspaceID: source.id,
            panelID: panelID,
            root: root,
            hookDirectory: hookDirectory,
            fileManager: fileManager
        )
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            environment: environment,
            processArgumentsProvider: { _ in nil },
            processPresenceProvider: { _ in .absent }
        )
        #expect(index.entry(workspaceId: source.id, panelId: panelID)?.processLiveness == .exited)

        let binding = SurfaceResumeBindingSnapshot(
            name: "Codex",
            kind: "codex",
            command: "codex resume \(sessionID)",
            cwd: root.path,
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_800_000_000
        )
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: panelID): binding
        ])
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: index,
            surfaceResumeBindingIndex: bindingIndex,
            currentAgentProcessIdentity: { _ in nil },
            agentProcessPresence: { _ in .absent }
        )
        let terminal = try #require(snapshot.panels.first?.terminal)
        #expect(terminal.agent?.sessionId == sessionID)
        #expect(terminal.wasAgentRunning == true)
    }

    private func writeHookRecord(
        sessionID: String,
        workspaceID: UUID,
        panelID: UUID,
        root: URL,
        hookDirectory: URL,
        fileManager: FileManager
    ) throws {
        let storeURL = RestorableAgentKind.codex.hookStoreFileURL(
            homeDirectory: root.path,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": hookDirectory.path]
        )
        try fileManager.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let transcriptURL = root.appendingPathComponent(".codex/sessions/rollout-\(sessionID).jsonl")
        try fileManager.createDirectory(at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let metadata: [String: Any] = [
            "type": "session_meta",
            "payload": ["id": sessionID, "cwd": root.path, "source": "cli", "originator": "codex-tui"]
        ]
        try JSONSerialization.data(withJSONObject: metadata).write(to: transcriptURL)
        let record: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": workspaceID.uuidString,
            "surfaceId": panelID.uuidString,
            "cwd": root.path,
            "pid": Int(Int32.max),
            "activePromptDepth": 1,
            "activePromptTurnIds": ["turn-stale"],
            "agentLifecycle": "idle",
            "runtimeStatus": "idle",
            "hookEventName": "Stop",
            "isRestorable": true,
            "updatedAt": 1_800_000_000,
            "launchCommand": [
                "launcher": "codex",
                "executablePath": "/usr/local/bin/codex",
                "arguments": ["/usr/local/bin/codex", "--yolo"],
                "workingDirectory": root.path,
                "capturedAt": 1_800_000_000,
                "source": "test"
            ]
        ]
        let store: [String: Any] = ["version": 1, "sessions": [sessionID: record]]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: storeURL, options: .atomic)
    }
}
