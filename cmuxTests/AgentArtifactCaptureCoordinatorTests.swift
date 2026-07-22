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
    @Test func oneCaptureRequestDoesNotDrainPolicyBacklog() async throws {
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let store = OutOfOrderCaptureStore(
            suspendsFirstImport: false,
            maximumFilesPerCapture: 1
        )
        let coordinator = AgentArtifactCaptureCoordinator(
            captureService: ArtifactCaptureService(store: store)
        )
        let record = captureRecord(projectRoot: projectRoot)
        let snapshot = snapshot(
            revision: 1,
            artifacts: (1...3).map { index in
                (projectRoot.appendingPathComponent("artifact-\(index).md").path, index)
            }
        )

        await coordinator.capture(record: record, snapshot: snapshot)

        #expect(await store.importedPaths.count == 1)
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
    @Test func removedAndReusedSessionIDCapturesTheSameRevisionAgain() async throws {
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let store = OutOfOrderCaptureStore(suspendsFirstImport: false)
        let coordinator = AgentArtifactCaptureCoordinator(
            captureService: ArtifactCaptureService(store: store)
        )
        let registry = AgentChatSessionRegistry()
        let service = AgentChatTranscriptService(
            registry: registry,
            artifactCaptureCoordinator: coordinator
        )
        let surfaceID = UUID().uuidString
        let workspaceID = UUID().uuidString
        let pendingSessionID = AgentChatSessionRegistry.pendingClaudeSessionID(
            surfaceID: surfaceID
        )
        registry.noteResumeInitiated(
            sessionID: pendingSessionID,
            source: "claude",
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            workingDirectory: projectRoot.path
        )
        let firstRecord = try #require(registry.record(sessionID: pendingSessionID))
        let indexed = snapshot(
            revision: 1,
            path: projectRoot.appendingPathComponent("plan.md").path
        )

        service.scheduleIndexedArtifactCapture(record: firstRecord, snapshot: indexed)
        let firstTask = try #require(service.artifactCaptureTasks[pendingSessionID]?.task)
        await firstTask.value
        #expect(await store.importCount == 1)

        let realSessionID = UUID().uuidString
        registry.noteResumeInitiated(
            sessionID: realSessionID,
            source: "claude",
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            workingDirectory: projectRoot.path
        )
        _ = registry.noteHookEvent(WorkstreamEvent(
            sessionId: realSessionID,
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            cwd: projectRoot.path,
            ppid: nil
        ))
        #expect(registry.record(sessionID: pendingSessionID) == nil)

        registry.noteResumeInitiated(
            sessionID: pendingSessionID,
            source: "claude",
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            workingDirectory: projectRoot.path
        )
        let reusedRecord = try #require(registry.record(sessionID: pendingSessionID))
        service.scheduleIndexedArtifactCapture(record: reusedRecord, snapshot: indexed)
        let reusedTask = try #require(service.artifactCaptureTasks[pendingSessionID]?.task)
        await reusedTask.value

        #expect(await store.importCount == 2)
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

    @Test func automaticTranscriptSnapshotRejectsFilesOverItsByteBudget() async throws {
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let transcript = projectRoot.appendingPathComponent("transcript.jsonl")
        try Data("{}\n".utf8).write(to: transcript)

        await #expect(throws: (any Error).self) {
            _ = try await AgentChatArtifactIndex().snapshot(
                sessionID: "session",
                agentKind: .claude,
                transcriptPath: transcript.path,
                workingDirectory: projectRoot.path,
                maximumFileBytes: 2
            )
        }
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
        agentKind: ChatAgentKind = .claude
    ) -> AgentChatSessionRecord {
        AgentChatSessionRecord(
            sessionID: "session",
            agentKind: agentKind,
            workspaceID: "workspace",
            surfaceID: nil,
            workingDirectory: projectRoot.path,
            transcriptPath: nil,
            state: .idle,
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
}

private actor OutOfOrderCaptureStore: ArtifactStoring {
    private let suspendsFirstImport: Bool
    private let captureConfiguration: ArtifactCaptureConfiguration
    private var firstImportStarted: CheckedContinuation<Void, Never>?
    private var firstImportRelease: CheckedContinuation<Void, Never>?
    private(set) var importCount = 0
    private(set) var importedPaths: [String] = []

    init(
        suspendsFirstImport: Bool = true,
        maximumFilesPerCapture: Int = ArtifactCaptureConfiguration.defaultValue.maximumFilesPerCapture
    ) {
        self.suspendsFirstImport = suspendsFirstImport
        var configuration = ArtifactCaptureConfiguration.defaultValue
        configuration.maximumFilesPerCapture = maximumFilesPerCapture
        captureConfiguration = configuration
    }

    func waitUntilFirstImportStarts() async {
        guard importCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstImportStarted = continuation
        }
    }

    func releaseFirstImport() {
        firstImportRelease?.resume()
        firstImportRelease = nil
    }

    func locateProjectRoot(startingAt url: URL) -> URL {
        url
    }

    func configuration(projectRoot _: URL) -> ArtifactCaptureConfiguration {
        captureConfiguration
    }

    func snapshot(projectRoot: URL) throws -> ArtifactSnapshot {
        ArtifactSnapshot(
            projectRoot: projectRoot,
            artifactsRoot: projectRoot.appendingPathComponent(".cmux/artifacts"),
            nodes: [],
            isTruncated: false
        )
    }

    func search(projectRoot _: URL, query _: String) -> [ArtifactSearchResult] {
        []
    }

    func importFile(
        sourceURL _: URL,
        context _: ArtifactCaptureContext,
        provenance _: ArtifactProvenance,
        configuration _: ArtifactCaptureConfiguration,
        capturedAt _: Date
    ) throws -> ArtifactImportOutcome {
        .skipped(.notARegularFile)
    }

    func importFiles(
        candidates: [ArtifactCandidate],
        context _: ArtifactCaptureContext,
        configuration _: ArtifactCaptureConfiguration,
        capturedAt _: Date
    ) async -> [ArtifactImportAttempt] {
        importCount += 1
        importedPaths.append(contentsOf: candidates.map(\.sourceURL.path))
        if importCount == 1, suspendsFirstImport {
            firstImportStarted?.resume()
            firstImportStarted = nil
            await withCheckedContinuation { continuation in
                firstImportRelease = continuation
            }
        }
        return candidates.map { _ in
            .imported(.skipped(.notARegularFile))
        }
    }

    func resolve(projectRoot _: URL, name: String) throws -> ArtifactNode {
        throw ArtifactStoreError.artifactNotFound(name)
    }

    func changes(projectRoot _: URL) -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}
