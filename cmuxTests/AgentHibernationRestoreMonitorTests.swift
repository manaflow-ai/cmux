import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct AgentHibernationRestoreMonitorTests {
    @MainActor
    @Test
    func replacementWaitsForOlderMonitorAndPreservesNewerSnapshot() async throws {
        let controller = AgentHibernationController.shared
        defer { resetSharedHibernationState(controller) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-restore-replacement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let olderSnapshot = directory.appendingPathComponent("older.jsonl")
        let newerSnapshot = directory.appendingPathComponent("newer.jsonl")
        let olderContent = #"{"type":"user","message":{"content":"before"}}"# + "\n"
        let newerContent = olderContent + #"{"type":"assistant","message":{"content":"after resume"}}"# + "\n"
        let metadataStub = #"{"type":"last-prompt","prompt":"continue"}"# + "\n"
        try newerContent.write(to: live, atomically: true, encoding: .utf8)
        try olderContent.write(to: olderSnapshot, atomically: true, encoding: .utf8)
        try newerContent.write(to: newerSnapshot, atomically: true, encoding: .utf8)

        let olderRequestID = UUID()
        let olderCancellationState = AgentHibernationController.PostTeardownRestoreCancellationState()
        let olderTask = restoreTask(
            live: live,
            snapshot: olderSnapshot,
            delays: [5_000_000_000],
            transcriptPath: live.path,
            requestID: olderRequestID,
            cancellationState: olderCancellationState
        )
        controller.storePostTeardownRestoreTask(
            olderTask,
            transcriptPath: live.path,
            requestID: olderRequestID,
            cancellationState: olderCancellationState
        )

        try metadataStub.write(to: live, atomically: true, encoding: .utf8)
        await controller.cancelPostTeardownRestoreTaskForReplacement(transcriptPath: live.path)
        #expect(olderTask.isCancelled)
        #expect(try String(contentsOf: live, encoding: .utf8) == metadataStub)

        let newerRequestID = UUID()
        let newerCancellationState = AgentHibernationController.PostTeardownRestoreCancellationState()
        let newerTask = restoreTask(
            live: live,
            snapshot: newerSnapshot,
            delays: [0],
            transcriptPath: live.path,
            requestID: newerRequestID,
            cancellationState: newerCancellationState
        )
        controller.storePostTeardownRestoreTask(
            newerTask,
            transcriptPath: live.path,
            requestID: newerRequestID,
            cancellationState: newerCancellationState
        )
        await newerTask.value

        let restoredContent = try String(contentsOf: live, encoding: .utf8)
        #expect(restoredContent.hasPrefix(newerContent))
        #expect(restoredContent.contains(#""after resume""#))
    }

    @MainActor
    @Test
    func replacingOneTranscriptMonitorLeavesOtherTranscriptMonitorRunning() async {
        let controller = AgentHibernationController.shared
        defer { resetSharedHibernationState(controller) }

        let firstPath = "/tmp/cmux-hibernation-first-\(UUID().uuidString).jsonl"
        let secondPath = "/tmp/cmux-hibernation-second-\(UUID().uuidString)/../live.jsonl"
        let firstTask = pendingTask()
        let secondTask = pendingTask()
        let firstState = AgentHibernationController.PostTeardownRestoreCancellationState()
        let secondState = AgentHibernationController.PostTeardownRestoreCancellationState()
        let firstRequestID = UUID()
        let secondRequestID = UUID()

        #expect(controller.storePostTeardownRestoreTask(
            firstTask,
            transcriptPath: firstPath,
            requestID: firstRequestID,
            cancellationState: firstState
        ))
        #expect(controller.storePostTeardownRestoreTask(
            secondTask,
            transcriptPath: secondPath,
            requestID: secondRequestID,
            cancellationState: secondState
        ))

        await controller.cancelPostTeardownRestoreTaskForReplacement(transcriptPath: secondPath)

        #expect(firstTask.isCancelled == false)
        #expect(secondTask.isCancelled)
        #expect(controller.postTeardownRestoreTaskIsCurrent(
            transcriptPath: firstPath,
            requestID: firstRequestID
        ))
        #expect(controller.postTeardownRestoreTaskIsCurrent(
            transcriptPath: secondPath,
            requestID: secondRequestID
        ) == false)
    }

    @MainActor
    @Test
    func armedForfeitMonitorRestoresClobberedTranscriptAndRefusesDuplicates() async throws {
        let controller = AgentHibernationController.shared
        defer { resetSharedHibernationState(controller) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-forfeit-arm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let snapshotContent = #"{"type":"user","message":{"content":"protected"}}"# + "\n"
        try #"{"type":"last-prompt","prompt":"continue"}"#.write(to: live, atomically: true, encoding: .utf8)
        try snapshotContent.write(to: snapshot, atomically: true, encoding: .utf8)

        #expect(controller.armPostTeardownRestoreMonitor(
            snapshot: .init(transcriptPath: live.path, snapshotPath: snapshot.path),
            processIDs: []
        ))
        #expect(controller.armPostTeardownRestoreMonitor(
            snapshot: .init(transcriptPath: live.path, snapshotPath: snapshot.path),
            processIDs: []
        ) == false)

        var restoredContent = ""
        for _ in 0..<200 {
            restoredContent = (try? String(contentsOf: live, encoding: .utf8)) ?? ""
            if restoredContent.hasPrefix(snapshotContent) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(restoredContent.hasPrefix(snapshotContent))
    }

    @MainActor
    @Test
    func bulkCancelDrainCompletesFinalRestoreBeforeNextTeardown() async throws {
        let controller = AgentHibernationController.shared
        defer { resetSharedHibernationState(controller) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-bulk-drain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let snapshotContent = #"{"type":"user","message":{"content":"protected"}}"# + "\n"
        try #"{"type":"last-prompt","prompt":"continue"}"#.write(to: live, atomically: true, encoding: .utf8)
        try snapshotContent.write(to: snapshot, atomically: true, encoding: .utf8)

        let requestID = UUID()
        let cancellationState = AgentHibernationController.PostTeardownRestoreCancellationState()
        let task = restoreTask(
            live: live,
            snapshot: snapshot,
            delays: [60_000_000_000],
            transcriptPath: live.path,
            requestID: requestID,
            cancellationState: cancellationState
        )
        #expect(controller.storePostTeardownRestoreTask(
            task,
            transcriptPath: live.path,
            requestID: requestID,
            cancellationState: cancellationState
        ))

        controller.cancelPostTeardownRestoreTasks()
        await controller.drainCancelledPostTeardownRestoreTasks()

        // The drain must not return before the cancelled monitor committed its
        // final protective restore, so a next teardown never races that write.
        #expect(try String(contentsOf: live, encoding: .utf8).hasPrefix(snapshotContent))
        #expect(controller.postTeardownRestoreTasksByTranscriptPath.isEmpty)
    }

    @Test
    func forfeitMonitorRetainsUnrestoredSnapshotWhenLiveDivergedButPopulated() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-forfeit-retain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let earlierTurn = #"{"type":"user","message":{"content":"kept"}}"# + "\n"
        let snapshotContent = earlierTurn + #"{"type":"assistant","message":{"content":"dropped tail"}}"# + "\n"
        // A partial rewrite kept an earlier turn but dropped the tail: the live
        // file is populated, so no restore fires, yet it does not contain the
        // snapshot. The forfeit disposal must retain the copy, never delete it.
        try earlierTurn.write(to: live, atomically: true, encoding: .utf8)
        try snapshotContent.write(to: snapshot, atomically: true, encoding: .utf8)

        await AgentHibernationTranscriptGuard.runPostTeardownRestoreChecks(
            snapshot: .init(transcriptPath: live.path, snapshotPath: snapshot.path),
            processIDs: [],
            initialRetryDelaysNanoseconds: [0],
            backstopDelaysSeconds: [],
            snapshotDisposal: .retainForRecovery(sessionId: "forfeit-retain")
        )

        #expect(try String(contentsOf: live, encoding: .utf8) == earlierTurn)
        #expect(FileManager.default.fileExists(atPath: snapshot.path) == false)
        let retained = directory.appendingPathComponent("forfeit-retain-retained.jsonl")
        #expect(try String(contentsOf: retained, encoding: .utf8) == snapshotContent)
    }

    @MainActor
    @Test
    func monitorKeyResolvesSymlinkedTranscriptPathAliases() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-symlink-\(UUID().uuidString)", isDirectory: true)
        let realDirectory = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let aliasDirectory = base.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: realDirectory)
        let transcript = realDirectory.appendingPathComponent("live.jsonl")
        try "{}\n".write(to: transcript, atomically: true, encoding: .utf8)

        let realKey = AgentHibernationController.postTeardownRestoreTaskKey(transcriptPath: transcript.path)
        let aliasKey = AgentHibernationController.postTeardownRestoreTaskKey(
            transcriptPath: aliasDirectory.appendingPathComponent("live.jsonl").path
        )
        #expect(realKey == aliasKey)
    }

    @Test
    func globalStopPolicyPerformsFinalRestoreWhenOwnershipDisappears() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-global-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let snapshotContent = #"{"type":"user","message":{"content":"protected"}}"# + "\n"
        try #"{"type":"last-prompt","prompt":"continue"}"#.write(to: live, atomically: true, encoding: .utf8)
        try snapshotContent.write(to: snapshot, atomically: true, encoding: .utf8)

        await AgentHibernationTranscriptGuard.runPostTeardownRestoreChecks(
            snapshot: .init(transcriptPath: live.path, snapshotPath: snapshot.path),
            processIDs: [],
            initialRetryDelaysNanoseconds: [0],
            backstopDelaysSeconds: [],
            shouldContinue: { false },
            shouldRestoreOnCancellation: { true }
        )

        #expect(try String(contentsOf: live, encoding: .utf8).hasPrefix(snapshotContent))
        #expect(FileManager.default.fileExists(atPath: snapshot.path))
    }

    @MainActor
    private func restoreTask(
        live: URL,
        snapshot: URL,
        delays: [UInt64],
        transcriptPath: String,
        requestID: UUID,
        cancellationState: AgentHibernationController.PostTeardownRestoreCancellationState
    ) -> Task<Void, Never> {
        Task.detached {
            await AgentHibernationTranscriptGuard.runPostTeardownRestoreChecks(
                snapshot: .init(transcriptPath: live.path, snapshotPath: snapshot.path),
                processIDs: [],
                initialRetryDelaysNanoseconds: delays,
                backstopDelaysSeconds: [],
                shouldContinue: {
                    await MainActor.run {
                        AgentHibernationController.shared.postTeardownRestoreTaskIsCurrent(
                            transcriptPath: transcriptPath,
                            requestID: requestID
                        )
                    }
                },
                shouldRestoreOnCancellation: {
                    await MainActor.run {
                        cancellationState.restoresSnapshotOnCancellation
                    }
                }
            )
        }
    }

    private func pendingTask() -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    @MainActor
    private func resetSharedHibernationState(_ controller: AgentHibernationController) {
        controller.cancelPostTeardownRestoreTasks()
    }
}
