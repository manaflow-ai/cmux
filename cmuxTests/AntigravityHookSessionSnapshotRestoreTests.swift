import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Antigravity hook session restore")
struct AntigravityHookSessionSnapshotRestoreTests {
    @Test("Attaches an agy hook session to the persisted terminal snapshot")
    func attachesHookSessionToSessionSnapshot() throws {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-antigravity-hook-restore-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: homeDirectory) }

        let source = Workspace()
        defer { source.teardownAllPanels() }
        let panelID = try #require(source.focusedPanelId)
        let sessionID = "antigravity-conversation-5473"
        let stateDirectory = homeDirectory.appendingPathComponent(".cmuxterm", isDirectory: true)
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

        let record: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": source.id.uuidString,
            "surfaceId": panelID.uuidString,
            "cwd": "/tmp/antigravity-5473",
            "launchCommand": [
                "launcher": "antigravity",
                "executablePath": "agy",
                "arguments": ["agy", "-c", "--dangerously-skip-permissions"],
                "workingDirectory": "/tmp/antigravity-5473",
                "source": "agent-hook",
            ],
            "isRestorable": true,
            "updatedAt": 1_780_000_000.0,
        ]
        let store = try JSONSerialization.data(
            withJSONObject: ["version": 1, "sessions": [sessionID: record]],
            options: .sortedKeys
        )
        try store.write(
            to: stateDirectory.appendingPathComponent("antigravity-hook-sessions.json"),
            options: .atomic
        )

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: homeDirectory.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry.load(
                homeDirectory: homeDirectory.path,
                fileManager: fileManager
            ),
            detectedSnapshots: [:],
            processArgumentsProvider: { _ in nil }
        )
        let snapshot = try #require(
            source.sessionSnapshot(
                includeScrollback: false,
                restorableAgentIndex: index,
                currentAgentProcessIdentity: { _ in nil },
                agentProcessPresence: { _ in .absent }
            ).panels.first(where: { $0.id == panelID })?.terminal?.agent
        )

        #expect(snapshot.kind == .custom("antigravity"))
        #expect(snapshot.sessionId == sessionID)
        #expect(snapshot.registration?.id == "antigravity")
        // `-c` (continue) is a launch-only flag and must not replay; the
        // permission flag must survive so the restored session keeps the mode
        // the user launched with (https://github.com/manaflow-ai/cmux/issues/5473).
        #expect(
            snapshot.resumeCommand ==
                "cd -- '/tmp/antigravity-5473' 2>/dev/null || [ ! -d '/tmp/antigravity-5473' ] && 'agy' '--conversation' 'antigravity-conversation-5473' '--dangerously-skip-permissions'"
        )
    }
}
