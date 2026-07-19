import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct AgentHibernationTranscriptGuardScanTests {
    @Test
    func liveVersionCheckRevalidatesBytesAfterSameSizeRewriteWithRestoredModificationDate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let original = Data("abcdef".utf8)
        let replacement = Data("UVWXYZ".utf8)
        try original.write(to: live)
        try original.write(to: snapshot)
        let validated = try #require(AgentHibernationTranscriptGuard.snapshotStillMatchesLive(
            .init(transcriptPath: live.path, snapshotPath: snapshot.path)
        ))
        let originalVersion = try #require(validated.liveFileVersion)

        let handle = try FileHandle(forWritingTo: live)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: replacement)
        try handle.truncate(atOffset: UInt64(replacement.count))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: originalVersion.modificationDate],
            ofItemAtPath: live.path
        )
        let rewrittenAttributes = try FileManager.default.attributesOfItem(atPath: live.path)
        #expect((rewrittenAttributes[.systemFileNumber] as? NSNumber)?.uint64Value == originalVersion.fileNumber)
        #expect((rewrittenAttributes[.size] as? NSNumber)?.uint64Value == originalVersion.size)
        #expect(rewrittenAttributes[.modificationDate] as? Date == originalVersion.modificationDate)

        #expect(AgentHibernationTranscriptGuard.liveFileVersionStillMatches(validated) == false)
    }

    @Test
    func transcriptReadsRejectSymlinksNamedPipesAndDirectories() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let conversation = Data((#"{"type":"user","message":{"content":"protected"}}"# + "\n").utf8)
        let target = directory.appendingPathComponent("target.jsonl")
        let symlink = directory.appendingPathComponent("symlink.jsonl")
        try conversation.write(to: target)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        #expect(AgentHibernationTranscriptGuard.transcriptHasConversationTurns(atPath: symlink.path) == false)

        let fifo = directory.appendingPathComponent("transcript.fifo")
        try #require(mkfifo(fifo.path, S_IRUSR | S_IWUSR) == 0)
        let fifoDescriptor = open(fifo.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        try #require(fifoDescriptor >= 0)
        defer { Darwin.close(fifoDescriptor) }
        let bytesWritten = conversation.withUnsafeBytes { buffer in
            Darwin.write(fifoDescriptor, buffer.baseAddress, buffer.count)
        }
        try #require(bytesWritten == conversation.count)
        #expect(AgentHibernationTranscriptGuard.transcriptHasConversationTurns(atPath: fifo.path) == false)

        #expect(AgentHibernationTranscriptGuard.transcriptHasConversationTurns(atPath: directory.path) == false)
    }

    @Test
    func stableComparisonRejectsSymlinksAndNamedPipesBeforeReading() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Keep the relative symlink target and file contents the same byte
        // length so metadata-only validation cannot reject it by size alone.
        let target = directory.appendingPathComponent("target")
        let symlink = directory.appendingPathComponent("live")
        let snapshot = directory.appendingPathComponent("snapshot")
        try Data("abcdef".utf8).write(to: target)
        try Data("abcdef".utf8).write(to: snapshot)
        try FileManager.default.createSymbolicLink(
            atPath: symlink.path,
            withDestinationPath: target.lastPathComponent
        )
        #expect(AgentHibernationTranscriptGuard.snapshotStillMatchesLive(
            .init(transcriptPath: symlink.path, snapshotPath: snapshot.path)
        ) == nil)

        let fifo = directory.appendingPathComponent("empty.fifo")
        let emptySnapshot = directory.appendingPathComponent("empty.snapshot")
        try #require(mkfifo(fifo.path, S_IRUSR | S_IWUSR) == 0)
        try Data().write(to: emptySnapshot)
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/bin/sh")
        writer.arguments = ["-c", ": > \"$1\"", "fifo-writer", fifo.path]
        try writer.run()
        defer {
            if writer.isRunning {
                writer.terminate()
                writer.waitUntilExit()
            }
        }
        #expect(AgentHibernationTranscriptGuard.snapshotStillMatchesLive(
            .init(transcriptPath: fifo.path, snapshotPath: emptySnapshot.path)
        ) == nil)
    }

    @Test
    func conversationScanStopsAtTotalByteBudget() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcript = directory.appendingPathComponent("over-budget.jsonl")
        _ = FileManager.default.createFile(atPath: transcript.path, contents: nil)
        let handle = try FileHandle(forWritingTo: transcript)
        defer { try? handle.close() }
        var malformedLine = Data(repeating: 120, count: 1024 * 1024)
        malformedLine.append(10)
        for _ in 0..<65 {
            try handle.write(contentsOf: malformedLine)
        }
        try handle.write(contentsOf: Data((#"{"type":"user","message":{"content":"too late"}}"# + "\n").utf8))
        try handle.synchronize()

        #expect(AgentHibernationTranscriptGuard.transcriptHasConversationTurns(atPath: transcript.path) == false)
    }

    @Test
    func oversizedLineDiscardResumesScanningAfterNewline() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let garbage = String(repeating: "x", count: 200 * 1024)
        let userTurn = #"{"type":"user","message":{"content":"later"}}"#
        let populated = directory.appendingPathComponent("oversized-then-user.jsonl")
        try (garbage + "\n" + userTurn + "\n").write(to: populated, atomically: true, encoding: .utf8)
        #expect(
            AgentHibernationTranscriptGuard.transcriptHasConversationTurns(
                atPath: populated.path,
                maxScannedLineBytes: 1_024
            )
        )

        let unpopulated = directory.appendingPathComponent("oversized-only.jsonl")
        try garbage.write(to: unpopulated, atomically: true, encoding: .utf8)
        #expect(
            AgentHibernationTranscriptGuard.transcriptHasConversationTurns(
                atPath: unpopulated.path,
                maxScannedLineBytes: 1_024
            ) == false
        )
    }

    @Test
    func streamingRestorePreservesExactBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let snapshotBytes = Data((String(repeating: #"{"type":"assistant","message":{"content":"chunk"}}"# + "\n", count: 96) + "\n\r\n").utf8)
        let stubBytes = Data(("\n\r\n" + metadataStub).utf8)
        try snapshotBytes.write(to: snapshot)
        try stubBytes.write(to: live)

        #expect(
            AgentHibernationTranscriptGuard.restoreIfClobbered(
                .init(transcriptPath: live.path, snapshotPath: snapshot.path)
            )
        )
        #expect(try Data(contentsOf: live) == expectedRestoredBytes(snapshot: snapshotBytes, stub: stubBytes))

        let missingLive = directory.appendingPathComponent("missing-live.jsonl")
        let secondSnapshot = directory.appendingPathComponent("snapshot-missing.jsonl")
        try snapshotBytes.write(to: secondSnapshot)
        #expect(
            AgentHibernationTranscriptGuard.restoreIfClobbered(
                .init(transcriptPath: missingLive.path, snapshotPath: secondSnapshot.path)
            )
        )
        #expect(try Data(contentsOf: missingLive) == snapshotBytes)
    }

    @Test
    func restoreIfClobberedDoesNotOverwriteUnclassifiedLiveTranscript() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let snapshotContent = #"{"type":"user","message":{"content":"before"}}"# + "\n"
        let liveContent = #"{"type":"summary","summary":"new compacted state"}"# + "\n"
        try snapshotContent.write(to: snapshot, atomically: true, encoding: .utf8)
        try liveContent.write(to: live, atomically: true, encoding: .utf8)

        let restored = AgentHibernationTranscriptGuard.restoreIfClobbered(
            .init(transcriptPath: live.path, snapshotPath: snapshot.path)
        )

        #expect(restored == false)
        #expect(try String(contentsOf: live, encoding: .utf8) == liveContent)
    }

    @Test
    func postTeardownRestoreChecksRetainSnapshotWhenLiveTranscriptStaysUnsafe() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let snapshotContent = #"{"type":"user","message":{"content":"before"}}"# + "\n"
        let liveContent = #"{"type":"summary","summary":"new compacted state"}"# + "\n"
        try snapshotContent.write(to: snapshot, atomically: true, encoding: .utf8)
        try liveContent.write(to: live, atomically: true, encoding: .utf8)

        await AgentHibernationTranscriptGuard.runPostTeardownRestoreChecks(
            snapshot: .init(transcriptPath: live.path, snapshotPath: snapshot.path),
            processIDs: [],
            initialRetryDelaysNanoseconds: [0],
            backstopDelaysSeconds: []
        )

        #expect(FileManager.default.fileExists(atPath: snapshot.path))
        #expect(try String(contentsOf: live, encoding: .utf8) == liveContent)
    }

    @Test
    func postTeardownRestoreChecksContinueAfterEarlyRestore() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let snapshotContent = #"{"type":"user","message":{"content":"before"}}"# + "\n"
        try snapshotContent.write(to: snapshot, atomically: true, encoding: .utf8)
        try metadataStub.write(to: live, atomically: true, encoding: .utf8)

        let task = Task {
            await AgentHibernationTranscriptGuard.runPostTeardownRestoreChecks(
                snapshot: .init(transcriptPath: live.path, snapshotPath: snapshot.path),
                processIDs: [],
                initialRetryDelaysNanoseconds: [0, 500_000_000],
                backstopDelaysSeconds: []
            )
        }

        try await waitUntilRestored(live: live, snapshotContent: snapshotContent)
        try metadataStub.write(to: live, atomically: true, encoding: .utf8)
        await task.value

        #expect(try String(contentsOf: live, encoding: .utf8).hasPrefix(snapshotContent))
        #expect(FileManager.default.fileExists(atPath: snapshot.path) == false)
    }

    @Test
    func postTeardownRestoreChecksRetainSnapshotAfterDelayedUnsafeRewrite() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let snapshotContent = #"{"type":"user","message":{"content":"before"}}"# + "\n"
        let unsafeContent = #"{"type":"summary","summary":"delayed compacted state"}"# + "\n"
        try snapshotContent.write(to: snapshot, atomically: true, encoding: .utf8)
        try metadataStub.write(to: live, atomically: true, encoding: .utf8)

        let task = Task {
            await AgentHibernationTranscriptGuard.runPostTeardownRestoreChecks(
                snapshot: .init(transcriptPath: live.path, snapshotPath: snapshot.path),
                processIDs: [],
                initialRetryDelaysNanoseconds: [0, 500_000_000],
                backstopDelaysSeconds: []
            )
        }

        try await waitUntilRestored(live: live, snapshotContent: snapshotContent)
        try unsafeContent.write(to: live, atomically: true, encoding: .utf8)
        await task.value

        #expect(try String(contentsOf: live, encoding: .utf8) == unsafeContent)
        #expect(FileManager.default.fileExists(atPath: snapshot.path))
    }

    @Test
    func cancelledPostTeardownRestoreChecksRetainSnapshotBackup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let snapshotContent = #"{"type":"user","message":{"content":"before"}}"# + "\n"
        try snapshotContent.write(to: snapshot, atomically: true, encoding: .utf8)
        try metadataStub.write(to: live, atomically: true, encoding: .utf8)

        let task = Task {
            await AgentHibernationTranscriptGuard.runPostTeardownRestoreChecks(
                snapshot: .init(transcriptPath: live.path, snapshotPath: snapshot.path),
                processIDs: [],
                initialRetryDelaysNanoseconds: [0, 5_000_000_000],
                backstopDelaysSeconds: []
            )
        }

        try await waitUntilRestored(live: live, snapshotContent: snapshotContent)
        try metadataStub.write(to: live, atomically: true, encoding: .utf8)
        task.cancel()
        await task.value

        #expect(try String(contentsOf: live, encoding: .utf8).hasPrefix(snapshotContent))
        #expect(FileManager.default.fileExists(atPath: snapshot.path))
    }

    private func waitUntilRestored(live: URL, snapshotContent: String) async throws {
        for _ in 0..<200 {
            if try String(contentsOf: live, encoding: .utf8).hasPrefix(snapshotContent) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("expected transcript restore before reclobbering")
    }

    @Test
    func postTeardownRestoreChecksRunsImmediatePassBeforeBackstop() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let snapshotContent = #"{"type":"user","message":{"content":"before"}}"# + "\n"
        try snapshotContent.write(to: snapshot, atomically: true, encoding: .utf8)
        try metadataStub.write(to: live, atomically: true, encoding: .utf8)

        await AgentHibernationTranscriptGuard.runPostTeardownRestoreChecks(
            snapshot: .init(transcriptPath: live.path, snapshotPath: snapshot.path),
            processIDs: [],
            initialRetryDelaysNanoseconds: [0],
            backstopDelaysSeconds: []
        )

        #expect(try String(contentsOf: live, encoding: .utf8).hasPrefix(snapshotContent))
    }

    @Test
    func snapshotBeforeTeardownFailsClosedForNonEmptyUnclassifiedTranscripts() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let cwd = "/tmp/repo"
        let summarySession = "summary-only"
        let summaryTranscript = transcriptURL(home: home, cwd: cwd, sessionId: summarySession)
        try writeFile(#"{"type":"summary","summary":"Compacted session"}"# + "\n", to: summaryTranscript)

        #expect(outcomeIsUnableToProtect(AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
            agent: agent(sessionId: summarySession, workingDirectory: cwd),
            homeDirectory: home.path,
            snapshotDirectory: snapshots
        )))
        #expect(FileManager.default.fileExists(atPath: snapshots.appendingPathComponent("\(summarySession).jsonl").path) == false)

        let nestedSession = "stub-then-summary"
        let directStub = transcriptURL(home: home, cwd: cwd, sessionId: nestedSession)
        let nestedSummary = nestedTranscriptURL(home: home, cwd: cwd, sessionId: nestedSession)
        try writeFile(metadataStub, to: directStub)
        try writeFile(#"{"type":"summary","summary":"Nested compacted session"}"# + "\n", to: nestedSummary)

        #expect(AgentHibernationTranscriptGuard.resolveTranscriptPath(
            agent: agent(sessionId: nestedSession, workingDirectory: cwd),
            homeDirectory: home.path
        ) == nil)
        #expect(outcomeIsUnableToProtect(AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
            agent: agent(sessionId: nestedSession, workingDirectory: cwd),
            homeDirectory: home.path,
            snapshotDirectory: snapshots
        )))
    }

    @Test
    func snapshotBeforeTeardownFailsClosedWhenCopiedSnapshotLosesConversationTurns() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        let fileManager = RewritingCopyFileManager(replacement: metadataStub)
        defer { try? FileManager.default.removeItem(at: home) }

        let cwd = "/tmp/repo"
        let sessionId = "copy-race"
        let live = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        try writeFile(#"{"type":"user","message":{"content":"before"}}"# + "\n", to: live)

        #expect(outcomeIsUnableToProtect(AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
            agent: agent(sessionId: sessionId, workingDirectory: cwd),
            homeDirectory: home.path,
            snapshotDirectory: snapshots,
            fileManager: fileManager
        )))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: snapshots.path))?.isEmpty != false)
    }

    @Test
    func resolveTranscriptPathFallsBackToAnyClaudeProjectWhenWorkingDirectoryMissingOrDrifted() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        let missingCwdSession = "any-project-missing-cwd"
        let missingCwdTranscript = transcriptURL(home: home, cwd: "/tmp/original", sessionId: missingCwdSession)
        let driftedSession = "any-project-drifted-cwd"
        let driftedTranscript = transcriptURL(home: home, cwd: "/tmp/actual", sessionId: driftedSession)
        let content = #"{"type":"user","message":{"content":"before"}}"# + "\n"
        try writeFile(content, to: missingCwdTranscript)
        try writeFile(content, to: driftedTranscript)

        #expect(AgentHibernationTranscriptGuard.resolveTranscriptPath(
            agent: agent(sessionId: missingCwdSession, workingDirectory: nil),
            homeDirectory: home.path
        ) == missingCwdTranscript.path)
        #expect(AgentHibernationTranscriptGuard.resolveTranscriptPath(
            agent: agent(sessionId: driftedSession, workingDirectory: "/tmp/drifted"),
            homeDirectory: home.path
        ) == driftedTranscript.path)
    }

    @Test
    func resolveTranscriptPathFailsClosedOnUnsafeHigherPriorityCandidate() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let sessionId = "unsafe-priority"
        let currentTranscript = transcriptURL(home: home, cwd: "/tmp/current", sessionId: sessionId)
        let staleDuplicateTranscript = transcriptURL(home: home, cwd: "/tmp/stale", sessionId: sessionId)
        try writeFile(#"{"type":"summary","summary":"Compacted session"}"# + "\n", to: currentTranscript)
        try writeFile(#"{"type":"user","message":{"content":"old duplicate"}}"# + "\n", to: staleDuplicateTranscript)

        #expect(AgentHibernationTranscriptGuard.resolveTranscriptPath(
            agent: agent(sessionId: sessionId, workingDirectory: "/tmp/current"),
            homeDirectory: home.path
        ) == nil)
        #expect(outcomeIsUnableToProtect(AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
            agent: agent(sessionId: sessionId, workingDirectory: "/tmp/current"),
            homeDirectory: home.path,
            snapshotDirectory: snapshots
        )))
    }

    @Test
    func resolveTranscriptPathFailsClosedOnAnyProjectDirectAndWorkflowCandidates() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let sessionId = "ambiguous-any-project"
        let staleDirect = transcriptURL(home: home, cwd: "/tmp/stale", sessionId: sessionId)
        let liveWorkflow = workflowTranscriptURL(home: home, cwd: "/tmp/live", containerSessionId: "workflow", sessionId: sessionId)
        try writeFile(#"{"type":"user","message":{"content":"stale"}}"# + "\n", to: staleDirect)
        try writeFile(#"{"type":"user","message":{"content":"live"}}"# + "\n", to: liveWorkflow)

        #expect(AgentHibernationTranscriptGuard.resolveTranscriptPath(
            agent: agent(sessionId: sessionId, workingDirectory: nil),
            homeDirectory: home.path
        ) == nil)
        #expect(outcomeIsUnableToProtect(AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
            agent: agent(sessionId: sessionId, workingDirectory: nil),
            homeDirectory: home.path,
            snapshotDirectory: snapshots
        )))
    }

    @Test
    func resolveTranscriptPathFailsClosedOnDuplicateWorkflowCandidatesAfterMetadataStub() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let cwd = "/tmp/ambiguous-workflow"
        let sessionId = "ambiguous-workflow-session"
        let directTranscript = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        try writeFile(metadataStub, to: directTranscript)
        for containerSessionId in ["workflow-one", "workflow-two"] {
            let workflowTranscript = workflowTranscriptURL(
                home: home,
                cwd: cwd,
                containerSessionId: containerSessionId,
                sessionId: sessionId
            )
            try writeFile(#"{"type":"user","message":{"content":"turn"}}"# + "\n", to: workflowTranscript)
        }

        #expect(AgentHibernationTranscriptGuard.resolveTranscriptPath(
            agent: agent(sessionId: sessionId, workingDirectory: cwd),
            homeDirectory: home.path
        ) == nil)
        #expect(outcomeIsUnableToProtect(AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
            agent: agent(sessionId: sessionId, workingDirectory: cwd),
            homeDirectory: home.path,
            snapshotDirectory: snapshots
        )))
    }

    @Test
    func resolveTranscriptPathFindsWorkflowResolvedClaudeTranscript() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        let cwd = "/tmp/workflow"
        let sessionId = "workflow-resolved-session"
        let workflowTranscript = workflowTranscriptURL(
            home: home,
            cwd: cwd,
            containerSessionId: "workflow-container",
            sessionId: sessionId
        )
        try writeFile(metadataStub, to: workflowTranscriptURL(home: home, cwd: cwd, containerSessionId: "workflow-a", sessionId: sessionId))
        try writeFile(metadataStub, to: workflowTranscriptURL(home: home, cwd: cwd, containerSessionId: "workflow-b", sessionId: sessionId))
        try writeFile(#"{"type":"user","message":{"content":"before"}}"# + "\n", to: workflowTranscript)

        #expect(AgentHibernationTranscriptGuard.resolveTranscriptPath(
            agent: agent(sessionId: sessionId, workingDirectory: cwd),
            homeDirectory: home.path
        ) == workflowTranscript.path)
    }

    @Test
    func resolveTranscriptPathDoesNotScanWorkflowsWhenDirectClaudeTranscriptResolves() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        let cwd = "/tmp/direct-before-workflow"
        let sessionId = "direct-before-workflow-session"
        let directTranscript = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        try writeFile(#"{"type":"user","message":{"content":"before"}}"# + "\n", to: directTranscript)
        let projectRoot = directTranscript.deletingLastPathComponent().path
        let fileManager = DirectoryReadTrackingFileManager(trackedPath: projectRoot)

        #expect(AgentHibernationTranscriptGuard.resolveTranscriptPath(
            agent: agent(sessionId: sessionId, workingDirectory: cwd),
            homeDirectory: home.path,
            fileManager: fileManager
        ) == directTranscript.path)
        #expect(fileManager.trackedDirectoryReadCount == 0)
    }

    @Test
    func resolveTranscriptPathDoesNotFollowWorkflowDirectorySymlinks() throws {
        let home = try temporaryDirectory()
        let externalRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: externalRoot)
        }

        let cwd = "/tmp/symlinked-workflow"
        let sessionId = "symlinked-workflow-session"
        let projectRoot = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
            .deletingLastPathComponent()
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let externalTranscript = externalRoot
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try writeFile(#"{"type":"user","message":{"content":"outside"}}"# + "\n", to: externalTranscript)
        try FileManager.default.createSymbolicLink(
            at: projectRoot.appendingPathComponent("linked-workflow", isDirectory: true),
            withDestinationURL: externalRoot
        )

        #expect(AgentHibernationTranscriptGuard.resolveTranscriptPath(
            agent: agent(sessionId: sessionId, workingDirectory: cwd),
            homeDirectory: home.path
        ) == nil)
    }

    @Test
    func resolveTranscriptPathRejectsWorkflowCandidateThatExhaustsGlobalByteBudget() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        let cwd = "/tmp/oversized-workflow"
        let sessionId = "oversized-workflow-session"
        let workflowTranscript = workflowTranscriptURL(
            home: home,
            cwd: cwd,
            containerSessionId: "workflow-container",
            sessionId: sessionId
        )
        try writeFile(#"{"type":"user","message":{"content":"before"}}"# + "\n", to: workflowTranscript)
        let handle = try FileHandle(forWritingTo: workflowTranscript)
        try handle.truncate(atOffset: UInt64(64 * 1_024 * 1_024 + 1))
        try handle.close()

        #expect(AgentHibernationTranscriptGuard.resolveTranscriptPath(
            agent: agent(sessionId: sessionId, workingDirectory: cwd),
            homeDirectory: home.path
        ) == nil)
    }

    private var metadataStub: String {
        [
            #"{"type":"last-prompt","prompt":"continue"}"#,
            #"{"type":"ai-title","aiTitle":"Fix hibernation"}"#,
            #"{"type":"mode","mode":"default"}"#,
        ].joined(separator: "\n") + "\n"
    }

    private func expectedRestoredBytes(snapshot: Data, stub: Data) -> Data {
        var restored = snapshot
        while restored.last == 10 || restored.last == 13 {
            restored.removeLast()
        }
        restored.append(10)
        var trailing = stub
        while trailing.first == 10 || trailing.first == 13 {
            trailing.removeFirst()
        }
        restored.append(trailing)
        return restored
    }

    private func transcriptURL(home: URL, cwd: String, sessionId: String) -> URL {
        home
            .appendingPathComponent(".claude", isDirectory: true)
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

    private func workflowTranscriptURL(
        home: URL,
        cwd: String,
        containerSessionId: String,
        sessionId: String
    ) -> URL {
        transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
            .deletingLastPathComponent()
            .appendingPathComponent(containerSessionId, isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
    }

    private func writeFile(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func outcomeIsUnableToProtect(_ outcome: AgentHibernationTranscriptGuard.TeardownSnapshotOutcome) -> Bool {
        guard case .unableToProtect = outcome else { return false }
        return true
    }

    private func agent(sessionId: String, workingDirectory: String?) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            launchCommand: nil
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-transcript-guard-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private final class RewritingCopyFileManager: FileManager {
        private let replacement: String

        init(replacement: String) {
            self.replacement = replacement
            super.init()
        }

        override func copyItem(atPath srcPath: String, toPath dstPath: String) throws {
            try replacement.write(toFile: srcPath, atomically: true, encoding: .utf8)
            try super.copyItem(atPath: srcPath, toPath: dstPath)
        }
    }

    private final class DirectoryReadTrackingFileManager: FileManager {
        private let trackedPath: String
        private(set) var trackedDirectoryReadCount = 0

        init(trackedPath: String) {
            self.trackedPath = (trackedPath as NSString).standardizingPath
            super.init()
        }

        override func contentsOfDirectory(atPath path: String) throws -> [String] {
            if (path as NSString).standardizingPath == trackedPath {
                trackedDirectoryReadCount += 1
            }
            return try super.contentsOfDirectory(atPath: path)
        }
    }
}
