import CmuxAgentChat
import CmuxArtifacts
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentChatArtifactIndexSafetyTests {
    @Test func cacheGenerationIncludesTranscriptIdentityAndScanLimit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("transcript.jsonl")
        let alias = root.appendingPathComponent("alias.jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        try FileManager.default.linkItem(at: transcript, to: alias)

        let index = AgentChatArtifactIndex()
        let fullSnapshot = try await index.snapshot(
            sessionID: "session",
            agentKind: .claude,
            transcriptPath: transcript.path,
            workingDirectory: root.path,
            maximumFileBytes: 4_096
        )
        let narrowSnapshot = try await index.snapshot(
            sessionID: "session",
            agentKind: .claude,
            transcriptPath: transcript.path,
            workingDirectory: root.path,
            maximumFileBytes: 2_048
        )
        let aliasSnapshot = try await index.snapshot(
            sessionID: "session",
            agentKind: .claude,
            transcriptPath: alias.path,
            workingDirectory: root.path,
            maximumFileBytes: 4_096
        )

        #expect(fullSnapshot.generation != narrowSnapshot.generation)
        #expect(fullSnapshot.generation != aliasSnapshot.generation)
    }

    @Test func oversizedTranscriptDoesNotTrustArtifactsOutsideItsCurrentTail() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("transcript.jsonl")
        let firstArtifactPath = root.appendingPathComponent("first.md").path
        let secondArtifactPath = root.appendingPathComponent("second.md").path
        let prefix = Array(repeating: String(repeating: "x", count: 80), count: 20)
        let artifactLine = try codexArtifactLine(path: firstArtifactPath)
        let initialTranscript = (prefix + [artifactLine]).joined(separator: "\n")
        try initialTranscript.write(to: transcript, atomically: true, encoding: .utf8)
        let firstArtifactOffset = (prefix.joined(separator: "\n") + "\n").utf8.count
        let index = AgentChatArtifactIndex()

        let firstSnapshot = try await index.snapshot(
            sessionID: "session",
            agentKind: .codex,
            transcriptPath: transcript.path,
            workingDirectory: root.path,
            maximumFileBytes: 512
        )
        let firstArtifact = try #require(firstSnapshot.artifacts.first)
        #expect(firstArtifact.path == firstArtifactPath)
        #expect(firstArtifact.lastReferencedSeq == firstArtifactOffset)

        let appendedPrefix = Array(repeating: String(repeating: "y", count: 80), count: 20)
        let appendedLines = appendedPrefix + [try codexArtifactLine(path: secondArtifactPath)]
        let secondArtifactOffset = initialTranscript.utf8.count
            + 1
            + appendedPrefix.joined(separator: "\n").utf8.count
            + 1
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + appendedLines.joined(separator: "\n")).utf8))
        try handle.close()
        let secondSnapshot = try await index.snapshot(
            sessionID: "session",
            agentKind: .codex,
            transcriptPath: transcript.path,
            workingDirectory: root.path,
            maximumFileBytes: 512
        )

        let artifacts = Dictionary(uniqueKeysWithValues: secondSnapshot.artifacts.map {
            ($0.path, $0.lastReferencedSeq)
        })
        #expect(artifacts[firstArtifactPath] == nil)
        #expect(artifacts[secondArtifactPath] == secondArtifactOffset)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)],
            ofItemAtPath: transcript.path
        )
        let metadataOnlySnapshot = try await index.snapshot(
            sessionID: "session",
            agentKind: .codex,
            transcriptPath: transcript.path,
            workingDirectory: root.path,
            maximumFileBytes: 512
        )
        let metadataOnlyArtifacts = Dictionary(uniqueKeysWithValues:
            metadataOnlySnapshot.artifacts.map { ($0.path, $0.lastReferencedSeq) }
        )
        #expect(metadataOnlyArtifacts[firstArtifactPath] == nil)
        #expect(metadataOnlyArtifacts[secondArtifactPath] == secondArtifactOffset)
    }

    @Test func canceledSnapshotStopsBeforeTranscriptParsing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("transcript.jsonl")
        try Data("{}\n".utf8).write(to: transcript)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AgentChatArtifactIndex().snapshot(
                sessionID: "session",
                agentKind: .claude,
                transcriptPath: transcript.path,
                workingDirectory: root.path,
                maximumFileBytes: 1_024
            )
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test func inPlaceTranscriptRewriteDropsPreviousAuthorization() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("transcript.jsonl")
        let oldArtifactPath = root.appendingPathComponent("old.md").path
        let newArtifactPath = root.appendingPathComponent("new.md").path
        let initialTranscript = try codexArtifactLine(path: oldArtifactPath)
        try Data(initialTranscript.utf8).write(to: transcript)
        let index = AgentChatArtifactIndex()

        let initialSnapshot = try await index.snapshot(
            sessionID: "session",
            agentKind: .codex,
            transcriptPath: transcript.path,
            workingDirectory: root.path,
            maximumFileBytes: 4_096
        )
        #expect(initialSnapshot.referencedPaths == [oldArtifactPath])

        let replacementTranscript = try codexArtifactLine(path: newArtifactPath)
            + "\n"
            + String(repeating: "{}\n", count: 512)
        #expect(replacementTranscript.utf8.count > initialTranscript.utf8.count)
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(replacementTranscript.utf8))
        try handle.close()

        let replacementSnapshot = try await index.snapshot(
            sessionID: "session",
            agentKind: .codex,
            transcriptPath: transcript.path,
            workingDirectory: root.path,
            maximumFileBytes: 4_096
        )

        #expect(replacementSnapshot.referencedPaths == [newArtifactPath])
        #expect(!replacementSnapshot.referencedPaths.contains(oldArtifactPath))
    }

    @Test func retainedArtifactAuthorizationIsBoundedByRecency() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("transcript.jsonl")
        let artifactPaths = (0...1_024).map {
            root.appendingPathComponent("artifact-\($0).md").path
        }
        let lines = try artifactPaths.map(codexArtifactLine(path:))
        try Data(lines.joined(separator: "\n").utf8).write(to: transcript)

        let snapshot = try await AgentChatArtifactIndex().snapshot(
            sessionID: "session",
            agentKind: .codex,
            transcriptPath: transcript.path,
            workingDirectory: root.path,
            maximumFileBytes: 4 * 1024 * 1024
        )

        #expect(snapshot.artifacts.count == 1_024)
        #expect(snapshot.referencedPaths.count == 1_024)
        #expect(snapshot.referencedPaths.contains(try #require(artifactPaths.last)))
        #expect(!snapshot.referencedPaths.contains(try #require(artifactPaths.first)))
    }

    @Test func laterReadDoesNotReuseEarlierMutationAuthorization() async throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let externalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: projectRoot)
            try? FileManager.default.removeItem(at: externalRoot)
        }
        let artifact = externalRoot.appendingPathComponent("private.md")
        try "generated".write(to: artifact, atomically: true, encoding: .utf8)
        let transcript = projectRoot.appendingPathComponent("transcript.jsonl")
        let createdLines = try codexCommandLines(
            command: "true > \(artifact.path)",
            callID: "create"
        )
        try createdLines.joined(separator: "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        let index = AgentChatArtifactIndex()
        let store = OutOfOrderCaptureStore(suspendsFirstImport: false)
        let coordinator = AgentArtifactCaptureCoordinator(
            captureService: ArtifactCaptureService(store: store)
        )
        let record = AgentChatSessionRecord(
            sessionID: "session",
            agentKind: .codex,
            workspaceID: "workspace",
            surfaceID: nil,
            workingDirectory: projectRoot.path,
            workingDirectoryAuthority: .hook,
            transcriptPath: transcript.path,
            state: .idle,
            lastActivityAt: .now,
            title: nil,
            pid: nil
        )

        let created = try await index.snapshot(
            sessionID: record.sessionID,
            agentKind: record.agentKind,
            transcriptPath: transcript.path,
            workingDirectory: record.workingDirectory
        )
        await coordinator.capture(record: record, snapshot: created)
        try "unrelated private contents".write(
            to: artifact,
            atomically: true,
            encoding: .utf8
        )
        let readLines = try codexCommandLines(
            command: "cat \(artifact.path)",
            callID: "read"
        )
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + readLines.joined(separator: "\n")).utf8))
        try handle.close()
        let read = try await index.snapshot(
            sessionID: record.sessionID,
            agentKind: record.agentKind,
            transcriptPath: transcript.path,
            workingDirectory: record.workingDirectory
        )

        await coordinator.capture(record: record, snapshot: read)

        #expect(await store.importCount == 1)
        #expect(await store.importedPaths == [artifact.path])
    }

    @Test func captureContinuationPreservesAnOlderUnprocessedAuthorization() async throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let externalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: projectRoot)
            try? FileManager.default.removeItem(at: externalRoot)
        }
        let first = externalRoot.appendingPathComponent("first.md")
        let delayed = externalRoot.appendingPathComponent("delayed.md")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "delayed".write(to: delayed, atomically: true, encoding: .utf8)
        let store = OutOfOrderCaptureStore(
            suspendsFirstImport: false,
            maximumFilesPerCapture: 1
        )
        let coordinator = AgentArtifactCaptureCoordinator(
            captureService: ArtifactCaptureService(store: store)
        )
        let record = AgentChatSessionRecord(
            sessionID: "session",
            agentKind: .codex,
            workspaceID: "workspace",
            surfaceID: nil,
            workingDirectory: projectRoot.path,
            workingDirectoryAuthority: .hook,
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: .now,
            title: nil,
            pid: nil
        )
        let snapshot = AgentChatArtifactIndex.Snapshot(
            referencedPaths: [first.path, delayed.path],
            artifacts: [
                ChatArtifactIndexedReference(
                    path: first.path,
                    provenance: .created,
                    lastReferencedSeq: 50,
                    captureAuthorization: .created(sequence: 50)
                ),
                ChatArtifactIndexedReference(
                    path: delayed.path,
                    provenance: .created,
                    lastReferencedSeq: 100,
                    captureAuthorization: .created(sequence: 1)
                ),
            ],
            generation: "generation",
            revision: 1,
            transcriptLineage: "lineage",
            transcriptExtent: 101
        )

        let firstProgress = await coordinator.capture(record: record, snapshot: snapshot)
        let secondProgress = await coordinator.capture(record: record, snapshot: snapshot)

        #expect(firstProgress == .needsContinuation)
        #expect(secondProgress == .complete)
        #expect(await store.importedPaths == [first.path, delayed.path])
    }

    @Test func fragmentedTranscriptRetainsABoundedLineIndex() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("fragmented.jsonl")
        let data = Data(Array(repeating: "{}\n", count: 20_000).joined().utf8)
        try data.write(to: transcript)
        let handle = try FileHandle(forReadingFrom: transcript)
        defer { try? handle.close() }

        let slice = try AgentChatTranscriptReader().read(
            handle: handle,
            fileSize: UInt64(data.count),
            maximumBytes: UInt64(data.count)
        )

        #expect(slice.lineStartOffsets.count <= 16_384)
        #expect(slice.data.count < data.count)
    }

    @Test func oversizedPrefixRewriteDropsRetainedArtifactAuthority() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("transcript.jsonl")
        let removedArtifact = root.appendingPathComponent("removed.md").path
        let retainedArtifact = root.appendingPathComponent("retained.md").path
        let createdLines = try codexCommandLines(
            command: "true > \(removedArtifact)",
            callID: "create"
        )
        let initialTranscript = createdLines.joined(separator: "\n")
        try initialTranscript.write(to: transcript, atomically: true, encoding: .utf8)
        let index = AgentChatArtifactIndex()
        let initial = try await index.snapshot(
            sessionID: "session",
            agentKind: .codex,
            transcriptPath: transcript.path,
            workingDirectory: root.path,
            maximumFileBytes: 1_024
        )
        #expect(initial.artifacts.first?.captureAuthorization != nil)

        let appendedLines = Array(repeating: "{}", count: 256)
            + [try codexArtifactLine(path: retainedArtifact)]
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + appendedLines.joined(separator: "\n")).utf8))
        try handle.close()
        let appended = try await index.snapshot(
            sessionID: "session",
            agentKind: .codex,
            transcriptPath: transcript.path,
            workingDirectory: root.path,
            maximumFileBytes: 1_024
        )
        #expect(appended.referencedPaths.contains(removedArtifact))

        let rewrite = try FileHandle(forWritingTo: transcript)
        try rewrite.seek(toOffset: 0)
        try rewrite.write(contentsOf: Data(repeating: 0x20, count: initialTranscript.utf8.count))
        try rewrite.close()
        let rewritten = try await index.snapshot(
            sessionID: "session",
            agentKind: .codex,
            transcriptPath: transcript.path,
            workingDirectory: root.path,
            maximumFileBytes: 1_024
        )

        #expect(!rewritten.referencedPaths.contains(removedArtifact))
        #expect(!rewritten.artifacts.contains { $0.path == removedArtifact })
        #expect(rewritten.referencedPaths.contains(retainedArtifact))
    }

    private func codexArtifactLine(path: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "timestamp": "2026-07-21T12:00:00.000Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [["type": "output_text", "text": "Saved artifact to \(path)"]],
            ],
        ])
        return String(decoding: data, as: UTF8.self)
    }

    private func codexCommandLines(command: String, callID: String) throws -> [String] {
        [
            try codexLine(type: "response_item", payload: [
                "type": "function_call",
                "name": "exec_command",
                "arguments": json(["cmd": command]),
                "call_id": callID,
            ]),
            try codexLine(type: "response_item", payload: [
                "type": "function_call_output",
                "call_id": callID,
                "output": "Process exited with code 0\nOutput:\n",
            ]),
        ]
    }

    private func codexLine(type: String, payload: [String: Any]) throws -> String {
        try json([
            "timestamp": "2026-07-21T12:00:00.000Z",
            "type": type,
            "payload": payload,
        ])
    }

    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
