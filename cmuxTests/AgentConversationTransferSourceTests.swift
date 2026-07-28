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

    @Test
    func openCodeTransferUsesCapturedXDGDataHome() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dataHome = directory.appendingPathComponent("custom-data", isDirectory: true)
        let databaseDirectory = dataHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(
            at: databaseDirectory,
            withIntermediateDirectories: true
        )
        let databaseURL = databaseDirectory.appendingPathComponent("opencode.db")
        try makeOpenCodeDatabase(at: databaseURL)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "captured-opencode-session",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode"],
                workingDirectory: nil,
                environment: [
                    "HOME": directory.appendingPathComponent("ignored-home").path,
                    "XDG_DATA_HOME": dataHome.path,
                ],
                capturedAt: 123,
                source: "process"
            )
        )
        let source = AgentConversationSource(snapshot: snapshot)

        let command = try #require(try await AgentConversationForkRequest(
            targetHarness: .claude,
            destination: .right
        ).startupCommandOverride(sourceSnapshot: snapshot))

        #expect(source.openCodeDatabasePath == databaseURL.path)
        #expect(command.contains("custom OpenCode home request"))
        #expect(command.contains("custom OpenCode home response"))
    }

    @Test
    func transferRetentionBoundsManyLargeConsecutiveTurnsBeforeCoalescing() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("large-claude.jsonl")
        var records = [
            #"{"type":"user","message":{"role":"user","content":"opening request"}}"#
        ]
        records.append(contentsOf: (0..<220).map { index in
            let suffix = index == 219 ? "-LATEST-MARKER" : ""
            let text = "assistant-\(index)-" + String(repeating: "x", count: 4_096) + suffix
            return #"{"type":"assistant","message":{"role":"assistant","content":"\#(text)"}}"#
        })
        try records.joined(separator: "\n").write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )
        let byteLimit = 32 * 1_024

        let turns = try await SessionTranscriptLoader.load(source: .init(
            agent: .claude,
            sessionId: "large-session",
            fileURL: transcript,
            retention: .transferOpeningUserAndLatest(
                turnLimit: 1_000,
                textByteLimit: byteLimit
            )
        ))

        #expect(turns.first?.text.contains("opening request") == true)
        #expect(turns.last?.text.contains("LATEST-MARKER") == true)
        #expect(turns.count == 2)
        #expect(turns.reduce(0) { $0 + $1.text.utf8.count } <= byteLimit)
    }

    @Test
    func smallCrossHarnessSeedUsesPrivateSelfDeletingLauncher() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = SessionRestorableAgentSnapshot(kind: .codex, sessionId: "small-session")
        let command = "claude 'small private transfer prompt'"

        let input = try #require(snapshot.customStartupInput(
            command: command,
            temporaryDirectory: directory
        ))
        let prefix = "/bin/zsh '"
        let scriptPath = String(input.dropFirst(prefix.count).dropLast(2))
        let contents = try String(contentsOfFile: scriptPath, encoding: .utf8)

        #expect(input.hasPrefix(prefix))
        #expect(!input.contains("small private transfer prompt"))
        #expect(contents.contains("rm -f -- \"$0\""))
        #expect(contents.contains(command))
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

    private func makeOpenCodeDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw FixtureError.sqlite
        }
        defer { sqlite3_close(database) }
        let sql = #"""
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
        CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, time_created INTEGER, data TEXT);
        INSERT INTO message VALUES ('m1', 'captured-opencode-session', 1, '{"role":"user"}');
        INSERT INTO message VALUES ('m2', 'captured-opencode-session', 2, '{"role":"assistant"}');
        INSERT INTO part VALUES ('p1', 'm1', 1, '{"type":"text","text":"custom OpenCode home request"}');
        INSERT INTO part VALUES ('p2', 'm2', 2, '{"type":"text","text":"custom OpenCode home response"}');
        """#
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw FixtureError.sqlite
        }
    }
}

private enum FixtureError: Error {
    case sqlite
}
