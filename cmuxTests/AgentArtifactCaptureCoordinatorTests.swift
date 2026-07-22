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
        let artifact = ChatArtifactIndexedReference(
            path: path,
            provenance: .created,
            lastReferencedSeq: 1
        )
        return AgentChatArtifactIndex.Snapshot(
            referencedPaths: [path],
            artifacts: [artifact],
            generation: String(revision),
            revision: revision
        )
    }
}

private actor OutOfOrderCaptureStore: ArtifactStoring {
    private let suspendsFirstImport: Bool
    private var firstImportStarted: CheckedContinuation<Void, Never>?
    private var firstImportRelease: CheckedContinuation<Void, Never>?
    private(set) var importCount = 0

    init(suspendsFirstImport: Bool = true) {
        self.suspendsFirstImport = suspendsFirstImport
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
        .defaultValue
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
