import Darwin
import Foundation
import Testing
import CmuxFoundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct AgentHibernationTranscriptGuardTests {
    @Test
    func budgetRejectedNewestGenerationBlocksOlderGeneration() {
        struct Candidate: Equatable {
            let id: String
            let transcript: String
            let generation: Int
            let contentBytes: UInt64
        }

        let filler = Candidate(id: "filler", transcript: "/a", generation: 1, contentBytes: 90)
        let older = Candidate(id: "older", transcript: "/z", generation: 1, contentBytes: 5)
        let newer = Candidate(id: "newer", transcript: "/z", generation: 2, contentBytes: 20)
        let selection = AgentHibernationTranscriptGuard.selectRecoveryCandidatesUnderBudget(
            [older, filler, newer],
            transcriptKey: \.transcript,
            metadataByteCount: { _ in 1 },
            contentByteCount: \.contentBytes,
            isNewer: { $0.generation > $1.generation },
            maximumCount: 10,
            maximumMetadataBytes: 10,
            maximumContentBytes: 100
        )

        #expect(selection.candidates == [filler])
        #expect(selection.blockedTranscriptKeys == ["/z"])
    }

    @Test
    func controlCharacterSessionIDCannotAliasSnapshotPrefix() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let sentinel = snapshots.appendingPathComponent("forged")
        try "keep".write(to: sentinel, atomically: true, encoding: .utf8)

        let outcome = AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
            agent: agent(sessionId: "forged\0suffix", workingDirectory: "/tmp"),
            homeDirectory: home.path,
            snapshotDirectory: snapshots
        )

        guard case .unableToProtect = outcome else {
            Issue.record("Expected control-character session ID to fail closed")
            return
        }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
        #expect(try FileManager.default.contentsOfDirectory(atPath: snapshots.path) == ["forged"])
    }

    @Test
    func stableFileIdentityIncludesDevice() {
        var first = stat()
        first.st_mode = mode_t(S_IFREG | S_IRUSR | S_IWUSR)
        first.st_dev = dev_t(11)
        first.st_ino = ino_t(42)
        first.st_size = 128
        first.st_mtimespec = timespec(tv_sec: 100, tv_nsec: 200)
        var second = first

        #expect(AgentHibernationTranscriptGuard.sameStableFile(first, second))
        second.st_dev = dev_t(12)
        #expect(!AgentHibernationTranscriptGuard.sameStableFile(first, second))
    }

    @Test
    func descriptorBoundMetadataWriteRejectsPathReplacement() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authority = directory.appendingPathComponent("authority.jsonl")
        let replacement = directory.appendingPathComponent("replacement.jsonl")
        let displaced = directory.appendingPathComponent("displaced.jsonl")
        try populatedTranscript.write(to: authority, atomically: true, encoding: .utf8)
        try metadataStub.write(to: replacement, atomically: true, encoding: .utf8)
        let descriptor = open(
            authority.path,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW
        )
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        #expect(AgentHibernationTranscriptGuard.atomicallyRename(
            authority,
            to: displaced
        ))
        #expect(AgentHibernationTranscriptGuard.atomicallyRename(
            replacement,
            to: authority
        ))

        #expect(!AgentHibernationTranscriptGuard.writeRecoveryMetadataData(
            Data("{}".utf8),
            toDescriptor: descriptor,
            expectedPath: authority.path
        ))
        errno = 0
        #expect(getxattr(
            authority.path,
            "com.cmux.agent-transcript-recovery",
            nil,
            0,
            0,
            XATTR_NOFOLLOW
        ) == -1)
        #expect(errno == ENOATTR)
    }

    @Test
    func atomicSwapCapabilityProbeIsStableUnderConcurrency() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    AgentHibernationTranscriptGuard.volumeSupportsAtomicSwap(
                        in: directory
                    )
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }

        #expect(results.count == 16)
        #expect(results.allSatisfy { $0 })
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .isEmpty
        )
    }

    @Test
    func recordedTranscriptFindsCanonicalSessionBeyondLegacyProjection() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let stateDirectory = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

        let targetSessionID = "claude-session-older-than-projection"
        let transcript = home.appendingPathComponent("transcripts/\(targetSessionID).jsonl")
        try writeFile(populatedTranscript, to: transcript)
        let registry = CmuxAgentSessionRegistry(
            url: stateDirectory.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )
        var records = try (0..<300).map { index in
            try canonicalTranscriptRecord(
                sessionID: String(format: "recent-%03d", index),
                transcriptPath: "/tmp/recent-\(index).jsonl",
                updatedAt: TimeInterval(1_000 + index)
            )
        }
        records.append(try canonicalTranscriptRecord(
            sessionID: targetSessionID,
            transcriptPath: transcript.path,
            updatedAt: 1
        ))
        try registry.apply(provider: "claude", records: records)
        try writeTranscriptLegacyProjection(
            records: Array(records.prefix(256)),
            to: stateDirectory.appendingPathComponent("claude-hook-sessions.json")
        )

        #expect(
            AgentHibernationTranscriptGuard.resolveTranscriptPath(
                agent: agent(sessionId: targetSessionID, workingDirectory: nil),
                homeDirectory: home.path
            ) == transcript.path
        )
    }

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
    func teardownSnapshotPersistsRestartRecoveryMetadata() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let cwd = "/tmp/restart-recovery"
        let sessionId = "session-restart-recovery"
        let transcript = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        try writeFile(populatedTranscript, to: transcript)
        let snapshot = try #require(
            snapshotOutcomeValue(
                from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                    agent: agent(sessionId: sessionId, workingDirectory: cwd),
                    homeDirectory: home.path,
                    snapshotDirectory: snapshots,
                    recoveryMetadataOwnerProcessIdentity: nil
                )
            )
        )
        let metadataName = "com.cmux.agent-transcript-recovery"
        let metadataSize = getxattr(snapshot.snapshotPath, metadataName, nil, 0, 0, 0)
        #expect(metadataSize > 0)
        var metadataData = Data(count: max(0, metadataSize))
        let bytesRead = metadataData.withUnsafeMutableBytes { buffer in
            getxattr(snapshot.snapshotPath, metadataName, buffer.baseAddress, buffer.count, 0, 0)
        }
        #expect(bytesRead == metadataSize)
        let metadata = try #require(
            JSONSerialization.jsonObject(with: metadataData) as? [String: Any]
        )
        #expect(metadata["version"] as? Int == 2)
        #expect(metadata["sessionId"] as? String == sessionId)
        #expect(metadata["transcriptPath"] as? String == transcript.path)
        #expect(metadata["snapshotPath"] == nil)
        #expect(UUID(uuidString: try #require(metadata["candidateId"] as? String)) != nil)
        #expect(metadata["candidateState"] as? String == "recoverable")
        #expect(metadata["ownerProcessId"] == nil)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)],
            ofItemAtPath: snapshot.snapshotPath
        )
        let newestContent = populatedTranscript
            + #"{"type":"assistant","message":{"role":"assistant","content":"newest"}}"#
            + "\n"
        try newestContent.write(to: transcript, atomically: true, encoding: .utf8)
        let newestSnapshot = try #require(
            snapshotOutcomeValue(
                from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                    agent: agent(sessionId: sessionId, workingDirectory: cwd),
                    homeDirectory: home.path,
                    snapshotDirectory: snapshots,
                    recoveryMetadataOwnerProcessIdentity: nil
                )
            )
        )
        try metadataStub.write(to: transcript, atomically: true, encoding: .utf8)
        #expect(
            AgentHibernationTranscriptGuard.recoverPendingSnapshots(
                snapshotDirectory: snapshots
            ) == 1
        )
        #expect(AgentHibernationTranscriptGuard.transcriptHasConversationTurns(atPath: transcript.path))
        #expect(
            try String(contentsOf: transcript, encoding: .utf8) ==
                expectedRestoredTranscript(snapshotContent: newestContent)
        )
        #expect(FileManager.default.fileExists(atPath: snapshot.snapshotPath) == false)
        #expect(FileManager.default.fileExists(atPath: newestSnapshot.snapshotPath) == false)
    }

    @Test
    func restartRecoveryPreservesDivergentPopulatedLiveTranscriptAndSnapshot() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let cwd = "/tmp/restart-divergent-live"
        let sessionId = "session-restart-divergent-live"
        let transcript = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        try writeFile(populatedTranscript, to: transcript)
        let snapshot = try #require(snapshotOutcomeValue(
            from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: sessionId, workingDirectory: cwd),
                homeDirectory: home.path,
                snapshotDirectory: snapshots,
                recoveryMetadataOwnerProcessIdentity: nil
            )
        ))
        let divergentLive = [
            #"{"type":"user","message":{"role":"user","content":"new branch"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":"different history"}}"#,
        ].joined(separator: "\n") + "\n"
        try divergentLive.write(to: transcript, atomically: true, encoding: .utf8)

        #expect(
            AgentHibernationTranscriptGuard.recoverPendingSnapshots(
                snapshotDirectory: snapshots
            ) == 0
        )
        #expect(try String(contentsOf: transcript, encoding: .utf8) == divergentLive)
        #expect(try String(contentsOfFile: snapshot.snapshotPath, encoding: .utf8) == populatedTranscript)
    }

    @Test
    func exhaustedProcessProbeBudgetBlocksOlderTranscriptGeneration() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let cwd = "/tmp/process-probe-budget"
        let sessionId = "process-probe-budget"
        let transcript = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        try writeFile(populatedTranscript, to: transcript)
        let older = try #require(snapshotOutcomeValue(
            from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: sessionId, workingDirectory: cwd),
                homeDirectory: home.path,
                snapshotDirectory: snapshots,
                recoveryMetadataOwnerProcessIdentity: nil
            )
        ))
        let newerContent = populatedTranscript
            + #"{"type":"assistant","message":{"content":"new generation"}}"#
            + "\n"
        try writeFile(newerContent, to: transcript)
        let newer = try #require(snapshotOutcomeValue(
            from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: sessionId, workingDirectory: cwd),
                homeDirectory: home.path,
                snapshotDirectory: snapshots
            )
        ))
        try metadataStub.write(to: transcript, atomically: true, encoding: .utf8)

        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(
            snapshotDirectory: snapshots,
            maximumProcessIdentityProbes: 0
        ) == 0)
        #expect(try String(contentsOf: transcript, encoding: .utf8) == metadataStub)
        #expect(FileManager.default.fileExists(atPath: older.snapshotPath))
        #expect(FileManager.default.fileExists(atPath: newer.snapshotPath))
    }

    @Test
    func retainedRenamePreservesMetadataAndNewestCaptureWinsRecovery() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let cwd = "/tmp/restart-retained-ordering"
        let sessionId = "session-retained-ordering"
        let transcript = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        try writeFile(populatedTranscript, to: transcript)
        let olderSnapshot = try #require(snapshotOutcomeValue(
            from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: sessionId, workingDirectory: cwd),
                homeDirectory: home.path,
                snapshotDirectory: snapshots,
                recoveryMetadataOwnerProcessIdentity: nil
            )
        ))
        var olderMetadata = try recoveryMetadataJSON(atPath: olderSnapshot.snapshotPath)
        let oldCaptureDate = Date(timeIntervalSinceNow: -120)
        olderMetadata["capturedAt"] = oldCaptureDate.timeIntervalSinceReferenceDate
        try setRecoveryMetadata(
            try JSONSerialization.data(withJSONObject: olderMetadata),
            atPath: olderSnapshot.snapshotPath
        )

        let newestContent = populatedTranscript
            + #"{"type":"assistant","message":{"role":"assistant","content":"newest"}}"#
            + "\n"
        try newestContent.write(to: transcript, atomically: true, encoding: .utf8)
        let newestSnapshot = try #require(snapshotOutcomeValue(
            from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: sessionId, workingDirectory: cwd),
                homeDirectory: home.path,
                snapshotDirectory: snapshots,
                recoveryMetadataOwnerProcessIdentity: nil
            )
        ))

        AgentHibernationTranscriptGuard.retainSnapshotForRecovery(
            olderSnapshot,
            sessionId: sessionId
        )
        let retained = snapshots.appendingPathComponent("\(sessionId)-retained.jsonl")
        #expect(FileManager.default.fileExists(atPath: olderSnapshot.snapshotPath) == false)
        #expect(FileManager.default.fileExists(atPath: retained.path))
        let retainedMetadata = try recoveryMetadataJSON(atPath: retained.path)
        #expect(retainedMetadata["version"] as? Int == 2)
        #expect(retainedMetadata["snapshotPath"] == nil)
        #expect(
            abs((retainedMetadata["capturedAt"] as? Double ?? 0) -
                oldCaptureDate.timeIntervalSinceReferenceDate) < 0.001
        )

        try metadataStub.write(to: transcript, atomically: true, encoding: .utf8)
        #expect(
            AgentHibernationTranscriptGuard.recoverPendingSnapshots(
                snapshotDirectory: snapshots
            ) == 1
        )
        #expect(
            try String(contentsOf: transcript, encoding: .utf8) ==
                expectedRestoredTranscript(snapshotContent: newestContent)
        )
        #expect(FileManager.default.fileExists(atPath: newestSnapshot.snapshotPath) == false)
        #expect(FileManager.default.fileExists(atPath: retained.path) == false)
    }

    @Test
    func retainedSwapCrashStateKeepsBothV2CandidatesDiscoverable() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let cwd = "/tmp/retained-v2-swap-crash"
        let sessionId = "retained-v2-swap-crash"
        let transcript = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        try writeFile(populatedTranscript, to: transcript)
        let older = try #require(snapshotOutcomeValue(
            from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: sessionId, workingDirectory: cwd),
                homeDirectory: home.path,
                snapshotDirectory: snapshots,
                recoveryMetadataOwnerProcessIdentity: nil
            )
        ))
        AgentHibernationTranscriptGuard.retainSnapshotForRecovery(
            older,
            sessionId: sessionId
        )
        let retained = snapshots.appendingPathComponent("\(sessionId)-retained.jsonl")
        let newerContent = populatedTranscript
            + #"{"type":"assistant","message":{"content":"newer tail"}}"#
            + "\n"
        try newerContent.write(to: transcript, atomically: true, encoding: .utf8)
        let newer = try #require(snapshotOutcomeValue(
            from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: sessionId, workingDirectory: cwd),
                homeDirectory: home.path,
                snapshotDirectory: snapshots,
                recoveryMetadataOwnerProcessIdentity: nil
            )
        ))
        #expect(renamex_np(
            newer.snapshotPath,
            retained.path,
            UInt32(RENAME_SWAP)
        ) == 0)
        try metadataStub.write(to: transcript, atomically: true, encoding: .utf8)

        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(
            snapshotDirectory: snapshots
        ) == 1)
        #expect(try String(contentsOf: transcript, encoding: .utf8).hasPrefix(newerContent))
    }

    @Test
    func restartRecoveryIgnoresMissingCorruptAndOversizedMetadata() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appendingPathComponent("missing-xattr-1.jsonl")
        let corrupt = directory.appendingPathComponent("corrupt-xattr-1.jsonl")
        let oversized = directory.appendingPathComponent("oversized-xattr-1.jsonl")
        try populatedTranscript.write(to: missing, atomically: true, encoding: .utf8)
        try populatedTranscript.write(to: corrupt, atomically: true, encoding: .utf8)
        try populatedTranscript.write(to: oversized, atomically: true, encoding: .utf8)
        try setRecoveryMetadata(Data("{".utf8), atPath: corrupt.path)
        try setRecoveryMetadata(Data(repeating: 0x78, count: 64 * 1024 + 1), atPath: oversized.path)

        #expect(
            AgentHibernationTranscriptGuard.recoverPendingSnapshots(
                snapshotDirectory: directory
            ) == 0
        )
        #expect(FileManager.default.fileExists(atPath: missing.path) == false)
        #expect(FileManager.default.fileExists(atPath: corrupt.path) == false)
        #expect(FileManager.default.fileExists(atPath: oversized.path) == false)
        let quarantine = directory.appendingPathComponent(
            ".recovery-quarantine",
            isDirectory: true
        )
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: quarantine,
            includingPropertiesForKeys: nil
        )
        #expect(quarantined.count == 3)
        for candidate in quarantined {
            #expect(try String(contentsOf: candidate, encoding: .utf8) == populatedTranscript)
        }
    }

    @Test
    func versionOneRecoveryMetadataCannotAuthorizeAPathAfterRename() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionId = "v1-path-bound"
        let live = directory.appendingPathComponent("live.jsonl")
        let candidate = directory.appendingPathComponent(
            "\(sessionId)-candidate.jsonl"
        )
        let authorizedPath = directory.appendingPathComponent(
            "\(sessionId)-authorized.jsonl"
        )
        try metadataStub.write(to: live, atomically: true, encoding: .utf8)
        try populatedTranscript.write(to: candidate, atomically: true, encoding: .utf8)
        try setRecoveryMetadata(
            recoveryMetadataData(
                sessionId: sessionId,
                transcriptPath: live.path,
                snapshotPath: authorizedPath.path,
                capturedAt: Date()
            ),
            atPath: candidate.path
        )

        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(
            snapshotDirectory: directory
        ) == 0)
        #expect(try String(contentsOf: live, encoding: .utf8) == metadataStub)
        #expect(FileManager.default.fileExists(atPath: candidate.path) == false)
        let quarantine = directory.appendingPathComponent(
            ".recovery-quarantine",
            isDirectory: true
        )
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: quarantine,
            includingPropertiesForKeys: nil
        )
        #expect(quarantined.count == 1)
        #expect(
            try String(
                contentsOf: #require(quarantined.first),
                encoding: .utf8
            ) == populatedTranscript
        )
    }

    @Test
    func crossVolumeDisplacementKeepsOldInodeAndDurableRecoveryPointer() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryDirectory = directory.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: recoveryDirectory,
            withIntermediateDirectories: true
        )
        let live = directory.appendingPathComponent("live.jsonl")
        let protected = recoveryDirectory.appendingPathComponent("protected.jsonl")
        try metadataStub.write(to: live, atomically: true, encoding: .utf8)
        try populatedTranscript.write(to: protected, atomically: true, encoding: .utf8)
        let descriptor = open(
            live.path,
            O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW
        )
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        var liveStatus = stat()
        #expect(lstat(live.path, &liveStatus) == 0)
        let guardedIdentity = try #require(AgentPIDProcessIdentity(pid: getpid()))
        let candidateId = UUID().uuidString

        let authority = try #require(
            AgentHibernationTranscriptGuard
                .preserveDisplacedLiveTranscriptAcrossVolumes(
                    transcriptURL: live,
                    recoveryDirectory: recoveryDirectory,
                    protectedSnapshot: .init(
                        transcriptPath: live.path,
                        snapshotPath: protected.path,
                        guardedProcessIdentities: [guardedIdentity]
                    ),
                    expectedLiveStatus: liveStatus,
                    sessionId: "cross-volume-pointer",
                    candidateId: candidateId,
                    capturedAt: Date(),
                    fileManager: .default
                )
        )
        #expect(authority.authorityURL.path != authority.contentURL.path)
        #expect(FileManager.default.fileExists(atPath: live.path) == false)
        #expect(FileManager.default.fileExists(atPath: authority.authorityURL.path))
        #expect(FileManager.default.fileExists(atPath: authority.contentURL.path))

        let lateBranch = #"{"type":"user","message":{"content":"late external branch"}}"#
            + "\n"
        let lateData = Data(lateBranch.utf8)
        let bytesWritten = lateData.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        #expect(bytesWritten == lateData.count)
        #expect(fsync(descriptor) == 0)
        let displacedContent = try String(
            contentsOf: authority.contentURL,
            encoding: .utf8
        )
        #expect(displacedContent.hasPrefix(metadataStub))
        #expect(displacedContent.contains("late external branch"))

        let pointerMetadata = try recoveryMetadataJSON(
            atPath: authority.authorityURL.path
        )
        #expect(pointerMetadata["version"] as? Int == 2)
        #expect(pointerMetadata["candidateId"] as? String == candidateId)
        #expect(pointerMetadata["snapshotPath"] == nil)
        #expect(
            pointerMetadata["externalCandidatePath"] as? String
                == authority.contentURL.path
        )
        #expect(pointerMetadata["ownerProcessId"] as? Int == Int(getpid()))
        let guardedProcesses = try #require(
            pointerMetadata["guardedProcesses"] as? [[String: Any]]
        )
        #expect(guardedProcesses.first?["processId"] as? Int == Int(getpid()))

        // Simulate the next launch after both the cmux owner and guarded
        // writer exited. Both sides of the pointer retain the same candidate
        // identity, so startup can claim the pointer and consume the exact
        // adjacent inode without copying it across volumes first.
        var ownerlessMetadata = pointerMetadata
        ownerlessMetadata.removeValue(forKey: "ownerProcessId")
        ownerlessMetadata.removeValue(forKey: "ownerProcessStartSeconds")
        ownerlessMetadata.removeValue(forKey: "ownerProcessStartMicroseconds")
        ownerlessMetadata["guardedProcesses"] = []
        let ownerlessData = try JSONSerialization.data(
            withJSONObject: ownerlessMetadata
        )
        try setRecoveryMetadata(
            ownerlessData,
            atPath: authority.authorityURL.path
        )
        try setRecoveryMetadata(
            ownerlessData,
            atPath: authority.contentURL.path
        )
        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(
            snapshotDirectory: recoveryDirectory
        ) == 1)
        #expect(
            try String(contentsOf: live, encoding: .utf8)
                .contains("late external branch")
        )
        #expect(
            FileManager.default.fileExists(atPath: authority.authorityURL.path)
                == false
        )
        #expect(
            FileManager.default.fileExists(atPath: authority.contentURL.path)
                == false
        )
    }

    @Test
    func crossVolumePointerRejectsWeakenedExternalMetadata() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryDirectory = directory.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: recoveryDirectory,
            withIntermediateDirectories: true
        )
        let live = directory.appendingPathComponent("live.jsonl")
        let protected = recoveryDirectory.appendingPathComponent("protected.jsonl")
        try metadataStub.write(to: live, atomically: true, encoding: .utf8)
        try populatedTranscript.write(to: protected, atomically: true, encoding: .utf8)
        var liveStatus = stat()
        #expect(lstat(live.path, &liveStatus) == 0)
        let candidateId = UUID().uuidString
        let authority = try #require(
            AgentHibernationTranscriptGuard
                .preserveDisplacedLiveTranscriptAcrossVolumes(
                    transcriptURL: live,
                    recoveryDirectory: recoveryDirectory,
                    protectedSnapshot: .init(
                        transcriptPath: live.path,
                        snapshotPath: protected.path
                    ),
                    expectedLiveStatus: liveStatus,
                    sessionId: "cross-volume-mismatch",
                    candidateId: candidateId,
                    capturedAt: Date(),
                    fileManager: .default
                )
        )

        var pointerMetadata = try recoveryMetadataJSON(
            atPath: authority.authorityURL.path
        )
        pointerMetadata.removeValue(forKey: "ownerProcessId")
        pointerMetadata.removeValue(forKey: "ownerProcessStartSeconds")
        pointerMetadata.removeValue(forKey: "ownerProcessStartMicroseconds")
        pointerMetadata.removeValue(forKey: "ownerRuntimeId")
        pointerMetadata.removeValue(forKey: "ownerBundleIdentifier")
        pointerMetadata["guardedProcesses"] = []
        pointerMetadata["hasUncapturedGuardedProcesses"] = false
        var weakenedExternalMetadata = pointerMetadata
        weakenedExternalMetadata["hasUncapturedGuardedProcesses"] = true
        try setRecoveryMetadata(
            try JSONSerialization.data(withJSONObject: pointerMetadata),
            atPath: authority.authorityURL.path
        )
        try setRecoveryMetadata(
            try JSONSerialization.data(withJSONObject: weakenedExternalMetadata),
            atPath: authority.contentURL.path
        )

        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(
            snapshotDirectory: recoveryDirectory
        ) == 0)
        #expect(!FileManager.default.fileExists(atPath: authority.authorityURL.path))
        #expect(FileManager.default.fileExists(atPath: authority.contentURL.path))
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: recoveryDirectory.appendingPathComponent(".recovery-quarantine"),
            includingPropertiesForKeys: nil
        )
        #expect(quarantined.count == 1)
    }

    @Test
    func startupCleansPendingExternalStagingBeforeInodePublication() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryDirectory = directory.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(
            at: recoveryDirectory,
            withIntermediateDirectories: true
        )
        let sessionId = "pending-external-stage"
        let candidateId = UUID().uuidString
        let live = directory.appendingPathComponent("live.jsonl")
        let external = directory.appendingPathComponent(
            ".live.jsonl.cmux-recovery-\(candidateId).jsonl"
        )
        let pointer = recoveryDirectory.appendingPathComponent(
            "\(sessionId)-staging-\(candidateId).jsonl"
        )
        try Data().write(to: external)
        try metadataStub.write(to: pointer, atomically: true, encoding: .utf8)
        try setRecoveryMetadata(
            try externalStagingMetadataData(
                sessionId: sessionId,
                transcriptPath: live.path,
                candidateId: candidateId,
                state: "external-staging-pending",
                externalPath: external.path
            ),
            atPath: pointer.path
        )

        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(
            snapshotDirectory: recoveryDirectory
        ) == 0)
        #expect(!FileManager.default.fileExists(atPath: pointer.path))
        #expect(!FileManager.default.fileExists(atPath: external.path))
    }

    @Test
    func startupCleansPopulatedExternalStagingBeforeSwap() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryDirectory = directory.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(
            at: recoveryDirectory,
            withIntermediateDirectories: true
        )
        let sessionId = "populated-external-stage"
        let candidateId = UUID().uuidString
        let live = directory.appendingPathComponent("live.jsonl")
        let external = directory.appendingPathComponent(
            ".live.jsonl.cmux-recovery-\(candidateId).jsonl"
        )
        let pointer = recoveryDirectory.appendingPathComponent(
            "\(sessionId)-staging-\(candidateId).jsonl"
        )
        try metadataStub.write(to: pointer, atomically: true, encoding: .utf8)
        try populatedTranscript.write(to: external, atomically: true, encoding: .utf8)
        var externalStatus = stat()
        #expect(lstat(external.path, &externalStatus) == 0)
        let metadata = try externalStagingMetadataData(
            sessionId: sessionId,
            transcriptPath: live.path,
            candidateId: candidateId,
            state: "external-staging",
            externalPath: external.path,
            externalDevice: UInt64(externalStatus.st_dev),
            externalFileNumber: UInt64(externalStatus.st_ino)
        )
        try setRecoveryMetadata(metadata, atPath: pointer.path)
        try setRecoveryMetadata(metadata, atPath: external.path)

        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(
            snapshotDirectory: recoveryDirectory
        ) == 0)
        #expect(!FileManager.default.fileExists(atPath: pointer.path))
        #expect(!FileManager.default.fileExists(atPath: external.path))
    }

    @Test
    func restartRecoveryValidatesMetadataBeforeApplyingCandidateLimit() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let cwd = "/tmp/restart-candidate-admission"
        let sessionId = "session-valid-beyond-invalid-limit"
        let transcript = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        try writeFile(populatedTranscript, to: transcript)
        let validSnapshot = try #require(snapshotOutcomeValue(
            from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: sessionId, workingDirectory: cwd),
                homeDirectory: home.path,
                snapshotDirectory: snapshots,
                recoveryMetadataOwnerProcessIdentity: nil
            )
        ))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -600)],
            ofItemAtPath: validSnapshot.snapshotPath
        )
        for index in 0..<300 {
            let invalid = snapshots.appendingPathComponent("invalid-newer-\(index).jsonl")
            try populatedTranscript.write(to: invalid, atomically: true, encoding: .utf8)
        }
        try metadataStub.write(to: transcript, atomically: true, encoding: .utf8)

        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(snapshotDirectory: snapshots) == 1)
        #expect(
            try String(contentsOf: transcript, encoding: .utf8) ==
                expectedRestoredTranscript(snapshotContent: populatedTranscript)
        )
        #expect(FileManager.default.fileExists(atPath: validSnapshot.snapshotPath) == false)
    }

    @Test
    func restartRecoveryRotatesFairlyPastDivergentTranscriptGroups() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let divergentLive = [
            #"{"type":"user","message":{"role":"user","content":"live branch"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":"live answer"}}"#,
        ].joined(separator: "\n") + "\n"
        for index in 0..<260 {
            let sessionId = String(format: "fair-%03d", index)
            let live = directory.appendingPathComponent("live-\(sessionId).jsonl")
            let snapshot = directory.appendingPathComponent("\(sessionId)-snapshot.jsonl")
            try divergentLive.write(to: live, atomically: true, encoding: .utf8)
            try populatedTranscript.write(to: snapshot, atomically: true, encoding: .utf8)
            try setRecoveryMetadata(
                recoveryMetadataData(
                    sessionId: sessionId,
                    transcriptPath: live.path,
                    snapshotPath: snapshot.path,
                    capturedAt: Date(timeIntervalSinceNow: TimeInterval(-index))
                ),
                atPath: snapshot.path
            )
        }

        let targetSessionId = "fair-zzz"
        let targetLive = directory.appendingPathComponent("live-\(targetSessionId).jsonl")
        let targetSnapshot = directory.appendingPathComponent("\(targetSessionId)-snapshot.jsonl")
        try metadataStub.write(to: targetLive, atomically: true, encoding: .utf8)
        try populatedTranscript.write(to: targetSnapshot, atomically: true, encoding: .utf8)
        try setRecoveryMetadata(
            recoveryMetadataData(
                sessionId: targetSessionId,
                transcriptPath: targetLive.path,
                snapshotPath: targetSnapshot.path,
                capturedAt: Date(timeIntervalSinceNow: -3_600)
            ),
            atPath: targetSnapshot.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
            ofItemAtPath: targetSnapshot.path
        )

        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(snapshotDirectory: directory) == 0)
        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(snapshotDirectory: directory) == 1)
        #expect(
            try String(contentsOf: targetLive, encoding: .utf8) ==
                expectedRestoredTranscript(snapshotContent: populatedTranscript)
        )
        #expect(FileManager.default.fileExists(atPath: targetSnapshot.path) == false)
    }

    @Test
    func retainedSlotPreservesDivergentProtectedBranches() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let cwd = "/tmp/retained-divergent-branches"
        let sessionId = "retained-divergent-branches"
        let transcript = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        let firstBranch = populatedTranscript
        try writeFile(firstBranch, to: transcript)
        let first = try #require(snapshotOutcomeValue(
            from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: sessionId, workingDirectory: cwd),
                homeDirectory: home.path,
                snapshotDirectory: snapshots,
                recoveryMetadataOwnerProcessIdentity: nil
            )
        ))
        AgentHibernationTranscriptGuard.retainSnapshotForRecovery(first, sessionId: sessionId)
        let retained = snapshots.appendingPathComponent("\(sessionId)-retained.jsonl")

        let secondBranch = [
            #"{"type":"user","message":{"role":"user","content":"different branch"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":"different answer"}}"#,
        ].joined(separator: "\n") + "\n"
        try secondBranch.write(to: transcript, atomically: true, encoding: .utf8)
        let second = try #require(snapshotOutcomeValue(
            from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: sessionId, workingDirectory: cwd),
                homeDirectory: home.path,
                snapshotDirectory: snapshots
            )
        ))
        AgentHibernationTranscriptGuard.retainSnapshotForRecovery(second, sessionId: sessionId)

        #expect(try String(contentsOf: retained, encoding: .utf8) == firstBranch)
        #expect(try String(contentsOfFile: second.snapshotPath, encoding: .utf8) == secondBranch)
    }

    @Test
    func recoveryQuotaRejectsAnotherDivergentBranchWithoutChangingLive() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let cwd = "/tmp/recovery-storage-quota"
        let sessionId = "recovery-storage-quota"
        let transcript = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        let branches = (1...3).map { branch in
            [
                #"{"type":"user","message":{"role":"user","content":"branch \#(branch)"}}"#,
                #"{"type":"assistant","message":{"role":"assistant","content":"answer \#(branch)"}}"#,
            ].joined(separator: "\n") + "\n"
        }

        try writeFile(branches[0], to: transcript)
        let first = try #require(snapshotOutcomeValue(
            from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: sessionId, workingDirectory: cwd),
                homeDirectory: home.path,
                snapshotDirectory: snapshots,
                maximumRecoveryStorageFileCount: 2,
                maximumRecoveryStorageBytes: 1_024 * 1_024,
                recoveryMetadataOwnerProcessIdentity: nil
            )
        ))
        AgentHibernationTranscriptGuard.retainSnapshotForRecovery(
            first,
            sessionId: sessionId
        )

        try writeFile(branches[1], to: transcript)
        let second = try #require(snapshotOutcomeValue(
            from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: sessionId, workingDirectory: cwd),
                homeDirectory: home.path,
                snapshotDirectory: snapshots,
                maximumRecoveryStorageFileCount: 2,
                maximumRecoveryStorageBytes: 1_024 * 1_024,
                recoveryMetadataOwnerProcessIdentity: nil
            )
        ))
        AgentHibernationTranscriptGuard.retainSnapshotForRecovery(
            second,
            sessionId: sessionId
        )
        let authoritiesBefore = try FileManager.default.contentsOfDirectory(
            atPath: snapshots.path
        ).filter { !$0.hasPrefix(".") && $0.hasSuffix(".jsonl") }
        #expect(authoritiesBefore.count == 2)

        try writeFile(branches[2], to: transcript)
        let rejected = AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
            agent: agent(sessionId: sessionId, workingDirectory: cwd),
            homeDirectory: home.path,
            snapshotDirectory: snapshots,
            maximumRecoveryStorageFileCount: 2,
            maximumRecoveryStorageBytes: 1_024 * 1_024,
            recoveryMetadataOwnerProcessIdentity: nil
        )

        #expect(outcomeIsUnableToProtect(rejected))
        #expect(try String(contentsOf: transcript, encoding: .utf8) == branches[2])
        let authoritiesAfter = try FileManager.default.contentsOfDirectory(
            atPath: snapshots.path
        ).filter { !$0.hasPrefix(".") && $0.hasSuffix(".jsonl") }
        #expect(authoritiesAfter.sorted() == authoritiesBefore.sorted())
    }

    @Test
    func retainedSlotQuarantinesFutureMetadataBeforeConsideringItsBytes() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let cwd = "/tmp/retained-invalid-version"
        let sessionId = "retained-invalid-version"
        let transcript = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        try writeFile(populatedTranscript, to: transcript)
        let fresh = try #require(snapshotOutcomeValue(
            from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: sessionId, workingDirectory: cwd),
                homeDirectory: home.path,
                snapshotDirectory: snapshots,
                recoveryMetadataOwnerProcessIdentity: nil
            )
        ))
        let retained = snapshots.appendingPathComponent("\(sessionId)-retained.jsonl")
        let invalidSuperset = populatedTranscript
            + #"{"type":"assistant","message":{"content":"invalid future metadata"}}"#
            + "\n"
        try invalidSuperset.write(to: retained, atomically: true, encoding: .utf8)
        let invalidMetadata = try JSONSerialization.data(withJSONObject: [
            "version": 99,
            "sessionId": sessionId,
            "transcriptPath": transcript.path,
            "candidateId": UUID().uuidString,
            "candidateState": "recoverable",
        ], options: [.sortedKeys])
        try setRecoveryMetadata(invalidMetadata, atPath: retained.path)

        AgentHibernationTranscriptGuard.retainSnapshotForRecovery(
            fresh,
            sessionId: sessionId
        )

        #expect(try String(contentsOf: retained, encoding: .utf8) == populatedTranscript)
        #expect(!FileManager.default.fileExists(atPath: fresh.snapshotPath))
        let quarantine = snapshots.appendingPathComponent(".recovery-quarantine")
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: quarantine,
            includingPropertiesForKeys: nil
        )
        #expect(quarantined.count == 1)
        #expect(try String(contentsOf: #require(quarantined.first), encoding: .utf8) == invalidSuperset)
    }

    @Test
    func retainedSlotMissingPathCommitNeverOverwritesLateDestination() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.jsonl")
        let destination = directory.appendingPathComponent("destination.jsonl")
        let lateDestinationContent = "independent recovery authority\n"
        try populatedTranscript.write(to: source, atomically: true, encoding: .utf8)
        try lateDestinationContent.write(to: destination, atomically: true, encoding: .utf8)

        #expect(AgentHibernationTranscriptGuard.atomicallyRename(
            source,
            to: destination
        ) == false)
        #expect(try String(contentsOf: destination, encoding: .utf8) == lateDestinationContent)
        #expect(try String(contentsOf: source, encoding: .utf8) == populatedTranscript)
    }

    @Test
    func repeatedPrefixRelatedAbortsStayInOneRetainedSlot() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let cwd = "/tmp/repeated-abort-retention"
        let sessionId = "repeated-abort-retention"
        let transcript = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        var content = populatedTranscript

        for index in 0..<20 {
            content += #"{"type":"assistant","message":{"role":"assistant","content":"abort "#
                + String(index)
                + #""}}"#
                + "\n"
            try writeFile(content, to: transcript)
            let snapshot = try #require(snapshotOutcomeValue(
                from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                    agent: agent(sessionId: sessionId, workingDirectory: cwd),
                    homeDirectory: home.path,
                    snapshotDirectory: snapshots
                )
            ))
            AgentHibernationTranscriptGuard.retainSnapshotForRecovery(
                snapshot,
                sessionId: sessionId
            )
        }

        let visibleSnapshots = try FileManager.default.contentsOfDirectory(atPath: snapshots.path)
            .filter { !$0.hasPrefix(".") && $0.hasSuffix(".jsonl") }
        #expect(visibleSnapshots == ["\(sessionId)-retained.jsonl"])
        #expect(
            try String(
                contentsOf: snapshots.appendingPathComponent(visibleSnapshots[0]),
                encoding: .utf8
            ) == content
        )
    }

    @Test
    func restartRecoveryDefersWhileCapturedOwnerProcessIsAlive() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let cwd = "/tmp/restart-live-owner"
        let sessionId = "session-restart-live-owner"
        let transcript = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        try writeFile(populatedTranscript, to: transcript)
        let snapshot = try #require(snapshotOutcomeValue(
            from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: sessionId, workingDirectory: cwd),
                homeDirectory: home.path,
                snapshotDirectory: snapshots
            )
        ))

        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        owner.arguments = ["30"]
        try owner.run()
        defer {
            if owner.isRunning {
                owner.terminate()
                owner.waitUntilExit()
            }
        }
        let ownerIdentity = try #require(AgentPIDProcessIdentity(pid: owner.processIdentifier))
        var metadata = try recoveryMetadataJSON(atPath: snapshot.snapshotPath)
        metadata["ownerProcessId"] = Int(ownerIdentity.pid)
        metadata["ownerProcessStartSeconds"] = ownerIdentity.startSeconds
        metadata["ownerProcessStartMicroseconds"] = ownerIdentity.startMicroseconds
        try setRecoveryMetadata(try JSONSerialization.data(withJSONObject: metadata), atPath: snapshot.snapshotPath)
        try metadataStub.write(to: transcript, atomically: true, encoding: .utf8)

        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(snapshotDirectory: snapshots) == 0)
        #expect(FileManager.default.fileExists(atPath: snapshot.snapshotPath))

        owner.terminate()
        owner.waitUntilExit()
        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(snapshotDirectory: snapshots) == 1)
        #expect(
            try String(contentsOf: transcript, encoding: .utf8) ==
                expectedRestoredTranscript(snapshotContent: populatedTranscript)
        )
    }

    @Test
    func restartRecoveryDefersWhileCapturedAgentProcessIsAlive() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let cwd = "/tmp/restart-live-agent"
        let sessionId = "session-restart-live-agent"
        let transcript = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        try writeFile(populatedTranscript, to: transcript)
        let snapshot = try #require(snapshotOutcomeValue(
            from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: sessionId, workingDirectory: cwd),
                homeDirectory: home.path,
                snapshotDirectory: snapshots,
                recoveryMetadataOwnerProcessIdentity: nil
            )
        ))

        let agentProcess = Process()
        agentProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        agentProcess.arguments = ["30"]
        try agentProcess.run()
        defer {
            if agentProcess.isRunning {
                agentProcess.terminate()
                agentProcess.waitUntilExit()
            }
        }
        let processIdentity = try #require(AgentPIDProcessIdentity(pid: agentProcess.processIdentifier))
        var metadata = try recoveryMetadataJSON(atPath: snapshot.snapshotPath)
        metadata["guardedProcesses"] = [[
            "processId": Int(processIdentity.pid),
            "processStartSeconds": processIdentity.startSeconds,
            "processStartMicroseconds": processIdentity.startMicroseconds,
        ]]
        try setRecoveryMetadata(try JSONSerialization.data(withJSONObject: metadata), atPath: snapshot.snapshotPath)
        try metadataStub.write(to: transcript, atomically: true, encoding: .utf8)

        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(snapshotDirectory: snapshots) == 0)
        #expect(FileManager.default.fileExists(atPath: snapshot.snapshotPath))

        agentProcess.terminate()
        agentProcess.waitUntilExit()
        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(snapshotDirectory: snapshots) == 1)
        #expect(
            try String(contentsOf: transcript, encoding: .utf8) ==
                expectedRestoredTranscript(snapshotContent: populatedTranscript)
        )
    }

    @Test
    func restartRecoveryDoesNotTrustSpoofableFileVersionMetadata() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let cwd = "/tmp/restart-version-spoof"
        let sessionId = "session-restart-version-spoof"
        let transcript = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        try writeFile(populatedTranscript, to: transcript)
        let snapshot = try #require(snapshotOutcomeValue(
            from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: sessionId, workingDirectory: cwd),
                homeDirectory: home.path,
                snapshotDirectory: snapshots,
                recoveryMetadataOwnerProcessIdentity: nil
            )
        ))
        let originalVersion = try #require(snapshot.liveFileVersion)
        let divergentSameSize = populatedTranscript.replacingOccurrences(of: "hello", with: "jello")
        #expect(divergentSameSize.utf8.count == populatedTranscript.utf8.count)
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(divergentSameSize.utf8))
        try handle.truncate(atOffset: UInt64(divergentSameSize.utf8.count))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: originalVersion.modificationDate],
            ofItemAtPath: transcript.path
        )

        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(snapshotDirectory: snapshots) == 0)
        #expect(try String(contentsOf: transcript, encoding: .utf8) == divergentSameSize)
        #expect(try String(contentsOfFile: snapshot.snapshotPath, encoding: .utf8) == populatedTranscript)
    }

    @Test
    func restartRecoveryUsesAnInterprocessDirectoryLock() throws {
        let home = try temporaryDirectory()
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let cwd = "/tmp/restart-directory-lock"
        let sessionId = "session-restart-directory-lock"
        let transcript = transcriptURL(home: home, cwd: cwd, sessionId: sessionId)
        try writeFile(populatedTranscript, to: transcript)
        let snapshot = try #require(snapshotOutcomeValue(
            from: AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: agent(sessionId: sessionId, workingDirectory: cwd),
                homeDirectory: home.path,
                snapshotDirectory: snapshots,
                recoveryMetadataOwnerProcessIdentity: nil
            )
        ))
        try metadataStub.write(to: transcript, atomically: true, encoding: .utf8)

        let lockPath = snapshots.appendingPathComponent(".agent-transcript-recovery.lock").path
        let lockDescriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        #expect(lockDescriptor >= 0)
        defer { if lockDescriptor >= 0 { close(lockDescriptor) } }
        #expect(flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0)

        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(snapshotDirectory: snapshots) == 0)
        #expect(FileManager.default.fileExists(atPath: snapshot.snapshotPath))

        #expect(flock(lockDescriptor, LOCK_UN) == 0)
        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(snapshotDirectory: snapshots) == 1)
        #expect(
            try String(contentsOf: transcript, encoding: .utf8) ==
                expectedRestoredTranscript(snapshotContent: populatedTranscript)
        )
    }

    @Test
    func restartRecoveryPreservesOlderDivergentSnapshotAfterRestoringNewest() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionId = "restart-divergent-older"
        let live = directory.appendingPathComponent("live.jsonl")
        let older = directory.appendingPathComponent("\(sessionId)-older.jsonl")
        let newest = directory.appendingPathComponent("\(sessionId)-newest.jsonl")
        let olderBranch = [
            #"{"type":"user","message":{"role":"user","content":"older branch"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":"older answer"}}"#,
        ].joined(separator: "\n") + "\n"
        try metadataStub.write(to: live, atomically: true, encoding: .utf8)
        try olderBranch.write(to: older, atomically: true, encoding: .utf8)
        try populatedTranscript.write(to: newest, atomically: true, encoding: .utf8)
        try setRecoveryMetadata(
            recoveryMetadataData(
                sessionId: sessionId,
                transcriptPath: live.path,
                snapshotPath: older.path,
                capturedAt: Date(timeIntervalSinceNow: -60)
            ),
            atPath: older.path
        )
        try setRecoveryMetadata(
            recoveryMetadataData(
                sessionId: sessionId,
                transcriptPath: live.path,
                snapshotPath: newest.path,
                capturedAt: Date()
            ),
            atPath: newest.path
        )

        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(snapshotDirectory: directory) == 1)
        #expect(
            try String(contentsOf: live, encoding: .utf8) ==
                expectedRestoredTranscript(snapshotContent: populatedTranscript)
        )
        #expect(FileManager.default.fileExists(atPath: newest.path) == false)
        #expect(try String(contentsOf: older, encoding: .utf8) == olderBranch)
    }

    @Test
    func restartRecoveryUsesAppendAncestryAcrossClockRollback() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionId = "restart-clock-rollback"
        let live = directory.appendingPathComponent("live.jsonl")
        let prefix = directory.appendingPathComponent("\(sessionId)-prefix.jsonl")
        let appendSuperset = directory.appendingPathComponent("\(sessionId)-superset.jsonl")
        let laterTurn = #"{"type":"assistant","message":{"role":"assistant","content":"after rollback"}}"# + "\n"
        let supersetContent = populatedTranscript + laterTurn
        try metadataStub.write(to: live, atomically: true, encoding: .utf8)
        try populatedTranscript.write(to: prefix, atomically: true, encoding: .utf8)
        try supersetContent.write(to: appendSuperset, atomically: true, encoding: .utf8)

        let apparentNewerDate = Date()
        let rolledBackDate = apparentNewerDate.addingTimeInterval(-3_600)
        try setRecoveryMetadata(
            recoveryMetadataData(
                sessionId: sessionId,
                transcriptPath: live.path,
                snapshotPath: prefix.path,
                capturedAt: apparentNewerDate
            ),
            atPath: prefix.path
        )
        try setRecoveryMetadata(
            recoveryMetadataData(
                sessionId: sessionId,
                transcriptPath: live.path,
                snapshotPath: appendSuperset.path,
                capturedAt: rolledBackDate
            ),
            atPath: appendSuperset.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: rolledBackDate],
            ofItemAtPath: appendSuperset.path
        )

        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(
            snapshotDirectory: directory
        ) == 1)
        #expect(
            try String(contentsOf: live, encoding: .utf8)
                == expectedRestoredTranscript(snapshotContent: supersetContent)
        )
        #expect(!FileManager.default.fileExists(atPath: prefix.path))
        #expect(!FileManager.default.fileExists(atPath: appendSuperset.path))
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
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let pointer = try #require(entries.first {
            $0.lastPathComponent.contains("-pointer-")
        })
        let displaced = try #require(entries.first {
            $0.lastPathComponent.hasPrefix(".live.jsonl.cmux-recovery-")
        })
        #expect(try String(contentsOf: displaced, encoding: .utf8) == metadataStub)
        let pointerMetadata = try recoveryMetadataJSON(atPath: pointer.path)
        let displacedMetadata = try recoveryMetadataJSON(atPath: displaced.path)
        #expect(
            NSDictionary(dictionary: pointerMetadata)
                .isEqual(to: displacedMetadata)
        )
    }

    @Test
    func restoreIfClobberedRestoresZeroByteInPlaceTruncation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        try Data().write(to: live)
        try populatedTranscript.write(to: snapshot, atomically: true, encoding: .utf8)

        #expect(AgentHibernationTranscriptGuard.restoreIfClobbered(
            .init(transcriptPath: live.path, snapshotPath: snapshot.path)
        ))
        #expect(try String(contentsOf: live, encoding: .utf8) == populatedTranscript)
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
    func restoreIfClobberedCompletesProtectedAppendPrefix() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let protectedPrefix = [
            #"{"type":"summary","summary":"Session"}"#,
            #"{"type":"user","message":{"role":"user","content":"hello"}}"#,
        ].joined(separator: "\n") + "\n"
        let protected = protectedPrefix
            + #"{"type":"assistant","message":{"role":"assistant","content":"hi"}}"#
            + "\n"
        try protectedPrefix.write(to: live, atomically: true, encoding: .utf8)
        try protected.write(to: snapshot, atomically: true, encoding: .utf8)

        #expect(AgentHibernationTranscriptGuard.restoreIfClobbered(
            .init(transcriptPath: live.path, snapshotPath: snapshot.path)
        ))
        #expect(try String(contentsOf: live, encoding: .utf8) == protected)
    }

    @Test
    func restoreIfClobberedPreservesSameSizeDivergentLiveTranscript() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let divergent = populatedTranscript.replacingOccurrences(of: "hello", with: "jello")
        #expect(divergent.utf8.count == populatedTranscript.utf8.count)
        try divergent.write(to: live, atomically: true, encoding: .utf8)
        try populatedTranscript.write(to: snapshot, atomically: true, encoding: .utf8)

        #expect(!AgentHibernationTranscriptGuard.restoreIfClobbered(
            .init(transcriptPath: live.path, snapshotPath: snapshot.path)
        ))
        #expect(try String(contentsOf: live, encoding: .utf8) == divergent)
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

    private func expectedRestoredTranscript(snapshotContent: String) -> String {
        snapshotContent.trimmedTrailingNewlines + "\n" + metadataStub
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

    private func recoveryMetadataJSON(atPath path: String) throws -> [String: Any] {
        let metadataName = "com.cmux.agent-transcript-recovery"
        let byteCount = getxattr(path, metadataName, nil, 0, 0, 0)
        guard byteCount > 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        var data = Data(count: byteCount)
        let bytesRead = data.withUnsafeMutableBytes { buffer in
            getxattr(path, metadataName, buffer.baseAddress, buffer.count, 0, 0)
        }
        guard bytesRead == byteCount,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    private func setRecoveryMetadata(_ data: Data, atPath path: String) throws {
        let result = data.withUnsafeBytes { buffer in
            setxattr(
                path,
                "com.cmux.agent-transcript-recovery",
                buffer.baseAddress,
                buffer.count,
                0,
                0
            )
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func recoveryMetadataData(
        sessionId: String,
        transcriptPath: String,
        snapshotPath: String,
        capturedAt: Date
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "sessionId": sessionId,
            "transcriptPath": transcriptPath,
            "snapshotPath": snapshotPath,
            "capturedAt": capturedAt.timeIntervalSinceReferenceDate,
        ], options: [.sortedKeys])
    }

    private func externalStagingMetadataData(
        sessionId: String,
        transcriptPath: String,
        candidateId: String,
        state: String,
        externalPath: String,
        externalDevice: UInt64? = nil,
        externalFileNumber: UInt64? = nil
    ) throws -> Data {
        var object: [String: Any] = [
            "version": 2,
            "sessionId": sessionId,
            "transcriptPath": transcriptPath,
            "candidateId": candidateId,
            "candidateState": state,
            "externalCandidatePath": externalPath,
            "capturedAt": Date().timeIntervalSinceReferenceDate,
            "guardedProcesses": [],
            "hasUncapturedGuardedProcesses": false,
        ]
        if let externalDevice { object["externalFileDevice"] = externalDevice }
        if let externalFileNumber { object["externalFileNumber"] = externalFileNumber }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func canonicalTranscriptRecord(
        sessionID: String,
        transcriptPath: String,
        updatedAt: TimeInterval
    ) throws -> CmuxAgentSessionRegistry.Record {
        let json = try JSONSerialization.data(withJSONObject: [
            "sessionId": sessionID,
            "transcriptPath": transcriptPath,
            "updatedAt": updatedAt,
        ], options: [.sortedKeys])
        return CmuxAgentSessionRegistry.Record(
            provider: "claude",
            sessionID: sessionID,
            updatedAt: updatedAt,
            json: json
        )
    }

    private func writeTranscriptLegacyProjection(
        records: [CmuxAgentSessionRegistry.Record],
        to url: URL
    ) throws {
        var sessions: [String: Any] = [:]
        for record in records {
            sessions[record.sessionID] = try JSONSerialization.jsonObject(with: record.json)
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "sessions": sessions,
        ], options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }

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
