import CmuxConversationTransfer
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
struct AgentConversationCrossHarnessForkTests {
    @Test
    func explicitSameHarnessRetainsNativeForkWithoutReadingTranscript() async throws {
        let snapshot = SessionRestorableAgentSnapshot(kind: .codex, sessionId: "codex-session")
        let service = AgentConversationExportService(
            readerRegistry: AgentConversationReaderRegistry(adapters: [FailingSourceAdapter()])
        )

        let override = try await AgentConversationForkRequest(
            targetHarness: .codex,
            destination: .right
        ).startupCommandOverride(sourceSnapshot: snapshot, exportService: service)

        #expect(override == nil)
        #expect(snapshot.forkStartupInput() != nil)
    }

    @Test
    func forkCacheIdentityChangesWhenTranscriptPathChanges() {
        let first = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-session",
            transcriptPath: "/tmp/first-rollout.jsonl"
        )
        let second = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-session",
            transcriptPath: "/tmp/second-rollout.jsonl"
        )

        #expect(
            ContentView.commandPaletteForkSnapshotFingerprint(first)
                != ContentView.commandPaletteForkSnapshotFingerprint(second)
        )
    }

    @Test
    func codexTranscriptSeedsClaudeCode() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let transcript = fixture.appendingPathComponent("rollout.jsonl")
        try [
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Find the parser bug"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"The parser drops the final field"}]}}"#,
        ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-session",
            transcriptPath: transcript.path
        )

        let command = try #require(try await AgentConversationForkRequest(
            targetHarness: .claude,
            destination: .newTab
        ).startupCommandOverride(sourceSnapshot: snapshot))

        #expect(command.hasPrefix("claude "))
        #expect(command.contains("Find the parser bug"))
        #expect(command.contains("The parser drops the final field"))
    }

    @Test
    func claudeTranscriptSeedsCodex() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let transcript = fixture.appendingPathComponent("claude.jsonl")
        try [
            #"{"type":"user","message":{"role":"user","content":"Repair the renderer"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":"The wakeup path is stale"}}"#,
        ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session",
            transcriptPath: transcript.path
        )

        let command = try #require(try await AgentConversationForkRequest(
            targetHarness: .codex,
            destination: .newWorkspace
        ).startupCommandOverride(sourceSnapshot: snapshot))

        #expect(command.hasPrefix("codex "))
        #expect(command.contains("Repair the renderer"))
        #expect(command.contains("The wakeup path is stale"))
    }

    @Test
    func openCodeDatabaseTranscriptSeedsClaudeCode() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let database = fixture.appendingPathComponent("opencode.db")
        try createOpenCodeDatabase(at: database)
        let service = AgentConversationExportService(
            readerRegistry: AgentConversationReaderRegistry(adapters: [
                OpenCodeAgentConversationSourceAdapter(databasePath: database.path),
            ])
        )

        let command = try #require(try await AgentConversationForkRequest(
            targetHarness: .claude,
            destination: .bottom
        ).startupCommandOverride(
            sourceSnapshot: SessionRestorableAgentSnapshot(
                kind: .opencode,
                sessionId: "open-session"
            ),
            exportService: service
        ))

        #expect(command.hasPrefix("claude "))
        #expect(command.contains("Inspect OpenCode storage"))
        #expect(command.contains("Storage is SQLite-backed"))
    }

    @Test
    func openCodeTransferRetentionKeepsOpeningRequestAndNewestSuffix() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let database = fixture.appendingPathComponent("opencode.db")
        try createOpenCodeRetentionDatabase(at: database)

        let turns = try await SessionTranscriptLoader.load(source: .init(
            agent: .opencode,
            sessionId: "retention-session",
            fileURL: nil,
            openCodeDatabasePath: database.path,
            retention: .openingUserAndLatest(3)
        ))

        #expect(turns.map(\.text) == [
            "OpenCode turn 0",
            "OpenCode turn 11",
            "OpenCode turn 12",
        ])
    }

    @Test
    func openCodeTargetUsesPromptFlag() throws {
        let command = try #require(
            AgentConversationForkRequest.TargetHarness.opencode.startupCommand(
                handoffMessage: "User:\nContinue this work"
            )
        )

        #expect(command.hasPrefix("opencode --prompt "))
        #expect(command.contains("Continue this work"))
    }

    @Test
    func genericForkCommandRanksAboveNativeShortcutAndDismissesBeforeRunning() {
        let genericBoost = ContentView.commandPaletteForkPriorityBoost(
            commandId: "palette.forkAgentConversation",
            query: "fork"
        )
        let nativeBoost = ContentView.commandPaletteForkPriorityBoost(
            commandId: "palette.forkAgentConversationRight",
            query: "fork"
        )

        #expect(genericBoost > nativeBoost)
        #expect(nativeBoost > 0)
        #expect(ContentView.commandPaletteShouldDismissBeforeRun(
            forCommandId: "palette.forkAgentConversation"
        ))
    }

    @Test
    func crossHarnessForkCreatesSplitWithTransferredPrompt() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let snapshot = try makeCodexSnapshot(in: fixture)
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: sourcePanelId)

        let didFork = await workspace.forkAgentConversation(
            fromPanelId: sourcePanelId,
            snapshot: snapshot,
            request: .init(targetHarness: .claude, destination: .right)
        )

        #expect(didFork)
        #expect(workspace.bonsplitController.allPaneIds.count == 2)
        let forkPanelId = try #require(workspace.focusedPanelId)
        let forkPanel = try #require(workspace.terminalPanel(for: forkPanelId))
        #expect(forkPanelId != sourcePanelId)
        #expect(forkPanel.surface.initialInput?.contains("claude ") == true)
        #expect(forkPanel.surface.initialInput?.contains("Preserve destination behavior") == true)
    }

    @Test
    func crossHarnessForkCreatesSiblingTabWithTransferredPrompt() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let snapshot = try makeCodexSnapshot(in: fixture)
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let sourcePaneId = try #require(workspace.paneId(forPanelId: sourcePanelId))
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: sourcePanelId)

        let didFork = await workspace.forkAgentConversation(
            fromPanelId: sourcePanelId,
            snapshot: snapshot,
            request: .init(targetHarness: .claude, destination: .newTab)
        )

        #expect(didFork)
        #expect(workspace.bonsplitController.allPaneIds.count == 1)
        #expect(workspace.bonsplitController.tabs(inPane: sourcePaneId).count == 2)
        let forkPanelId = try #require(workspace.focusedPanelId)
        let forkPanel = try #require(workspace.terminalPanel(for: forkPanelId))
        #expect(forkPanelId != sourcePanelId)
        #expect(forkPanel.surface.initialInput?.contains("Preserve destination behavior") == true)
    }

    @Test
    func crossHarnessForkCreatesWorkspaceWithTransferredPrompt() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let snapshot = try makeCodexSnapshot(in: fixture)
        let tabManager = TabManager()
        let sourceWorkspace = try #require(tabManager.tabs.first)
        let sourcePanelId = try #require(sourceWorkspace.focusedPanelId)
        sourceWorkspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: sourcePanelId)

        let didFork = await sourceWorkspace.forkAgentConversation(
            fromPanelId: sourcePanelId,
            snapshot: snapshot,
            request: .init(targetHarness: .claude, destination: .newWorkspace)
        )

        #expect(didFork)
        #expect(tabManager.tabs.count == 2)
        let forkWorkspace = try #require(tabManager.tabs.first { $0.id != sourceWorkspace.id })
        let forkPanelId = try #require(forkWorkspace.focusedPanelId)
        let forkPanel = try #require(forkWorkspace.terminalPanel(for: forkPanelId))
        #expect(forkPanel.surface.initialInput?.contains("Preserve destination behavior") == true)
    }

    @Test
    func crossHarnessForkCancelsWhenConversationChangesDuringExport() async throws {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "original-session",
            transcriptPath: "/unused/original-transcript.jsonl"
        )
        let replacement = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "replacement-session",
            transcriptPath: "/unused/replacement-transcript.jsonl"
        )
        let transcriptGate = SuspendingTranscriptGate()
        let exportService = AgentConversationExportService(
            readerRegistry: AgentConversationReaderRegistry(adapters: [
                SuspendingSourceAdapter(gate: transcriptGate),
            ])
        )
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: sourcePanelId)

        let forkTask = Task { @MainActor in
            await workspace.forkAgentConversation(
                fromPanelId: sourcePanelId,
                snapshot: snapshot,
                request: .init(targetHarness: .claude, destination: .right),
                exportService: exportService
            )
        }
        await transcriptGate.waitUntilReadStarts()
        workspace.setRestoredAgentSnapshotForTesting(replacement, panelId: sourcePanelId)
        await transcriptGate.finishRead()

        #expect(await forkTask.value == false)
        #expect(workspace.bonsplitController.allPaneIds.count == 1)
        #expect(workspace.focusedPanelId == sourcePanelId)
    }

    @Test
    func cancelledCrossHarnessForkRemovesPrivateLauncher() async throws {
        let sessionID = "cancel-\(UUID().uuidString)"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            transcriptPath: "/unused/cancelled-transcript.jsonl"
        )
        let transcriptGate = SuspendingTranscriptGate()
        let exportService = AgentConversationExportService(
            readerRegistry: AgentConversationReaderRegistry(adapters: [
                SuspendingSourceAdapter(gate: transcriptGate),
            ])
        )
        let workspace = Workspace()
        let sourcePanelID = try #require(workspace.focusedPanelId)
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: sourcePanelID)

        let launcherDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-resume", isDirectory: true)
        let launcherNamePrefix = "codex-\(sessionID.prefix(12))-"
        let launcherURLsBefore = launcherScripts(
            in: launcherDirectory,
            namePrefix: launcherNamePrefix
        )
        defer {
            let launcherURLsAfter = launcherScripts(
                in: launcherDirectory,
                namePrefix: launcherNamePrefix
            )
            for url in launcherURLsAfter.subtracting(launcherURLsBefore) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let forkTask = Task { @MainActor in
            await workspace.forkAgentConversation(
                fromPanelId: sourcePanelID,
                snapshot: snapshot,
                request: .init(targetHarness: .claude, destination: .right),
                exportService: exportService
            )
        }
        await transcriptGate.waitUntilReadStarts()
        forkTask.cancel()
        await transcriptGate.finishRead()

        #expect(await forkTask.value == false)
        #expect(workspace.bonsplitController.allPaneIds.count == 1)
        #expect(
            launcherScripts(in: launcherDirectory, namePrefix: launcherNamePrefix)
                == launcherURLsBefore
        )
    }

    @Test
    func crossHarnessForkRejectsRemoteSourceBeforeReadingLocalTranscript() async throws {
        let snapshot = SessionRestorableAgentSnapshot(kind: .codex, sessionId: "remote-session")
        let sourceAdapter = ReadRecordingSourceAdapter()
        let exportService = AgentConversationExportService(
            readerRegistry: AgentConversationReaderRegistry(adapters: [sourceAdapter])
        )
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: sourcePanelId)
        workspace.trackRemoteTerminalSurface(sourcePanelId)

        let didFork = await workspace.forkAgentConversation(
            fromPanelId: sourcePanelId,
            snapshot: snapshot,
            request: .init(targetHarness: .claude, destination: .right),
            exportService: exportService
        )

        #expect(!didFork)
        #expect(await sourceAdapter.readCount == 0)
        #expect(workspace.bonsplitController.allPaneIds.count == 1)
    }

    @Test
    func transferRetentionKeepsOpeningRequestAndLatestTurns() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let transcript = fixture.appendingPathComponent("claude.jsonl")
        try (0..<8).map { index in
            let type = index.isMultiple(of: 2) ? "user" : "assistant"
            return #"{"type":"\#(type)","message":{"role":"\#(type)","content":"turn-\#(index)"}}"#
        }.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let turns = try await SessionTranscriptLoader.load(source: .init(
            agent: .claude,
            sessionId: "session",
            fileURL: transcript,
            retention: .openingUserAndLatest(3)
        ))

        #expect(turns.first?.text.contains("turn-0") == true)
        #expect(turns.last?.text.contains("turn-7") == true)
        #expect(!turns.contains(where: { $0.text.contains("turn-2") }))
    }

    @Test
    func rovoDevTransferRetentionKeepsOpeningRequestAndNewestSuffix() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let transcript = fixture.appendingPathComponent("rovodev.json")
        let messages = (0..<8).map { index in
            let role = index.isMultiple(of: 2) ? "user" : "assistant"
            return ["role": role, "content": "rovo-turn-\(index)"]
        }
        let data = try JSONSerialization.data(withJSONObject: ["message_history": messages])
        try data.write(to: transcript)

        let turns = try await SessionTranscriptLoader.load(source: .init(
            agent: .rovodev,
            sessionId: "rovo-session",
            fileURL: transcript,
            retention: .openingUserAndLatest(3)
        ))

        #expect(turns.map(\.text) == ["rovo-turn-0", "rovo-turn-6", "rovo-turn-7"])
    }

    @Test
    func antigravityTransferRetentionScansPastTailForOpeningRequest() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let transcript = fixture.appendingPathComponent("antigravity.jsonl")
        let sessionID = "antigravity-session"
        let history = (0..<12).map { index in
            #"{"conversationId":"\#(sessionID)","display":"antigravity-turn-\#(index)"}"#
        }.joined(separator: "\n")
        try history.write(to: transcript, atomically: true, encoding: .utf8)

        let turns = try await SessionTranscriptLoader.load(source: .init(
            agent: .registered(RegisteredSessionAgent(id: "antigravity")),
            sessionId: sessionID,
            fileURL: transcript,
            retention: .openingUserAndLatest(3)
        ))

        let transferredText = turns.map(\.text).joined(separator: "\n")
        #expect(transferredText.contains("antigravity-turn-0"))
        #expect(transferredText.contains("antigravity-turn-10"))
        #expect(transferredText.contains("antigravity-turn-11"))
        #expect(!transferredText.contains("antigravity-turn-9"))
    }

    @Test
    func failedDestinationRemovesPrivateCrossHarnessLauncher() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sessionID = "cleanup-\(UUID().uuidString)"
        let snapshot = try makeCodexSnapshot(in: fixture, sessionID: sessionID)
        let workspace = Workspace()
        let sourcePanelID = try #require(workspace.focusedPanelId)
        let sourceSurfaceID = try #require(workspace.surfaceIdFromPanelId(sourcePanelID))
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: sourcePanelID)

        let launcherDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-resume", isDirectory: true)
        let safeSessionPrefix = String(sessionID.prefix(12))
        let launcherNamePrefix = "codex-\(safeSessionPrefix)-"
        let launcherURLsBefore = launcherScripts(
            in: launcherDirectory,
            namePrefix: launcherNamePrefix
        )
        defer {
            let launcherURLsAfter = launcherScripts(
                in: launcherDirectory,
                namePrefix: launcherNamePrefix
            )
            for url in launcherURLsAfter.subtracting(launcherURLsBefore) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        workspace.removeSurfaceMapping(forSurfaceId: sourceSurfaceID)
        let didFork = await workspace.forkAgentConversation(
            fromPanelId: sourcePanelID,
            snapshot: snapshot,
            request: .init(targetHarness: .claude, destination: .newTab)
        )

        let launcherURLsAfter = launcherScripts(
            in: launcherDirectory,
            namePrefix: launcherNamePrefix
        )
        #expect(!didFork)
        #expect(launcherURLsAfter == launcherURLsBefore)
    }

    @Test
    func largeCrossHarnessCommandUsesPrivateSelfDeletingLauncher() throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let snapshot = SessionRestorableAgentSnapshot(kind: .codex, sessionId: "large-session")
        let command = "claude " + String(repeating: "context ", count: 500)

        let input = try #require(snapshot.customStartupInput(
            command: command,
            temporaryDirectory: fixture
        ))
        let prefix = "/bin/zsh '"
        #expect(input.hasPrefix(prefix))
        let path = String(input.dropFirst(prefix.count).dropLast(2))
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        ).intValue & 0o777

        #expect(permissions == 0o600)
        #expect(contents.contains("rm -f -- \"$0\""))
        #expect(contents.contains(command))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cross-harness-fork-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeCodexSnapshot(
        in directory: URL,
        sessionID: String = "codex-destination-session"
    ) throws -> SessionRestorableAgentSnapshot {
        let transcript = directory.appendingPathComponent("rollout.jsonl")
        try [
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Preserve destination behavior"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Use the shared executor"}]}}"#,
        ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
        return SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: directory.path,
            transcriptPath: transcript.path
        )
    }

    private func createOpenCodeDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw OpenCodeFixtureError.sqlite
        }
        defer { sqlite3_close(database) }
        let sql = #"""
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
        CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, time_created INTEGER, data TEXT);
        INSERT INTO message VALUES ('m1', 'open-session', 1, '{"role":"user"}');
        INSERT INTO message VALUES ('m2', 'open-session', 2, '{"role":"assistant"}');
        INSERT INTO part VALUES ('p1', 'm1', 1, '{"type":"text","text":"Inspect OpenCode storage"}');
        INSERT INTO part VALUES ('p2', 'm2', 2, '{"type":"text","text":"Storage is SQLite-backed"}');
        """#
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw OpenCodeFixtureError.sqlite
        }
    }

    private func createOpenCodeRetentionDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw OpenCodeFixtureError.sqlite
        }
        defer { sqlite3_close(database) }
        let messages = (0..<13).map { index in
            let role = index.isMultiple(of: 2) ? "user" : "assistant"
            return "INSERT INTO message VALUES ('m\(index)', 'retention-session', \(index), '{\"role\":\"\(role)\"}');"
        }
        let parts = (0..<13).map { index in
            "INSERT INTO part VALUES ('p\(index)', 'm\(index)', \(index), '{\"type\":\"text\",\"text\":\"OpenCode turn \(index)\"}');"
        }
        let sql = ([
            "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);",
            "CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, time_created INTEGER, data TEXT);",
        ] + messages + parts).joined(separator: "\n")
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw OpenCodeFixtureError.sqlite
        }
    }

    private func launcherScripts(in directory: URL, namePrefix: String) -> Set<URL> {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return Set(urls.filter { $0.lastPathComponent.hasPrefix(namePrefix) })
    }
}

private struct FailingSourceAdapter: AgentConversationSourceAdapter {
    func supports(_ source: AgentConversationSource) -> Bool { true }

    func read(_ source: AgentConversationSource) async throws -> [SessionTranscriptTurn]? {
        throw OpenCodeFixtureError.unexpectedRead
    }
}

private struct SuspendingSourceAdapter: AgentConversationSourceAdapter {
    let gate: SuspendingTranscriptGate

    func supports(_ source: AgentConversationSource) -> Bool { true }

    func read(_ source: AgentConversationSource) async throws -> [SessionTranscriptTurn]? {
        await gate.read()
    }
}

private actor SuspendingTranscriptGate {
    private var readStarted = false
    private var readStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var readContinuation: CheckedContinuation<[SessionTranscriptTurn], Never>?

    func read() async -> [SessionTranscriptTurn] {
        readStarted = true
        readStartWaiters.forEach { $0.resume() }
        readStartWaiters.removeAll()
        return await withCheckedContinuation { continuation in
            readContinuation = continuation
        }
    }

    func waitUntilReadStarts() async {
        guard !readStarted else { return }
        await withCheckedContinuation { continuation in
            readStartWaiters.append(continuation)
        }
    }

    func finishRead() {
        readContinuation?.resume(returning: [
            SessionTranscriptTurn(id: 0, role: .user, text: "Continue the original work"),
        ])
        readContinuation = nil
    }
}

private actor ReadRecordingSourceAdapter: AgentConversationSourceAdapter {
    private(set) var readCount = 0

    nonisolated func supports(_ source: AgentConversationSource) -> Bool { true }

    func read(_ source: AgentConversationSource) async throws -> [SessionTranscriptTurn]? {
        readCount += 1
        return []
    }
}

private enum OpenCodeFixtureError: Error {
    case sqlite
    case unexpectedRead
}
