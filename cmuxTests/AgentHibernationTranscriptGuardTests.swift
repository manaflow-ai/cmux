import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct AgentHibernationTranscriptGuardTests {
    @Test
    func transcriptHasConversationTurnsClassifiesTranscriptLines() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let stub = directory.appendingPathComponent("stub.jsonl")
        try metadataStub.write(to: stub, atomically: true, encoding: .utf8)
        #expect(AgentHibernationTranscriptGuard.transcriptHasConversationTurns(atPath: stub.path) == false)

        let populated = directory.appendingPathComponent("populated.jsonl")
        try [
            #"{"type":"last-prompt","prompt":"hello"}"#,
            #"{"type":"user","message":{"role":"user","content":"hello"}}"#,
            "{not-json",
            #"{"type":"assistant","message":{"role":"assistant","content":"hi"}}"#,
            #"{"type":"mode","mode":"default"}"#,
        ].joined(separator: "\n").write(to: populated, atomically: true, encoding: .utf8)
        #expect(AgentHibernationTranscriptGuard.transcriptHasConversationTurns(atPath: populated.path))

        let malformedOnly = directory.appendingPathComponent("malformed.jsonl")
        try [
            "{not-json",
            #"{"type":"ai-title","aiTitle":"user stories"}"#,
            #"{"note":"assistant"}"#,
        ].joined(separator: "\n").write(to: malformedOnly, atomically: true, encoding: .utf8)
        #expect(AgentHibernationTranscriptGuard.transcriptHasConversationTurns(atPath: malformedOnly.path) == false)

        let empty = directory.appendingPathComponent("empty.jsonl")
        _ = FileManager.default.createFile(atPath: empty.path, contents: Data())
        #expect(AgentHibernationTranscriptGuard.transcriptHasConversationTurns(atPath: empty.path) == false)
        #expect(
            AgentHibernationTranscriptGuard.transcriptHasConversationTurns(
                atPath: directory.appendingPathComponent("missing.jsonl").path
            ) == false
        )
        let oversizedThenUser = directory.appendingPathComponent("oversized-user.jsonl")
        try (String(repeating: "x", count: 2_048) + "\n" + #"{"type":"user","message":{"content":"later"}}"#).write(to: oversizedThenUser, atomically: true, encoding: .utf8)
        #expect(AgentHibernationTranscriptGuard.transcriptHasConversationTurns(atPath: oversizedThenUser.path, maxScannedLineBytes: 1_024))
        let oversizedOnly = directory.appendingPathComponent("oversized-only.jsonl")
        try String(repeating: "x", count: 2_048).write(to: oversizedOnly, atomically: true, encoding: .utf8)
        #expect(AgentHibernationTranscriptGuard.transcriptHasConversationTurns(atPath: oversizedOnly.path, maxScannedLineBytes: 1_024) == false)
    }

    @Test
    func invalidUTF8LineBeforeConversationTurnIsSkippedAndDoesNotTriggerRestore() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        var liveData = Data([0xff, 0xfe, 0x0a])
        liveData.append(Data(#"{"type":"user","message":{"content":"later"}}"#.utf8))
        liveData.append(0x0a)
        try liveData.write(to: live)
        try populatedTranscript.write(to: snapshot, atomically: true, encoding: .utf8)

        #expect(AgentHibernationTranscriptGuard.transcriptHasConversationTurns(atPath: live.path))

        let restored = AgentHibernationTranscriptGuard.restoreIfClobbered(
            .init(transcriptPath: live.path, snapshotPath: snapshot.path)
        )

        #expect(restored == false)
        #expect(try Data(contentsOf: live) == liveData)
    }

    @Test
    func resolveTranscriptPathFindsDirectAndNestedClaudeTranscripts() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        let cwd = "/tmp/repo.with.dot"
        let sessionId = "session-123"
        let direct = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        try FileManager.default.createDirectory(at: direct.deletingLastPathComponent(), withIntermediateDirectories: true)
        try metadataStub.write(to: direct, atomically: true, encoding: .utf8)

        #expect(
            AgentHibernationTranscriptGuard.resolveTranscriptPath(
                agent: agent(sessionId: sessionId, workingDirectory: cwd),
                homeDirectory: home.path
            ) == direct.path
        )

        try FileManager.default.removeItem(at: direct)
        let nested = nestedTranscriptURL(home: home, cwd: cwd, sessionId: sessionId)
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try metadataStub.write(to: nested, atomically: true, encoding: .utf8)

        #expect(
            AgentHibernationTranscriptGuard.resolveTranscriptPath(
                agent: agent(sessionId: sessionId, workingDirectory: cwd),
                homeDirectory: home.path
            ) == nested.path
        )
    }

    @Test
    func resolveTranscriptPathSearchesAccountRootsAndDefaultClaudeRoot() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let cwd = "/tmp/repo"
        let accountSessionId = "session-account"
        let accountRoot = home
            .appendingPathComponent(".codex-accounts", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: true)
            .appendingPathComponent("acct-1", isDirectory: true)
        let accountTranscript = transcriptURL(configRoot: accountRoot, cwd: cwd, sessionId: accountSessionId)
        try FileManager.default.createDirectory(
            at: accountTranscript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try populatedTranscript.write(to: accountTranscript, atomically: true, encoding: .utf8)

        let accountAgent = agent(sessionId: accountSessionId, workingDirectory: cwd)
        #expect(
            AgentHibernationTranscriptGuard.resolveTranscriptPath(
                agent: accountAgent,
                homeDirectory: home.path
            ) == accountTranscript.path
        )

        let capturedSnapshot = try #require(snapshotOutcomeValue(from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: accountAgent,
                homeDirectory: home.path,
                snapshotDirectory: snapshots
        )))
        #expect(capturedSnapshot.transcriptPath == accountTranscript.path)
        #expect(try String(contentsOfFile: capturedSnapshot.snapshotPath, encoding: .utf8) == populatedTranscript)

        let defaultSessionId = "session-default"
        let defaultTranscript = transcriptURL(home: home, cwd: cwd, sessionId: defaultSessionId)
        try FileManager.default.createDirectory(
            at: defaultTranscript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try populatedTranscript.write(to: defaultTranscript, atomically: true, encoding: .utf8)

        #expect(
            AgentHibernationTranscriptGuard.resolveTranscriptPath(
                agent: agent(sessionId: defaultSessionId, workingDirectory: cwd),
                homeDirectory: home.path
            ) == defaultTranscript.path
        )
    }

    @Test
    func resolveTranscriptPathHonorsConfigOverrideAndRejectsUnsupportedAgents() throws {
        let home = try temporaryDirectory()
        let customConfig = home.appendingPathComponent("custom-claude", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let cwd = "/tmp/repo"
        let sessionId = "session-override"
        let direct = transcriptURL(configRoot: customConfig, cwd: cwd, sessionId: sessionId)
        try FileManager.default.createDirectory(at: direct.deletingLastPathComponent(), withIntermediateDirectories: true)
        try metadataStub.write(to: direct, atomically: true, encoding: .utf8)

        let launch = AgentLaunchCommandSnapshot(
            launcher: "claude",
            executablePath: "/usr/bin/claude",
            arguments: ["/usr/bin/claude"],
            workingDirectory: cwd,
            environment: ["CLAUDE_CONFIG_DIR": "~/custom-claude"],
            capturedAt: nil,
            source: nil
        )
        #expect(
            AgentHibernationTranscriptGuard.resolveTranscriptPath(
                agent: agent(sessionId: sessionId, workingDirectory: cwd, launchCommand: launch),
                homeDirectory: home.path
            ) == direct.path
        )
        #expect(
            AgentHibernationTranscriptGuard.resolveTranscriptPath(
                agent: agent(kind: .codex, sessionId: sessionId, workingDirectory: cwd),
                homeDirectory: home.path
            ) == nil
        )
        #expect(
            AgentHibernationTranscriptGuard.resolveTranscriptPath(
                agent: agent(sessionId: sessionId, workingDirectory: nil),
                homeDirectory: home.path
            ) == nil
        )
    }

    @Test
    func resolveTranscriptPathScopesRecordedHookTranscriptPathToPanel() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let cwd = "/tmp/repo"
        let sessionId = "session-recorded"
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: panelId)
        let staleTranscript = home.appendingPathComponent("outside/stale.jsonl")
        let recordedTranscript = home.appendingPathComponent("outside/recorded.jsonl")
        let derivedTranscript = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        try writeFile(populatedTranscript, to: staleTranscript)
        try writeFile(populatedTranscript, to: recordedTranscript)
        try writeFile(populatedTranscript + #"{"type":"assistant","message":{"content":"derived"}}"# + "\n", to: derivedTranscript)
        let storeURL = RestorableAgentKind.claude.hookStoreFileURL(homeDirectory: home.path)
        let staleRecord = #""sessionId":" \#(sessionId) ","workspaceId":"\#(UUID().uuidString)","surfaceId":"\#(UUID().uuidString)","transcriptPath":"\#(staleTranscript.path)","updatedAt":1"#
        let currentRecord = #""sessionId":" \#(sessionId) ","workspaceId":"\#(workspaceId.uuidString)","surfaceId":"\#(panelId.uuidString)","transcriptPath":"~/outside/recorded.jsonl","updatedAt":2"#
        let claudeAgent = agent(sessionId: sessionId, workingDirectory: cwd)
        try writeFile(#"{"version":1,"sessions":{"stale":{\#(staleRecord)}}}"#, to: storeURL)
        #expect(AgentHibernationTranscriptGuard.resolveTranscriptPath(agent: claudeAgent, panelKey: panelKey, homeDirectory: home.path) == derivedTranscript.path)
        try writeFile(#"{"version":1,"sessions":{"stale":{\#(staleRecord)},"current":{\#(currentRecord)}}}"#, to: storeURL)
        #expect(
            AgentHibernationTranscriptGuard.resolveTranscriptPath(
                agent: claudeAgent,
                panelKey: panelKey,
                homeDirectory: home.path
            ) == recordedTranscript.path
        )
        let protected = try #require(snapshotOutcomeValue(from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
            agent: claudeAgent,
            panelKey: panelKey,
            homeDirectory: home.path,
            snapshotDirectory: snapshots
        )))
        #expect(protected.transcriptPath == recordedTranscript.path)
        #expect(try String(contentsOfFile: protected.snapshotPath, encoding: .utf8) == populatedTranscript)
        let duplicateRecord = #""sessionId":" \#(sessionId) ","workspaceId":"\#(workspaceId.uuidString)","surfaceId":"\#(panelId.uuidString)","transcriptPath":"\#(staleTranscript.path)","updatedAt":3"#
        try writeFile(#"{"version":1,"sessions":{"current":{\#(currentRecord)},"duplicate":{\#(duplicateRecord)}}}"#, to: storeURL)
        #expect(outcomeIsUnableToProtect(AgentHibernationTranscriptGuard.snapshotBeforeTeardown(agent: claudeAgent, panelKey: panelKey, homeDirectory: home.path, snapshotDirectory: snapshots)))
    }

    @Test
    func snapshotBeforeTeardownPrefersPopulatedCandidateOverEarlierStubs() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let cwd = "/tmp/repo"
        let recordedSession = "recorded-stub"
        let recordedStub = home.appendingPathComponent("outside/recorded-stub.jsonl")
        try writeFile(metadataStub, to: recordedStub)
        let recordedDerived = transcriptURL(home: home, cwd: cwd, sessionId: recordedSession)
        try writeFile(populatedTranscript, to: recordedDerived)
        try writeFile(
            #"{"version":1,"sessions":{"hook-key":{"sessionId":"recorded-stub","transcriptPath":""# + recordedStub.path + #""}}}"#,
            to: RestorableAgentKind.claude.hookStoreFileURL(homeDirectory: home.path)
        )
        let recorded = try #require(snapshotOutcomeValue(from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(agent: agent(sessionId: recordedSession, workingDirectory: cwd), homeDirectory: home.path, snapshotDirectory: snapshots)))
        #expect(recorded.transcriptPath == recordedDerived.path)
        let nestedSession = "nested-populated"
        let directStub = transcriptURL(home: home, cwd: cwd, sessionId: nestedSession)
        let nestedPopulated = nestedTranscriptURL(home: home, cwd: cwd, sessionId: nestedSession)
        try writeFile(metadataStub, to: directStub)
        try writeFile(populatedTranscript, to: nestedPopulated)
        let nested = try #require(snapshotOutcomeValue(from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(agent: agent(sessionId: nestedSession, workingDirectory: cwd), homeDirectory: home.path, snapshotDirectory: snapshots)))
        #expect(nested.transcriptPath == nestedPopulated.path)
        let duplicateSession = "standard-duplicates"
        try writeFile(populatedTranscript, to: transcriptURL(home: home, cwd: cwd, sessionId: duplicateSession))
        try writeFile(populatedTranscript, to: nestedTranscriptURL(home: home, cwd: cwd, sessionId: duplicateSession))
        #expect(outcomeIsUnableToProtect(AgentHibernationTranscriptGuard.snapshotBeforeTeardown(agent: agent(sessionId: duplicateSession, workingDirectory: cwd), homeDirectory: home.path, snapshotDirectory: snapshots)))
        let stubsSession = "all-stubs"
        try writeFile(metadataStub, to: transcriptURL(home: home, cwd: cwd, sessionId: stubsSession))
        try writeFile(metadataStub, to: nestedTranscriptURL(home: home, cwd: cwd, sessionId: stubsSession))
        #expect(outcomeIsNothingToProtect(AgentHibernationTranscriptGuard.snapshotBeforeTeardown(agent: agent(sessionId: stubsSession, workingDirectory: cwd), homeDirectory: home.path, snapshotDirectory: snapshots)))
    }

    @Test
    func snapshotBeforeTeardownCopiesOnlyPopulatedTranscriptAndKeepsSameSessionSnapshotsDistinct() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let sessionId = "session-snapshot"
        let live = transcriptURL(home: home, cwd: "/tmp/repo", sessionId: sessionId)
        try FileManager.default.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        let firstContent = populatedTranscript
        try firstContent.write(to: live, atomically: true, encoding: .utf8)
        let oldDate = Date(timeIntervalSinceNow: -15 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: live.path)

        let first = try #require(snapshotOutcomeValue(from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: sessionId, workingDirectory: "/tmp/repo"),
                homeDirectory: home.path,
                snapshotDirectory: snapshots
        )))
        #expect(first.transcriptPath == live.path)
        let firstName = URL(fileURLWithPath: first.snapshotPath).lastPathComponent
        #expect(firstName.hasPrefix("\(sessionId)-") && firstName.hasSuffix(".jsonl"))
        #expect(try String(contentsOfFile: first.snapshotPath, encoding: .utf8) == firstContent)

        let peerSessionId = "session-snapshot-peer"
        let peerLive = transcriptURL(home: home, cwd: "/tmp/repo", sessionId: peerSessionId)
        try populatedTranscript.write(to: peerLive, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: peerLive.path)
        let peer = try #require(snapshotOutcomeValue(from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: peerSessionId, workingDirectory: "/tmp/repo"),
                homeDirectory: home.path,
                snapshotDirectory: snapshots
        )))
        #expect(FileManager.default.fileExists(atPath: first.snapshotPath))
        #expect(FileManager.default.fileExists(atPath: peer.snapshotPath))

        let secondContent = populatedTranscript + #"{"type":"assistant","message":{"content":"again"}}"# + "\n"
        try secondContent.write(to: live, atomically: true, encoding: .utf8)
        let second = try #require(snapshotOutcomeValue(from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: sessionId, workingDirectory: "/tmp/repo"),
                homeDirectory: home.path,
                snapshotDirectory: snapshots
        )))
        #expect(second.snapshotPath != first.snapshotPath)
        #expect(try String(contentsOfFile: second.snapshotPath, encoding: .utf8) == secondContent)
        try FileManager.default.removeItem(atPath: first.snapshotPath)
        #expect(FileManager.default.fileExists(atPath: second.snapshotPath))

        let stubSession = "session-stub"
        let stubLive = transcriptURL(home: home, cwd: "/tmp/repo", sessionId: stubSession)
        try metadataStub.write(to: stubLive, atomically: true, encoding: .utf8)
        #expect(outcomeIsNothingToProtect(AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: stubSession, workingDirectory: "/tmp/repo"),
                homeDirectory: home.path,
                snapshotDirectory: snapshots
        )))
        #expect(FileManager.default.fileExists(atPath: snapshots.appendingPathComponent("\(stubSession).jsonl").path) == false)

        #expect(outcomeIsUnableToProtect(AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
            agent: agent(sessionId: "session-missing", workingDirectory: "/tmp/repo"),
            homeDirectory: home.path,
            snapshotDirectory: snapshots
        )))
        #expect(outcomeIsNothingToProtect(AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
            agent: agent(kind: .codex, sessionId: "session-codex", workingDirectory: "/tmp/repo"),
            homeDirectory: home.path,
            snapshotDirectory: snapshots
        )))
        #expect(AgentHibernationTranscriptGuard.resolveTranscriptPath(agent: agent(sessionId: "../escape", workingDirectory: "/tmp/repo"), homeDirectory: home.path) == nil)
        #expect(outcomeIsUnableToProtect(AgentHibernationTranscriptGuard.snapshotBeforeTeardown(agent: agent(sessionId: "../escape", workingDirectory: "/tmp/repo"), homeDirectory: home.path, snapshotDirectory: snapshots)))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("escape.jsonl").path) == false)
    }

    @Test
    func restoreIfClobberedAppendsMetadataStubAfterSnapshot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        try populatedTranscript.write(to: snapshot, atomically: true, encoding: .utf8)
        try metadataStub.write(to: live, atomically: true, encoding: .utf8)

        let restored = AgentHibernationTranscriptGuard.restoreIfClobbered(
            .init(transcriptPath: live.path, snapshotPath: snapshot.path)
        )

        #expect(restored)
        #expect(try String(contentsOf: live, encoding: .utf8) == populatedTranscript.trimmedTrailingNewlines + "\n" + metadataStub)
    }

    @Test
    func restoreIfClobberedNeverWritesOverPopulatedLiveTranscript() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let liveContent = populatedTranscript + #"{"type":"user","message":{"content":"new"}}"# + "\n"
        try populatedTranscript.write(to: snapshot, atomically: true, encoding: .utf8)
        try liveContent.write(to: live, atomically: true, encoding: .utf8)

        let restored = AgentHibernationTranscriptGuard.restoreIfClobbered(
            .init(transcriptPath: live.path, snapshotPath: snapshot.path)
        )

        #expect(restored == false)
        #expect(try String(contentsOf: live, encoding: .utf8) == liveContent)
    }

    @Test
    func restoreIfClobberedRestoresMissingLiveTranscriptExactly() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        try populatedTranscript.write(to: snapshot, atomically: true, encoding: .utf8)

        let restored = AgentHibernationTranscriptGuard.restoreIfClobbered(
            .init(transcriptPath: live.path, snapshotPath: snapshot.path)
        )

        #expect(restored)
        #expect(try String(contentsOf: live, encoding: .utf8) == populatedTranscript)
    }

    @Test
    func restoreIfClobberedIgnoresStubSnapshot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let liveContent = metadataStub
        try liveContent.write(to: live, atomically: true, encoding: .utf8)
        try metadataStub.write(to: snapshot, atomically: true, encoding: .utf8)

        let restored = AgentHibernationTranscriptGuard.restoreIfClobbered(
            .init(transcriptPath: live.path, snapshotPath: snapshot.path)
        )

        #expect(restored == false)
        #expect(try String(contentsOf: live, encoding: .utf8) == liveContent)
    }

    private var metadataStub: String {
        [
            #"{"type":"last-prompt","prompt":"continue"}"#,
            #"{"type":"ai-title","aiTitle":"Fix hibernation"}"#,
            #"{"type":"mode","mode":"default"}"#,
        ].joined(separator: "\n") + "\n"
    }

    private var populatedTranscript: String {
        [
            #"{"type":"summary","summary":"Session"}"#,
            #"{"type":"user","message":{"role":"user","content":"hello"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":"hi"}}"#,
        ].joined(separator: "\n") + "\n"
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-transcript-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func transcriptURL(home: URL, cwd: String, sessionId: String) -> URL {
        transcriptURL(configRoot: home.appendingPathComponent(".claude", isDirectory: true), cwd: cwd, sessionId: sessionId)
    }

    private func transcriptURL(configRoot: URL, cwd: String, sessionId: String) -> URL {
        configRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd), isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
    }

    private func nestedTranscriptURL(home: URL, cwd: String, sessionId: String) -> URL {
        transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
            .deletingLastPathComponent()
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
    }

    private func snapshotOutcomeValue(from outcome: AgentHibernationTranscriptGuard.TeardownSnapshotOutcome) -> AgentHibernationTranscriptGuard.TeardownTranscriptSnapshot? { guard case .snapshot(let snapshot) = outcome else { return nil }; return snapshot }

    private func outcomeIsNothingToProtect(_ outcome: AgentHibernationTranscriptGuard.TeardownSnapshotOutcome) -> Bool { guard case .nothingToProtect = outcome else { return false }; return true }

    private func outcomeIsUnableToProtect(_ outcome: AgentHibernationTranscriptGuard.TeardownSnapshotOutcome) -> Bool { guard case .unableToProtect = outcome else { return false }; return true }

    private func writeFile(_ content: String, to url: URL) throws { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try content.write(to: url, atomically: true, encoding: .utf8) }

    private func agent(
        kind: RestorableAgentKind = .claude,
        sessionId: String,
        workingDirectory: String?,
        launchCommand: AgentLaunchCommandSnapshot? = nil
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            launchCommand: launchCommand
        )
    }
}

private extension String {
    var trimmedTrailingNewlines: String {
        var value = self
        while value.last == "\n" || value.last == "\r" {
            value.removeLast()
        }
        return value
    }
}
