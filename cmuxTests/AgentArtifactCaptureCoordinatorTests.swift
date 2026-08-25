import CMUXAgentLaunch
import CmuxAgentChat
import CmuxArtifacts
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentArtifactCaptureCoordinatorTests {
    @MainActor
    @Test func scheduledCaptureContinuesPolicyBacklogWithoutNewEvent() async throws {
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let store = OutOfOrderCaptureStore(
            suspendsFirstImport: false,
            maximumFilesPerCapture: 1
        )
        let coordinator = AgentArtifactCaptureCoordinator(
            captureService: ArtifactCaptureService(store: store)
        )
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            artifactCaptureCoordinator: coordinator
        )
        let record = captureRecord(projectRoot: projectRoot)
        let snapshot = snapshot(
            revision: 1,
            artifacts: (1...3).map { index in
                (projectRoot.appendingPathComponent("artifact-\(index).md").path, index)
            }
        )

        service.scheduleIndexedArtifactCapture(record: record, snapshot: snapshot)
        let task = try #require(service.artifactCaptureTasks[record.sessionID]?.task)
        await task.value

        #expect(await store.importedPaths.count == 3)
        #expect(await store.importCount == 3)
    }

    @Test func newerSnapshotCapturesOnlyNewTranscriptReferences() async throws {
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let store = OutOfOrderCaptureStore(suspendsFirstImport: false)
        let coordinator = AgentArtifactCaptureCoordinator(
            captureService: ArtifactCaptureService(store: store)
        )
        let record = captureRecord(projectRoot: projectRoot)
        let oldPath = projectRoot.appendingPathComponent("old.md").path
        let newPath = projectRoot.appendingPathComponent("new.md").path

        await coordinator.capture(
            record: record,
            snapshot: snapshot(revision: 1, artifacts: [(oldPath, 1)])
        )
        await coordinator.capture(
            record: record,
            snapshot: snapshot(revision: 2, artifacts: [(oldPath, 1), (newPath, 2)])
        )

        #expect(await store.importedPaths == [oldPath, newPath])
    }

    @Test func sameSizeTranscriptRewriteResetsCaptureCursor() async throws {
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let oldPath = projectRoot.appendingPathComponent("z-old.md").path
        let rewrittenPath = projectRoot.appendingPathComponent("a-new.md").path
        let store = OutOfOrderCaptureStore(suspendsFirstImport: false)
        let coordinator = AgentArtifactCaptureCoordinator(
            captureService: ArtifactCaptureService(store: store)
        )
        let record = captureRecord(projectRoot: projectRoot)
        let first = AgentChatArtifactIndex.Snapshot(
            referencedPaths: [oldPath],
            artifacts: [ChatArtifactIndexedReference(
                path: oldPath,
                provenance: .created,
                lastReferencedSeq: 1
            )],
            generation: "generation-1",
            revision: 1,
            transcriptExtent: 100
        )
        let rewritten = AgentChatArtifactIndex.Snapshot(
            referencedPaths: [rewrittenPath],
            artifacts: [ChatArtifactIndexedReference(
                path: rewrittenPath,
                provenance: .created,
                lastReferencedSeq: 1
            )],
            generation: "generation-2",
            revision: 2,
            transcriptExtent: 100
        )

        await coordinator.capture(record: record, snapshot: first)
        await coordinator.capture(record: record, snapshot: rewritten)

        #expect(await store.importedPaths == [oldPath, rewrittenPath])
    }

    @Test func skippedSourceIsRetriedWithoutAdvancingCaptureCursor() async throws {
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let source = projectRoot.appendingPathComponent("appears-later.md")
        let store = LocalArtifactRepository()
        let coordinator = AgentArtifactCaptureCoordinator(
            captureService: ArtifactCaptureService(store: store)
        )
        let record = captureRecord(projectRoot: projectRoot)
        let indexed = snapshot(revision: 1, path: source.path)

        await coordinator.capture(record: record, snapshot: indexed)
        try "now present".write(to: source, atomically: true, encoding: .utf8)
        await coordinator.capture(record: record, snapshot: indexed)

        let snapshot = try await store.snapshot(projectRoot: projectRoot)
        #expect(snapshot.nodes.flattenedArtifactNodes().contains { $0.name == source.lastPathComponent })
    }

    @Test func busyStoreDoesNotCheckpointAnAutomaticArtifact() async throws {
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let store = OutOfOrderCaptureStore(
            suspendsFirstImport: false,
            rejectsFirstImportAsBusy: true
        )
        let coordinator = AgentArtifactCaptureCoordinator(
            captureService: ArtifactCaptureService(store: store)
        )
        let record = captureRecord(projectRoot: projectRoot)
        let indexed = snapshot(
            revision: 1,
            path: projectRoot.appendingPathComponent("plan.md").path
        )

        await coordinator.capture(record: record, snapshot: indexed)
        await coordinator.capture(record: record, snapshot: indexed)

        #expect(await store.importCount == 2)
        #expect(await store.importedPaths == [projectRoot.appendingPathComponent("plan.md").path])
    }

    @Test func transcriptTruncationResetsTheCompletedReferenceCursor() async throws {
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let transcript = projectRoot.appendingPathComponent("transcript.jsonl")
        let oldPath = projectRoot.appendingPathComponent("old.md").path
        let newPath = projectRoot.appendingPathComponent("new.md").path
        try (Array(repeating: "{}", count: 20) + [codexArtifactLine(path: oldPath)])
            .joined(separator: "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        let index = AgentChatArtifactIndex()
        let store = OutOfOrderCaptureStore(suspendsFirstImport: false)
        let coordinator = AgentArtifactCaptureCoordinator(
            captureService: ArtifactCaptureService(store: store)
        )
        let record = captureRecord(projectRoot: projectRoot, agentKind: .codex)

        let first = try await index.snapshot(
            sessionID: record.sessionID,
            agentKind: record.agentKind,
            transcriptPath: transcript.path,
            workingDirectory: record.workingDirectory
        )
        await coordinator.capture(record: record, snapshot: first)
        try codexArtifactLine(path: newPath)
            .write(to: transcript, atomically: true, encoding: .utf8)
        let truncated = try await index.snapshot(
            sessionID: record.sessionID,
            agentKind: record.agentKind,
            transcriptPath: transcript.path,
            workingDirectory: record.workingDirectory
        )
        await coordinator.capture(record: record, snapshot: truncated)

        #expect(await store.importedPaths == [oldPath, newPath])
    }

    @MainActor
    @Test func sameSnapshotReplacementFinishesActiveBatchBeforePendingWork() async throws {
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let store = OutOfOrderCaptureStore(maximumFilesPerCapture: 1)
        let coordinator = AgentArtifactCaptureCoordinator(
            captureService: ArtifactCaptureService(store: store)
        )
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            artifactCaptureCoordinator: coordinator
        )
        let record = captureRecord(projectRoot: projectRoot)
        let snapshot = snapshot(
            revision: 1,
            artifacts: [
                (projectRoot.appendingPathComponent("one.md").path, 1),
                (projectRoot.appendingPathComponent("two.md").path, 2),
            ]
        )

        service.scheduleIndexedArtifactCapture(record: record, snapshot: snapshot)
        let activeTask = try #require(service.artifactCaptureTasks[record.sessionID]?.task)
        await store.waitUntilFirstImportStarts()
        service.scheduleIndexedArtifactCapture(record: record, snapshot: snapshot)
        await store.releaseFirstImport()
        await activeTask.value

        #expect(await store.importedPaths.count == 2)
    }

    @Test func sequentialStaleSnapshotDoesNotRegressCompletedGeneration() async throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        let store = OutOfOrderCaptureStore(suspendsFirstImport: false)
        let coordinator = AgentArtifactCaptureCoordinator(
            captureService: ArtifactCaptureService(store: store)
        )
        let record = AgentChatSessionRecord(
            sessionID: "session",
            agentKind: .claude,
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
        let older = snapshot(
            revision: 1,
            path: projectRoot.appendingPathComponent("older.md").path
        )
        let newer = snapshot(
            revision: 2,
            path: projectRoot.appendingPathComponent("newer.md").path
        )

        await coordinator.capture(record: record, snapshot: newer)
        await coordinator.capture(record: record, snapshot: older)
        await coordinator.capture(record: record, snapshot: newer)

        #expect(await store.importCount == 1)
    }

    @MainActor
    @Test func completedCaptureTaskIsReleased() async throws {
        let store = OutOfOrderCaptureStore(suspendsFirstImport: false)
        let coordinator = AgentArtifactCaptureCoordinator(
            captureService: ArtifactCaptureService(store: store)
        )
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            artifactCaptureCoordinator: coordinator
        )
        let record = AgentChatSessionRecord(
            sessionID: "session",
            agentKind: .claude,
            workspaceID: "workspace",
            surfaceID: nil,
            workingDirectory: FileManager.default.temporaryDirectory.path,
            workingDirectoryAuthority: .hook,
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: .now,
            title: nil,
            pid: nil
        )
        let snapshot = AgentChatArtifactIndex.Snapshot(
            referencedPaths: [],
            artifacts: [],
            generation: "empty",
            revision: 1
        )

        service.scheduleIndexedArtifactCapture(record: record, snapshot: snapshot)
        let task = try #require(service.artifactCaptureTasks[record.sessionID]?.task)
        await task.value

        #expect(service.artifactCaptureTasks[record.sessionID] == nil)
    }

    @MainActor
    @Test func automaticCaptureTracksLiveArtifactsBetaAvailability() async throws {
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let store = OutOfOrderCaptureStore(suspendsFirstImport: false)
        let coordinator = AgentArtifactCaptureCoordinator(
            captureService: ArtifactCaptureService(store: store)
        )
        var artifactsBetaEnabled = false
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            artifactCaptureCoordinator: coordinator,
            isAutomaticArtifactCaptureEnabled: { artifactsBetaEnabled }
        )
        let record = captureRecord(projectRoot: projectRoot)
        let indexed = snapshot(
            revision: 1,
            path: projectRoot.appendingPathComponent("plan.md").path
        )

        service.scheduleIndexedArtifactCapture(record: record, snapshot: indexed)
        #expect(service.artifactCaptureTasks[record.sessionID] == nil)

        artifactsBetaEnabled = true
        service.scheduleIndexedArtifactCapture(record: record, snapshot: indexed)
        let task = try #require(service.artifactCaptureTasks[record.sessionID]?.task)
        await task.value

        #expect(await store.importCount == 1)
    }

    @MainActor
    @Test func streamedProseBatchesShareOneDebouncedCapture() throws {
        let registry = AgentChatSessionRegistry()
        let sessionID = UUID().uuidString
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .userPromptSubmit,
            source: "claude",
            workspaceId: "workspace",
            surfaceId: nil,
            transcriptPath: nil,
            cwd: projectRoot.path,
            ppid: nil
        ))
        let store = OutOfOrderCaptureStore(suspendsFirstImport: false)
        let service = AgentChatTranscriptService(
            registry: registry,
            artifactCaptureCoordinator: AgentArtifactCaptureCoordinator(
                captureService: ArtifactCaptureService(store: store)
            )
        )
        let firstMessage = ChatMessage(
            id: "prose-1",
            seq: 1,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: 1),
            kind: .prose(ChatProse(text: "first chunk"))
        )
        let secondMessage = ChatMessage(
            id: "prose-2",
            seq: 2,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: 2),
            kind: .prose(ChatProse(text: "second chunk"))
        )

        service.publishBatch(
            AgentChatTranscriptTailer.Batch(
                appended: [firstMessage],
                updated: [],
                discoveredTitle: nil
            ),
            sessionID: sessionID
        )
        let firstToken = try #require(
            service.artifactCaptureDebounceTasks[sessionID]?.token
        )
        service.publishBatch(
            AgentChatTranscriptTailer.Batch(
                appended: [secondMessage],
                updated: [],
                discoveredTitle: nil
            ),
            sessionID: sessionID
        )
        let secondToken = try #require(
            service.artifactCaptureDebounceTasks[sessionID]?.token
        )

        #expect(firstToken != secondToken)
        #expect(service.artifactCaptureDebounceTasks.count == 1)
        #expect(service.artifactCaptureTasks[sessionID] == nil)
    }

    @MainActor
    @Test func lateAuthorizedToolUpdateSchedulesDebouncedCapture() throws {
        let registry = AgentChatSessionRegistry()
        let sessionID = UUID().uuidString
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .userPromptSubmit,
            source: "claude",
            workspaceId: "workspace",
            surfaceId: nil,
            transcriptPath: nil,
            cwd: projectRoot.path,
            ppid: nil
        ))
        let service = AgentChatTranscriptService(
            registry: registry,
            artifactCaptureCoordinator: AgentArtifactCaptureCoordinator(
                captureService: ArtifactCaptureService(
                    store: OutOfOrderCaptureStore(suspendsFirstImport: false)
                )
            )
        )
        let updatedTool = ChatMessage(
            id: "apply-patch",
            seq: 4,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: 4),
            kind: .toolUse(ChatToolUse(
                toolName: "apply_patch",
                summary: "apply_patch plan.md",
                status: .succeeded,
                referencedPaths: [projectRoot.appendingPathComponent("plan.md").path],
                artifactMutationAuthorized: true
            ))
        )

        service.publishBatch(
            AgentChatTranscriptTailer.Batch(
                appended: [],
                updated: [updatedTool],
                discoveredTitle: nil
            ),
            sessionID: sessionID
        )

        #expect(service.artifactCaptureDebounceTasks[sessionID] != nil)
        #expect(service.artifactCaptureTasks[sessionID] == nil)
    }

    @MainActor
    @Test func sidechainMutationAuthorizationSchedulesCaptureWithoutVisibleRow() throws {
        let registry = AgentChatSessionRegistry()
        let sessionID = UUID().uuidString
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .userPromptSubmit,
            source: "claude",
            workspaceId: "workspace",
            surfaceId: nil,
            transcriptPath: nil,
            cwd: projectRoot.path,
            ppid: nil
        ))
        let service = AgentChatTranscriptService(
            registry: registry,
            artifactCaptureCoordinator: AgentArtifactCaptureCoordinator(
                captureService: ArtifactCaptureService(
                    store: OutOfOrderCaptureStore(suspendsFirstImport: false)
                )
            )
        )

        service.publishBatch(
            AgentChatTranscriptTailer.Batch(
                appended: [],
                updated: [],
                discoveredTitle: nil,
                didAuthorizeArtifactMutation: true
            ),
            sessionID: sessionID
        )

        #expect(service.artifactCaptureDebounceTasks[sessionID] != nil)
    }

    @MainActor
    @Test func successfulReadOnlyTerminalDoesNotScheduleCapture() throws {
        let registry = AgentChatSessionRegistry()
        let sessionID = UUID().uuidString
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .userPromptSubmit,
            source: "claude",
            workspaceId: "workspace",
            surfaceId: nil,
            transcriptPath: nil,
            cwd: projectRoot.path,
            ppid: nil
        ))
        let service = AgentChatTranscriptService(
            registry: registry,
            artifactCaptureCoordinator: AgentArtifactCaptureCoordinator(
                captureService: ArtifactCaptureService(
                    store: OutOfOrderCaptureStore(suspendsFirstImport: false)
                )
            )
        )
        service.publishBatch(
            AgentChatTranscriptTailer.Batch(
                appended: [ChatMessage(
                    id: "ls",
                    seq: 1,
                    role: .agent,
                    timestamp: Date(timeIntervalSince1970: 2),
                    kind: .terminal(ChatTerminalCapture(
                        command: "ls -la",
                        output: "notes.md",
                        exitCode: 0,
                        isRunning: false
                    ))
                ],
                updated: [],
                discoveredTitle: nil
            ),
            sessionID: sessionID
        )

        #expect(service.artifactCaptureDebounceTasks[sessionID] == nil)
    }

    @MainActor
    @Test func deinitCancelsActiveAutomaticCaptureTask() async throws {
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let store = OutOfOrderCaptureStore()
        let coordinator = AgentArtifactCaptureCoordinator(
            captureService: ArtifactCaptureService(store: store)
        )
        let record = captureRecord(projectRoot: projectRoot)
        let indexed = snapshot(
            revision: 1,
            path: projectRoot.appendingPathComponent("plan.md").path
        )
        var service: AgentChatTranscriptService? = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            artifactCaptureCoordinator: coordinator
        )
        service?.scheduleIndexedArtifactCapture(record: record, snapshot: indexed)
        let captureTask = try #require(service?.artifactCaptureTasks[record.sessionID]?.task)
        await store.waitUntilFirstImportStarts()
        service = nil

        #expect(captureTask.isCancelled)
        await store.releaseFirstImport()
        await captureTask.value
    }

    @MainActor
    @Test func completedTranscriptTurnsCaptureWithoutMobileSubscribers() async throws {
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let artifact = projectRoot.appendingPathComponent("completed-plan.md")
        try "plan".write(to: artifact, atomically: true, encoding: .utf8)
        let transcript = projectRoot.appendingPathComponent("transcript.jsonl")
        try "".write(to: transcript, atomically: true, encoding: .utf8)
        let store = OutOfOrderCaptureStore(suspendsFirstImport: false)
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            hasEventSubscribers: { false },
            artifactCaptureCoordinator: AgentArtifactCaptureCoordinator(
                captureService: ArtifactCaptureService(store: store)
            )
        )
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .userPromptSubmit,
            source: "claude",
            workspaceId: "workspace",
            surfaceId: nil,
            transcriptPath: transcript.path,
            cwd: projectRoot.path,
            ppid: nil,
            receivedAt: Date(timeIntervalSince1970: 1)
        ))
        #expect(service.debugSessionDump().first?["tailer_active"] as? Bool == true)
        try claudeArtifactLine(path: artifact.path).write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )

        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .stop,
            source: "claude",
            workspaceId: "workspace",
            surfaceId: nil,
            transcriptPath: transcript.path,
            cwd: projectRoot.path,
            ppid: nil,
            receivedAt: Date(timeIntervalSince1970: 2)
        ))
        let task = try #require(service.artifactCaptureTasks[sessionID]?.task)
        await task.value

        #expect(await store.importedPaths == [artifact.path])
    }

    @Test func automaticTranscriptSnapshotRejectsFinalSymlinks() async throws {
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let target = projectRoot.appendingPathComponent("real.jsonl")
        let transcript = projectRoot.appendingPathComponent("transcript.jsonl")
        try Data("{}\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: transcript, withDestinationURL: target)

        await #expect(throws: (any Error).self) {
            _ = try await AgentChatArtifactIndex().snapshot(
                sessionID: "session",
                agentKind: .claude,
                transcriptPath: transcript.path,
                workingDirectory: projectRoot.path,
                maximumFileBytes: 1_024
            )
        }
    }

    @Test func completedCaptureProgressIsBoundedAcrossEndedSessions() async throws {
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let store = OutOfOrderCaptureStore(suspendsFirstImport: false)
        let coordinator = AgentArtifactCaptureCoordinator(
            captureService: ArtifactCaptureService(store: store)
        )
        for index in 0...64 {
            let record = captureRecord(
                projectRoot: projectRoot,
                sessionID: "ended-\(index)",
                state: .ended
            )
            let path = projectRoot.appendingPathComponent("artifact-\(index).md").path
            await coordinator.capture(
                record: record,
                snapshot: snapshot(revision: 1, artifacts: [(path, 1)])
            )
        }
        let oldest = captureRecord(projectRoot: projectRoot, sessionID: "ended-0", state: .ended)
        let oldestPath = projectRoot.appendingPathComponent("artifact-0.md").path
        await coordinator.capture(
            record: oldest,
            snapshot: snapshot(revision: 1, artifacts: [(oldestPath, 1)])
        )

        #expect(await store.importCount == 66)
    }

    @Test func olderCaptureFinishingLastDoesNotRegressCompletedGeneration() async throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        let store = OutOfOrderCaptureStore()
        let coordinator = AgentArtifactCaptureCoordinator(
            captureService: ArtifactCaptureService(store: store)
        )
        let record = AgentChatSessionRecord(
            sessionID: "session",
            agentKind: .claude,
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
        let older = snapshot(
            revision: 1,
            path: projectRoot.appendingPathComponent("older.md").path
        )
        let newer = snapshot(
            revision: 2,
            path: projectRoot.appendingPathComponent("newer.md").path
        )

        let olderTask = Task {
            await coordinator.capture(record: record, snapshot: older)
        }
        await store.waitUntilFirstImportStarts()

        await coordinator.capture(record: record, snapshot: newer)
        await store.releaseFirstImport()
        await olderTask.value

        await coordinator.capture(record: record, snapshot: newer)

        #expect(await store.importCount == 2)
    }

    private func snapshot(
        revision: UInt64,
        path: String
    ) -> AgentChatArtifactIndex.Snapshot {
        snapshot(revision: revision, artifacts: [(path, Int(revision))])
    }

    private func snapshot(
        revision: UInt64,
        artifacts: [(path: String, sequence: Int)]
    ) -> AgentChatArtifactIndex.Snapshot {
        return AgentChatArtifactIndex.Snapshot(
            referencedPaths: Set(artifacts.map(\.path)),
            artifacts: artifacts.map {
                ChatArtifactIndexedReference(
                    path: $0.path,
                    provenance: .created,
                    lastReferencedSeq: $0.sequence
                )
            },
            generation: String(revision),
            revision: revision
        )
    }

    private func temporaryProjectRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func captureRecord(
        projectRoot: URL,
        agentKind: ChatAgentKind = .claude,
        sessionID: String = "session",
        state: ChatAgentState = .idle
    ) -> AgentChatSessionRecord {
        AgentChatSessionRecord(
            sessionID: sessionID,
            agentKind: agentKind,
            workspaceID: "workspace",
            surfaceID: nil,
            workingDirectory: projectRoot.path,
            workingDirectoryAuthority: .hook,
            transcriptPath: nil,
            state: state,
            lastActivityAt: .now,
            title: nil,
            pid: nil
        )
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

    private func claudeArtifactLine(path: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "assistant",
            "isSidechain": false,
            "uuid": UUID().uuidString,
            "timestamp": "2026-07-21T12:00:00.000Z",
            "message": [
                "role": "assistant",
                "content": [[
                    "type": "tool_use",
                    "id": "write-plan",
                    "name": "Write",
                    "input": ["file_path": path, "content": "plan"],
                ]],
            ],
        ])
        return String(decoding: data, as: UTF8.self)
    }
}
