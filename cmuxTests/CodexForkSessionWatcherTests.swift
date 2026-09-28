import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct CodexForkSessionWatcherTests {
    @Test
    func rolloutWithParentIdentityWinsBeforeFirstPrompt() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-codex-fork-watch-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions/2026/09/27", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let parentID = "019f4f0d-38ed-7ec3-948b-49a9f58984f6"
        let childID = "019f4f0e-38ed-7ec3-948b-49a9f58984f6"
        let childPath = sessions.appendingPathComponent("rollout-2026-09-27T20-01-02-\(childID).jsonl")
        let metadata: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "id": childID,
                "forked_from_id": parentID,
                "timestamp": "1970-01-01T00:01:42.000Z",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata)
        try data.write(to: childPath, options: .atomic)

        let match = CodexForkSessionWatcher.findForkedSession(
            parentSessionID: parentID,
            sessionsRoot: root.appendingPathComponent("sessions", isDirectory: true),
            launchedAt: Date(timeIntervalSince1970: 100),
            fileManager: fileManager
        )
        #expect(match?.sessionID == childID)
        #expect(match?.transcriptPath == childPath.path)
    }

    @Test
    func explicitForkLaunchIsForegroundDespiteInheritedParentToken() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-fork-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledgerPath = root.appendingPathComponent("ledger.json").path
        let ledger = CodexTurnLedger(environment: [
            CodexHookInvocation.ledgerPathEnvironmentKey: ledgerPath,
        ])

        let parent = CodexHookInvocation(environment: [
            CodexHookInvocation.tokenEnvironmentKey: "parent-token",
            CodexHookInvocation.ownerPIDEnvironmentKey: "101",
        ])
        _ = try ledger.sessionStart(
            sessionID: "parent-session",
            workspaceID: "workspace",
            surfaceID: "fork-surface",
            invocation: parent
        )

        let fork = CodexHookInvocation(environment: [
            CodexHookInvocation.tokenEnvironmentKey: "child-token",
            CodexHookInvocation.parentTokenEnvironmentKey: "parent-token",
            CodexHookInvocation.ownerPIDEnvironmentKey: "102",
            CodexHookInvocation.forkSessionEnvironmentKey: "1",
        ])
        let decision = try ledger.sessionStart(
            sessionID: "child-session",
            workspaceID: "workspace",
            surfaceID: "fork-surface",
            invocation: fork
        )
        #expect(decision.ownership == .foreground)
    }
}
