import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Code Puppy hook-store restore")
struct CodePuppySessionRestoreTests {
    @Test("plain launch restores verified autosave identity from the existing hook store")
    func plainLaunch() throws {
        let fixture = try makeIndex(sessionID: "auto_session_20260501_120000", persisted: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try #require(fixture.index.snapshot(workspaceId: fixture.workspace, panelId: fixture.panel))
        #expect(snapshot.sessionId == "auto_session_20260501_120000")
        #expect(snapshot.preparedResumeArguments(
            launchCommand: snapshot.launchCommand, workingDirectory: snapshot.workingDirectory,
            observedPermissionMode: nil
        ) == ["code-puppy", "--resume", "auto_session_20260501_120000"])
    }

    @Test("placeholder and per-run UUID never become restorable checkpoints", arguments: [
        "codepuppy-session", "11111111-2222-3333-4444-555555555555",
    ])
    func invalidHookIdentity(sessionID: String) throws {
        let fixture = try makeIndex(sessionID: sessionID, persisted: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(fixture.index.snapshot(workspaceId: fixture.workspace, panelId: fixture.panel)?.sessionId == nil)
    }

    private func makeIndex(sessionID: String, persisted: Bool) throws -> (
        root: URL, workspace: UUID, panel: UUID, index: RestorableAgentSessionIndex
    ) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("puppy-restore-\(UUID())")
        let store = root.appendingPathComponent(".cmuxterm")
        let autosaves = root.appendingPathComponent(".code_puppy/autosaves")
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        try fm.createDirectory(at: autosaves, withIntermediateDirectories: true)
        if persisted {
            try Data().write(to: autosaves.appendingPathComponent("\(sessionID).pkl"))
        }
        let workspace = UUID()
        let panel = UUID()
        let record: [String: Any] = [
            "sessionId": sessionID, "workspaceId": workspace.uuidString,
            "surfaceId": panel.uuidString, "cwd": root.path, "updatedAt": 10,
            "launchCommand": ["launcher": "code-puppy", "arguments": ["code-puppy"], "source": "process"],
        ]
        try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": [sessionID: record]])
            .write(to: store.appendingPathComponent("code-puppy-hook-sessions.json"))
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: root.path, fileManager: fm,
            registry: CmuxVaultAgentRegistry(registrations: [.builtInCodePuppy]),
            detectedSnapshots: [:], environment: [:], processArgumentsProvider: { _ in nil }
        )
        return (root, workspace, panel, index)
    }
}
