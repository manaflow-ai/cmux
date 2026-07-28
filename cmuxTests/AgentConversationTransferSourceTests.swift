import Foundation
import SQLite3
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct AgentConversationTransferSourceTests {
    @Test(arguments: [RestorableAgentKind.rovodev, .antigravity])
    func localTranscriptSourceDoesNotRequireNativeForkCapability(
        kind: RestorableAgentKind
    ) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("history.jsonl")
        try Data(#"{"sessionId":"transfer-session","display":"continue"}"#.utf8)
            .write(to: transcript)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: "transfer-session",
            transcriptPath: transcript.path
        )
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: panelId)

        let transferSelection = workspace.agentConversationForkSelection(
            forPanelId: panelId,
            request: .init(targetHarness: .claude, destination: .right)
        )
        let nativeSelection = workspace.agentConversationForkSelection(
            forPanelId: panelId,
            request: .init(targetHarness: .current, destination: .right)
        )

        #expect(snapshot.forkCommand == nil)
        #expect(transferSelection?.snapshot.sessionId == snapshot.sessionId)
        #expect(transferSelection?.requiresNativeForkCapability == false)
        #expect(nativeSelection == nil)
        #expect(
            workspace.forkAgentConversationContextMenuAvailability(forPanelId: panelId)
                == .unsupported
        )
    }

    @Test
    func remoteTranscriptSourceDoesNotOfferCrossHarnessTransfer() throws {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .rovodev,
            sessionId: "remote-rovo",
            transcriptPath: "/tmp/remote-rovo.json"
        )
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: panelId)
        workspace.trackRemoteTerminalSurface(panelId)

        #expect(workspace.agentConversationTransferSnapshot(forPanelId: panelId) == nil)
        #expect(workspace.agentConversationForkSelection(
            forPanelId: panelId,
            request: .init(targetHarness: .claude, destination: .right)
        ) == nil)
    }

    @Test
    func commandPaletteHarnessChoicesLeaveCurrentHarnessToNativeCommands() throws {
        let harnessArgument = try #require(
            AgentConversationForkRequest.commandPaletteChoiceArguments.first {
                $0.name == AgentConversationForkRequest.harnessArgumentName
            }
        )

        #expect(!harnessArgument.choices.contains { $0.value == "current" })
        #expect(Set(harnessArgument.choices.map(\.value)) == ["claude", "codex", "opencode"])
    }

    @Test
    func hermesTransferUsesCapturedHermesHome() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("state.db")
        try makeHermesStateDatabase(at: databaseURL)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .hermesAgent,
            sessionId: "captured-home-session",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "hermes",
                executablePath: "/opt/homebrew/bin/hermes",
                arguments: ["/opt/homebrew/bin/hermes", "--resume", "captured-home-session"],
                workingDirectory: nil,
                environment: ["HERMES_HOME": directory.path],
                capturedAt: 123,
                source: "process"
            )
        )
        let source = AgentConversationSource(snapshot: snapshot)

        let command = try #require(try await AgentConversationForkRequest(
            targetHarness: .claude,
            destination: .right
        ).startupCommandOverride(sourceSnapshot: snapshot))

        #expect(source.hermesStateDatabaseURL == databaseURL)
        #expect(command.contains("custom Hermes home request"))
        #expect(command.contains("custom Hermes home response"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-conversation-transfer-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeHermesStateDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw FixtureError.sqlite
        }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL,
          role TEXT NOT NULL,
          content TEXT,
          tool_calls TEXT,
          tool_name TEXT,
          timestamp REAL NOT NULL
        );
        INSERT INTO messages (session_id, role, content, timestamp)
        VALUES
          ('captured-home-session', 'user', 'custom Hermes home request', 1),
          ('captured-home-session', 'assistant', 'custom Hermes home response', 2);
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw FixtureError.sqlite
        }
    }
}

private enum FixtureError: Error {
    case sqlite
}
