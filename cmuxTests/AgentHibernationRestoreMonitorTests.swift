import Darwin
import Foundation
import os
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
    func immediatelyCompletedArmedMonitorsNeverLeaveStaleRegistryEntries() async throws {
        let controller = AgentHibernationController.shared
        defer { resetSharedHibernationState(controller) }

        let directory = try temporaryDirectory(prefix: "immediate-monitor-completion")
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<64 {
            let live = directory.appendingPathComponent("live-\(index).jsonl")
            let snapshot = directory.appendingPathComponent("snapshot-\(index).jsonl")
            try #"{"type":"user","message":{"content":"live"}}"#.appending("\n").write(
                to: live,
                atomically: true,
                encoding: .utf8
            )
            try #"{"type":"user","message":{"content":"snapshot"}}"#.appending("\n").write(
                to: snapshot,
                atomically: true,
                encoding: .utf8
            )
            #expect(controller.armPostTeardownRestoreMonitor(
                snapshot: .init(
                    transcriptPath: live.path,
                    snapshotPath: snapshot.path
                ),
                processIDs: [],
                initialRetryDelaysNanoseconds: [],
                backstopDelaysSeconds: []
            ))
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !controller.postTeardownRestoreTasksByTranscriptPath.isEmpty,
              clock.now < deadline {
            await Task.yield()
        }
        #expect(controller.postTeardownRestoreTasksByTranscriptPath.isEmpty)
    }

    @MainActor
    @Test
    func rejectedArmedMonitorCannotRunRestoreBeforeCancellationPolicyIsInstalled() async throws {
        let controller = AgentHibernationController.shared
        defer { resetSharedHibernationState(controller) }

        let directory = try temporaryDirectory(prefix: "rejected-monitor-gate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = directory.appendingPathComponent("live.jsonl")
        let occupyingSnapshot = directory.appendingPathComponent("occupying.jsonl")
        let rejectedSnapshot = directory.appendingPathComponent("rejected.jsonl")
        let metadata = #"{"type":"last-prompt","prompt":"continue"}"# + "\n"
        let rejectedContent = #"{"type":"user","message":{"content":"must not restore"}}"# + "\n"
        try metadata.write(to: live, atomically: true, encoding: .utf8)
        try rejectedContent.write(to: rejectedSnapshot, atomically: true, encoding: .utf8)
        try rejectedContent.write(to: occupyingSnapshot, atomically: true, encoding: .utf8)

        let occupyingRequestID = UUID()
        let occupyingState = AgentHibernationController.PostTeardownRestoreCancellationState()
        let occupyingTask = pendingTask()
        #expect(controller.storePostTeardownRestoreTask(
            occupyingTask,
            transcriptPath: live.path,
            requestID: occupyingRequestID,
            cancellationState: occupyingState
        ))

        #expect(controller.armPostTeardownRestoreMonitor(
            snapshot: .init(
                transcriptPath: live.path,
                snapshotPath: rejectedSnapshot.path
            ),
            processIDs: [],
            initialRetryDelaysNanoseconds: [0],
            backstopDelaysSeconds: []
        ) == false)
        for _ in 0..<32 { await Task.yield() }
        #expect(try String(contentsOf: live, encoding: .utf8) == metadata)
        #expect(controller.postTeardownRestoreTaskIsCurrent(
            transcriptPath: live.path,
            requestID: occupyingRequestID
        ))
        await controller.cancelPostTeardownRestoreTaskForReplacement(
            transcriptPath: live.path
        )
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
        // A partial rewrite kept an earlier turn but dropped the tail. The
        // protected snapshot is an append-only superset, so restore the missing
        // tail while retaining the displaced inode as recovery authority.
        try earlierTurn.write(to: live, atomically: true, encoding: .utf8)
        try snapshotContent.write(to: snapshot, atomically: true, encoding: .utf8)

        await AgentHibernationTranscriptGuard.runPostTeardownRestoreChecks(
            snapshot: .init(transcriptPath: live.path, snapshotPath: snapshot.path),
            processIDs: [],
            initialRetryDelaysNanoseconds: [0],
            backstopDelaysSeconds: [],
            snapshotDisposal: .retainForRecovery(sessionId: "forfeit-retain")
        )

        #expect(try String(contentsOf: live, encoding: .utf8) == snapshotContent)
        #expect(FileManager.default.fileExists(atPath: snapshot.path) == false)
        let recoveryEntries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let pointers = recoveryEntries.filter {
            $0.lastPathComponent.contains("-pointer-")
        }
        let displaced = recoveryEntries.filter {
            $0.lastPathComponent.hasPrefix(".live.jsonl.cmux-recovery-")
        }
        #expect(pointers.count == 1)
        #expect(displaced.count == 1)
        #expect(
            try String(
                contentsOf: #require(displaced.first),
                encoding: .utf8
            ) == earlierTurn
        )
    }

    @Test
    func normalMonitorPreservesSnapshotWhenLiveIsPopulatedButDivergent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-normal-divergence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let snapshotContent = #"{"type":"user","message":{"content":"protected"}}"# + "\n"
        let divergentContent = #"{"type":"user","message":{"content":"different history"}}"# + "\n"
        try divergentContent.write(to: live, atomically: true, encoding: .utf8)
        try snapshotContent.write(to: snapshot, atomically: true, encoding: .utf8)

        await AgentHibernationTranscriptGuard.runPostTeardownRestoreChecks(
            snapshot: .init(transcriptPath: live.path, snapshotPath: snapshot.path),
            processIDs: [],
            initialRetryDelaysNanoseconds: [0],
            backstopDelaysSeconds: []
        )

        #expect(try String(contentsOf: live, encoding: .utf8) == divergentContent)
        #expect(try String(contentsOf: snapshot, encoding: .utf8) == snapshotContent)
    }

    @Test
    func normalMonitorDeletesSnapshotWhenStableLivePrefixContainsIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-normal-prefix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let snapshotContent = #"{"type":"user","message":{"content":"protected"}}"# + "\n"
        let appendedContent = #"{"type":"assistant","message":{"content":"continued"}}"# + "\n"
        try (snapshotContent + appendedContent).write(to: live, atomically: true, encoding: .utf8)
        try snapshotContent.write(to: snapshot, atomically: true, encoding: .utf8)

        await AgentHibernationTranscriptGuard.runPostTeardownRestoreChecks(
            snapshot: .init(transcriptPath: live.path, snapshotPath: snapshot.path),
            processIDs: [],
            initialRetryDelaysNanoseconds: [0],
            backstopDelaysSeconds: []
        )

        #expect(try String(contentsOf: live, encoding: .utf8) == snapshotContent + appendedContent)
        #expect(FileManager.default.fileExists(atPath: snapshot.path) == false)
    }

    @Test
    func forfeitMonitorDeletesSnapshotWhenStableLivePrefixContainsIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-forfeit-prefix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let snapshotContent = #"{"type":"user","message":{"content":"protected"}}"# + "\n"
        let appendedContent = #"{"type":"assistant","message":{"content":"continued"}}"# + "\n"
        try (snapshotContent + appendedContent).write(to: live, atomically: true, encoding: .utf8)
        try snapshotContent.write(to: snapshot, atomically: true, encoding: .utf8)

        await AgentHibernationTranscriptGuard.runPostTeardownRestoreChecks(
            snapshot: .init(transcriptPath: live.path, snapshotPath: snapshot.path),
            processIDs: [],
            initialRetryDelaysNanoseconds: [0],
            backstopDelaysSeconds: [],
            snapshotDisposal: .retainForRecovery(sessionId: "forfeit-prefix")
        )

        #expect(FileManager.default.fileExists(atPath: snapshot.path) == false)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("forfeit-prefix-retained.jsonl").path
        ) == false)
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

    @Test
    func processWaitRejectsReusedPIDGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-pid-generation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = directory.appendingPathComponent("live.jsonl")
        let snapshotURL = directory.appendingPathComponent("snapshot.jsonl")
        let content = #"{"type":"user","message":{"content":"protected"}}"# + "\n"
        try content.write(to: live, atomically: true, encoding: .utf8)
        try content.write(to: snapshotURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let liveIdentity = try #require(
            AgentPIDProcessIdentity(pid: process.processIdentifier)
        )
        let staleIdentity = AgentPIDProcessIdentity(
            pid: liveIdentity.pid,
            startSeconds: liveIdentity.startSeconds + 1,
            startMicroseconds: liveIdentity.startMicroseconds
        )

        let clock = ContinuousClock()
        let startedAt = clock.now
        await AgentHibernationTranscriptGuard.runPostTeardownRestoreChecks(
            snapshot: .init(
                transcriptPath: live.path,
                snapshotPath: snapshotURL.path,
                guardedProcessIdentities: [staleIdentity]
            ),
            processIDs: [
                Int(liveIdentity.pid),
                -1,
                Int(Int32.max) + 1,
            ],
            initialRetryDelaysNanoseconds: [0],
            backstopDelaysSeconds: []
        )

        #expect(startedAt.duration(to: clock.now) < .seconds(1))
    }

    @Test
    func prefinishedDispatchWaitActivatesCanceledSuspendedSources() async {
        let cancellation = AgentHibernationRestoreTestFlag()
        let source = DispatchSource.makeTimerSource()
        source.setCancelHandler {
            Task { await cancellation.set() }
        }
        let waiter = AgentHibernationRestoreDispatchWait()

        // Models exit/cancellation winning before the source array is armed.
        await waiter.finish()
        await waiter.wait(for: [source])

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline, !(await cancellation.value) {
            try? await clock.sleep(for: .milliseconds(10))
        }
        let didCancel = await cancellation.value
        #expect(didCancel)
    }

    @Test
    func inPlaceTranscriptTruncationWakesRestoreWithoutTimerDelay() async throws {
        let directory = try temporaryDirectory(prefix: "truncate-wakeup")
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let protected = #"{"type":"user","message":{"content":"protected"}}"# + "\n"
        try protected.write(to: live, atomically: true, encoding: .utf8)
        try protected.write(to: snapshot, atomically: true, encoding: .utf8)

        let monitor = Task {
            await AgentHibernationTranscriptGuard.runPostTeardownRestoreChecks(
                snapshot: .init(transcriptPath: live.path, snapshotPath: snapshot.path),
                processIDs: [],
                initialRetryDelaysNanoseconds: [5_000_000_000],
                backstopDelaysSeconds: []
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        let descriptor = open(live.path, O_WRONLY | O_TRUNC | O_CLOEXEC)
        #expect(descriptor >= 0)
        if descriptor >= 0 {
            let replacement = Data(#"{"type":"last-prompt","prompt":"continue"}"#.utf8)
            _ = replacement.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress, bytes.count)
            }
            Darwin.close(descriptor)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline,
              !((try? String(contentsOf: live, encoding: .utf8)) ?? "").hasPrefix(protected) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try String(contentsOf: live, encoding: .utf8).hasPrefix(protected))
        monitor.cancel()
        await monitor.value
    }

    @Test
    func transcriptWriteStormHasGlobalComparisonBudget() async throws {
        let directory = try temporaryDirectory(prefix: "write-storm")
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let protected = #"{"type":"user","message":{"content":"protected"}}"# + "\n"
        try protected.write(to: live, atomically: true, encoding: .utf8)
        try protected.write(to: snapshot, atomically: true, encoding: .utf8)
        let clock = ContinuousClock()
        let startedAt = clock.now

        let monitor = Task {
            await AgentHibernationTranscriptGuard.runPostTeardownRestoreChecks(
                snapshot: .init(transcriptPath: live.path, snapshotPath: snapshot.path),
                processIDs: [],
                initialRetryDelaysNanoseconds: [200_000_000, 200_000_000, 200_000_000],
                backstopDelaysSeconds: [],
                maximumMutationChecksPerMonitor: 2
            )
        }
        for index in 0..<40 {
            try (protected + "{\"storm\":\(index)}\n").write(
                to: live,
                atomically: true,
                encoding: .utf8
            )
            try await Task.sleep(for: .milliseconds(10))
        }
        await monitor.value
        #expect(startedAt.duration(to: clock.now) < .seconds(2))
    }

    @Test
    func sharedRestoreSchedulerBoundsConcurrentMonitorResources() async {
        let scheduler = AgentHibernationRestoreMonitorScheduler(
            maximumConcurrentMonitors: 3
        )
        let concurrency = AgentHibernationRestoreConcurrencyProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<48 {
                group.addTask {
                    guard await scheduler.acquire() else { return }
                    await concurrency.enter()
                    try? await Task.sleep(for: .milliseconds(10))
                    await concurrency.leave()
                    scheduler.release()
                }
            }
        }

        #expect(await concurrency.maximum == 3)
        #expect(await concurrency.active == 0)
    }

    @Test
    func cancelledRestoreSchedulerWaitersDoNotConsumePermits() async throws {
        let scheduler = AgentHibernationRestoreMonitorScheduler(
            maximumConcurrentMonitors: 1
        )
        #expect(await scheduler.acquire())
        let waiters = (0..<128).map { _ in
            Task { await scheduler.acquire() }
        }
        await Task.yield()
        for waiter in waiters { waiter.cancel() }
        for waiter in waiters {
            #expect(await waiter.value == false)
        }
        scheduler.release()

        let completed = AgentHibernationRestoreTestFlag()
        let successor = Task {
            guard await scheduler.acquire() else { return }
            await completed.set()
            scheduler.release()
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline, !(await completed.value) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await completed.value)
        successor.cancel()
        await successor.value
    }

    @Test
    func processSourceCountAndOverflowAreBounded() async throws {
        let directory = try temporaryDirectory(prefix: "process-cap")
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let protected = #"{"type":"user","message":{"content":"protected"}}"# + "\n"
        try protected.write(to: live, atomically: true, encoding: .utf8)
        try protected.write(to: snapshot, atomically: true, encoding: .utf8)
        let identity = try #require(AgentPIDProcessIdentity(pid: getpid()))
        let processIDs = Set((1...300).map { Int(Int32.max) + $0 }).union([Int(getpid())])

        let monitor = Task {
            await AgentHibernationTranscriptGuard.runPostTeardownRestoreChecks(
                snapshot: .init(
                    transcriptPath: live.path,
                    snapshotPath: snapshot.path,
                    guardedProcessIdentities: [identity],
                    hasUncapturedGuardedProcesses: true
                ),
                processIDs: processIDs,
                initialRetryDelaysNanoseconds: [0],
                backstopDelaysSeconds: [],
                processExitBackstopSeconds: 1
            )
        }
        await Task.yield()
        monitor.cancel()
        await monitor.value
    }

    @Test
    func currentProcessOwnedSnapshotIsNotClaimedByStartupRecovery() throws {
        let home = try temporaryDirectory(prefix: "same-owner")
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionID = "same-owner"
        let workingDirectory = "/tmp/same-owner"
        let transcript = try writeClaudeTranscript(
            home: home,
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
        let captured = try #require(snapshotValue(
            AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: .init(
                    kind: .claude,
                    sessionId: sessionID,
                    workingDirectory: workingDirectory
                ),
                homeDirectory: home.path,
                snapshotDirectory: snapshots
            )
        ))
        try #"{"type":"last-prompt","prompt":"continue"}"#.write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )

        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(
            snapshotDirectory: snapshots
        ) == 0)
        #expect(FileManager.default.fileExists(atPath: captured.snapshotPath))
    }

    @Test
    func exhaustedMonitorRetiresOwnerAndEnqueuesImmediateRecovery() async throws {
        let home = try temporaryDirectory(prefix: "retired-owner")
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionID = "retired-owner"
        let workingDirectory = "/tmp/retired-owner"
        let transcript = try writeClaudeTranscript(
            home: home,
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
        let captured = try #require(snapshotValue(
            AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: .init(
                    kind: .claude,
                    sessionId: sessionID,
                    workingDirectory: workingDirectory
                ),
                homeDirectory: home.path,
                snapshotDirectory: snapshots
            )
        ))
        let divergentLive = [
            #"{"type":"user","message":{"content":"independent"}}"#,
            #"{"type":"assistant","message":{"content":"branch"}}"#,
        ].joined(separator: "\n") + "\n"
        try divergentLive.write(to: transcript, atomically: true, encoding: .utf8)
        let enqueued = AgentHibernationRestoreTestFlag()

        await AgentHibernationTranscriptGuard.runPostTeardownRestoreChecks(
            snapshot: captured,
            processIDs: [],
            initialRetryDelaysNanoseconds: [0],
            backstopDelaysSeconds: [],
            recoveryAuthorityRetired: { await enqueued.set() }
        )

        #expect(await enqueued.value)
        #expect(FileManager.default.fileExists(atPath: captured.snapshotPath))
        #expect(try String(contentsOf: transcript, encoding: .utf8) == divergentLive)

        let metadataStub = #"{"type":"last-prompt","prompt":"continue"}"# + "\n"
        try metadataStub.write(to: transcript, atomically: true, encoding: .utf8)
        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(
            snapshotDirectory: snapshots
        ) == 1)
        let protectedTranscript =
            #"{"type":"user","message":{"content":"protected"}}"# + "\n"
        #expect(
            try String(contentsOf: transcript, encoding: .utf8)
                == protectedTranscript + metadataStub
        )
    }

    @Test
    func oversizedTranscriptFailsHibernationBeforeCopy() throws {
        let home = try temporaryDirectory(prefix: "oversized")
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionID = "oversized"
        let workingDirectory = "/tmp/oversized"
        let transcript = try writeClaudeTranscript(
            home: home,
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
        let handle = try FileHandle(forUpdating: transcript)
        try handle.truncate(
            atOffset: AgentHibernationTranscriptGuard.maximumProtectedTranscriptBytes + 1
        )
        try handle.close()

        let outcome = AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
            agent: .init(
                kind: .claude,
                sessionId: sessionID,
                workingDirectory: workingDirectory
            ),
            homeDirectory: home.path,
            snapshotDirectory: snapshots
        )
        guard case .unableToProtect = outcome else {
            Issue.record("Expected oversized transcript to fail closed")
            return
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: snapshots.path))?.isEmpty != false)
    }

    @Test
    func guardedProcessOverflowFailsHibernationBeforeTeardown() throws {
        let home = try temporaryDirectory(prefix: "process-overflow")
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionID = "process-overflow"
        let workingDirectory = "/tmp/process-overflow"
        _ = try writeClaudeTranscript(
            home: home,
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )

        let outcome = AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
            agent: .init(
                kind: .claude,
                sessionId: sessionID,
                workingDirectory: workingDirectory
            ),
            guardedProcessIDs: [Int(getpid())],
            homeDirectory: home.path,
            snapshotDirectory: snapshots,
            maximumGuardedProcessIdentities: 0
        )
        guard case .unableToProtect = outcome else {
            Issue.record("Expected uncaptured live process to fail hibernation closed")
            return
        }
    }

    @Test
    func snapshotDirectorySymlinkFailsClosedWithoutTouchingTarget() throws {
        let home = try temporaryDirectory(prefix: "snapshot-symlink")
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent("target", isDirectory: true)
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let sentinel = target.appendingPathComponent("sentinel")
        try "keep".write(to: sentinel, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: snapshots, withDestinationURL: target)
        let sessionID = "snapshot-symlink"
        let workingDirectory = "/tmp/snapshot-symlink"
        _ = try writeClaudeTranscript(
            home: home,
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )

        let outcome = AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
            agent: .init(
                kind: .claude,
                sessionId: sessionID,
                workingDirectory: workingDirectory
            ),
            homeDirectory: home.path,
            snapshotDirectory: snapshots
        )
        guard case .unableToProtect = outcome else {
            Issue.record("Expected symlinked snapshot directory to fail closed")
            return
        }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
    }

    @Test
    func recoveryLockHardlinkIsRejectedWithoutTruncatingTarget() throws {
        let directory = try temporaryDirectory(prefix: "lock-hardlink")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        let lock = directory.appendingPathComponent(".agent-transcript-recovery.lock")
        try "do-not-truncate".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: target, to: lock)

        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(
            snapshotDirectory: directory
        ) == 0)
        #expect(try String(contentsOf: target, encoding: .utf8) == "do-not-truncate")
    }

    @Test
    func heldRecoveryLockCancellationReleasesAfterLockOwnerDrains() async throws {
        let directory = try temporaryDirectory(prefix: "held-recovery-lock")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = directory.appendingPathComponent(".agent-transcript-recovery.lock")
        let descriptor = open(
            lock.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)

        let recovery = Task {
            await AgentHibernationTranscriptGuard.recoverPendingSnapshotsAwaitingLock(
                snapshotDirectory: directory,
                cancellationCheck: { Task.isCancelled }
            )
        }
        await Task.yield()
        recovery.cancel()
        #expect(flock(descriptor, LOCK_UN) == 0)
        #expect(await recovery.value == 0)
    }

    @MainActor
    @Test
    func stopStartDefersSuccessorUntilCancelledLockOwnerDrains() async throws {
        struct State {
            var invocationCount = 0
            var firstAcquiredLock = false
            var secondAcquiredLock = false
        }
        let directory = try temporaryDirectory(prefix: "recovery-stop-start")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("recovery.lock")
        let state = OSAllocatedUnfairLock(initialState: State())
        let firstStarted = DispatchSemaphore(value: 0)
        let cancellationObserved = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let waitForSignal: @Sendable (DispatchSemaphore) async -> DispatchTimeoutResult = {
            semaphore in
            await Task.detached {
                semaphore.wait(timeout: .now() + 2)
            }.value
        }

        let coordinator = AgentHibernationStartupRecoveryCoordinator {
            cancellationCheck in
            let invocation = state.withLock { state -> Int in
                state.invocationCount += 1
                return state.invocationCount
            }
            let descriptor = open(
                lockURL.path,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
            guard descriptor >= 0 else { return 0 }
            defer { close(descriptor) }
            let acquired = flock(descriptor, LOCK_EX | LOCK_NB) == 0
            if invocation == 1 {
                state.withLock { $0.firstAcquiredLock = acquired }
                firstStarted.signal()
                while !cancellationCheck() { _ = sched_yield() }
                cancellationObserved.signal()
                _ = releaseFirst.wait(timeout: .now() + 2)
                if acquired { _ = flock(descriptor, LOCK_UN) }
                return 0
            }
            state.withLock { $0.secondAcquiredLock = acquired }
            if acquired { _ = flock(descriptor, LOCK_UN) }
            secondFinished.signal()
            return acquired ? 1 : 0
        }

        coordinator.start()
        #expect(await waitForSignal(firstStarted) == .success)
        coordinator.stop()
        #expect(await waitForSignal(cancellationObserved) == .success)
        coordinator.start()
        #expect(coordinator.hasDeferredRecoveryForCurrentStart)
        #expect(state.withLock { $0.invocationCount } == 1)
        releaseFirst.signal()
        #expect(await waitForSignal(secondFinished) == .success)
        #expect(state.withLock { $0.firstAcquiredLock })
        #expect(state.withLock { $0.secondAcquiredLock })
        #expect(state.withLock { $0.invocationCount } == 2)
        coordinator.stop()
    }

    @Test
    func crashAfterStagedSnapshotFsyncRestoresOnStartup() throws {
        let home = try temporaryDirectory(prefix: "staged-crash")
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionID = "staged-crash"
        let workingDirectory = "/tmp/staged-crash"
        let transcript = try writeClaudeTranscript(
            home: home,
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
        let protected = try String(contentsOf: transcript, encoding: .utf8)

        let captured = try #require(snapshotValue(
            AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: .init(
                    kind: .claude,
                    sessionId: sessionID,
                    workingDirectory: workingDirectory
                ),
                homeDirectory: home.path,
                snapshotDirectory: snapshots,
                recoveryMetadataOwnerProcessIdentity: nil
            )
        ))
        let publishedURL = URL(fileURLWithPath: captured.snapshotPath)
        let stagedURL = snapshots.appendingPathComponent(
            ".\(sessionID)-capture-\(UUID().uuidString).tmp"
        )
        #expect(AgentHibernationTranscriptGuard.atomicallyRename(
            publishedURL,
            to: stagedURL
        ))
        // Occupy the canonical v2 publication name. The staged inode must be
        // publishable under an alternate name without rewriting its xattr.
        try FileManager.default.createDirectory(
            at: publishedURL,
            withIntermediateDirectories: false
        )

        try #"{"type":"last-prompt","prompt":"continue"}"#.appending("\n").write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )
        #expect(AgentHibernationTranscriptGuard.recoverPendingSnapshots(
            snapshotDirectory: snapshots
        ) == 1)
        #expect(try String(contentsOf: transcript, encoding: .utf8).hasPrefix(protected))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: snapshots.path)
                .contains(where: { $0.contains("-capture-") }) == false
        )
        #expect(FileManager.default.fileExists(atPath: publishedURL.path))
    }

    @Test
    func startupRecoveryQuarantinesInvalidHiddenCaptureAuthority() async throws {
        let directory = try temporaryDirectory(prefix: "invalid-hidden-capture")
        defer { try? FileManager.default.removeItem(at: directory) }
        let hidden = directory.appendingPathComponent(
            ".invalid-capture-\(UUID().uuidString).tmp"
        )
        try Data("not recovery metadata".utf8).write(to: hidden)

        #expect(await AgentHibernationTranscriptGuard.recoverPendingSnapshotsAwaitingLock(
            snapshotDirectory: directory
        ) == 0)
        #expect(!FileManager.default.fileExists(atPath: hidden.path))
        let quarantine = directory.appendingPathComponent(".recovery-quarantine")
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: quarantine,
            includingPropertiesForKeys: nil
        )
        #expect(quarantined.count == 1)
    }

    @Test
    func latePopulatedTranscriptWinsAtomicRestoreCAS() throws {
        let directory = try temporaryDirectory(prefix: "late-restore-writer")
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let protected = #"{"type":"user","message":{"content":"protected"}}"# + "\n"
        let metadata = #"{"type":"last-prompt","prompt":"continue"}"# + "\n"
        let lateBranch = #"{"type":"user","message":{"content":"late branch"}}"# + "\n"
        try protected.write(to: snapshot, atomically: true, encoding: .utf8)
        try metadata.write(to: live, atomically: true, encoding: .utf8)

        try lateBranch.write(to: live, atomically: true, encoding: .utf8)
        let restored = AgentHibernationTranscriptGuard.restoreIfClobbered(
            .init(transcriptPath: live.path, snapshotPath: snapshot.path)
        )

        #expect(restored == false)
        #expect(try String(contentsOf: live, encoding: .utf8) == lateBranch)
        #expect(try String(contentsOf: snapshot, encoding: .utf8) == protected)
    }

    @Test
    func writerAppendingAfterRestoreKeepsDisplacedBranchAsRecoveryCandidate() throws {
        let directory = try temporaryDirectory(prefix: "post-swap-restore-writer")
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let protected = #"{"type":"user","message":{"content":"protected"}}"# + "\n"
        let metadata = #"{"type":"last-prompt","prompt":"continue"}"# + "\n"
        let lateBranch = #"{"type":"user","message":{"content":"post-swap branch"}}"# + "\n"
        try protected.write(to: snapshot, atomically: true, encoding: .utf8)
        try metadata.write(to: live, atomically: true, encoding: .utf8)
        let liveDescriptor = open(live.path, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        #expect(liveDescriptor >= 0)
        guard liveDescriptor >= 0 else { return }
        defer { Darwin.close(liveDescriptor) }
        let restored = AgentHibernationTranscriptGuard.restoreIfClobbered(
            .init(transcriptPath: live.path, snapshotPath: snapshot.path)
        )
        #expect(restored)
        let lateData = Data(lateBranch.utf8)
        _ = lateData.withUnsafeBytes { bytes in
            Darwin.write(liveDescriptor, bytes.baseAddress, bytes.count)
        }
        let restoredContent = try String(contentsOf: live, encoding: .utf8)
        #expect(restoredContent.hasPrefix(protected))
        let recoveryEntries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let pointers = recoveryEntries.filter {
            $0.lastPathComponent.contains("-pointer-")
        }
        let displacedCandidates = recoveryEntries.filter {
            $0.lastPathComponent.hasPrefix(".live.jsonl.cmux-recovery-")
        }
        #expect(pointers.count == 1)
        #expect(displacedCandidates.count == 1)
        let displacedContent = try String(
            contentsOf: #require(displacedCandidates.first),
            encoding: .utf8
        )
        #expect(displacedContent.hasPrefix(metadata))
        #expect(displacedContent.contains("post-swap branch"))
    }

    @Test
    func restoreOutputSymlinkSwapCannotMutateReplacementTarget() throws {
        let directory = try temporaryDirectory(prefix: "restore-output-symlink")
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = directory.appendingPathComponent("live.jsonl")
        let snapshot = directory.appendingPathComponent("snapshot.jsonl")
        let sentinel = directory.appendingPathComponent("sentinel.jsonl")
        let protected = #"{"type":"user","message":{"content":"protected"}}"# + "\n"
        let metadata = #"{"type":"last-prompt","prompt":"continue"}"# + "\n"
        try protected.write(to: snapshot, atomically: true, encoding: .utf8)
        try metadata.write(to: live, atomically: true, encoding: .utf8)
        try "do-not-mutate".write(to: sentinel, atomically: true, encoding: .utf8)

        let restoreOutput = directory.appendingPathComponent("restore-output.jsonl")
        try FileManager.default.createSymbolicLink(
            at: restoreOutput,
            withDestinationURL: sentinel
        )
        #expect(throws: (any Error).self) {
            try AgentHibernationTranscriptGuard.appendLiveStubIfPresent(
                from: live,
                toRestoreFile: restoreOutput,
                fileManager: .default
            )
        }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "do-not-mutate")
        #expect(try String(contentsOf: live, encoding: .utf8) == metadata)
    }

    @Test
    func startupRecoveryContinuesPastFirstDirectoryBatch() async throws {
        let home = try temporaryDirectory(prefix: "startup-continuation")
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for index in 0..<1_100 {
            try Data().write(to: snapshots.appendingPathComponent("filler-\(index)"))
        }
        let sessionID = "startup-continuation"
        let workingDirectory = "/tmp/startup-continuation"
        let transcript = try writeClaudeTranscript(
            home: home,
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
        let protected = try String(contentsOf: transcript, encoding: .utf8)
        let captured = try #require(snapshotValue(
            AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: .init(
                    kind: .claude,
                    sessionId: sessionID,
                    workingDirectory: workingDirectory
                ),
                homeDirectory: home.path,
                snapshotDirectory: snapshots,
                maximumRecoveryStorageFileCount: 20_000,
                recoveryMetadataOwnerProcessIdentity: nil
            )
        ))
        #expect(FileManager.default.fileExists(atPath: captured.snapshotPath))
        try #"{"type":"mode","mode":"default"}"#.appending("\n").write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )

        let restoredCount = await AgentHibernationTranscriptGuard.recoverPendingSnapshotsAwaitingLock(
            snapshotDirectory: snapshots
        )
        #expect(restoredCount == 1)
        #expect(try String(contentsOf: transcript, encoding: .utf8).hasPrefix(protected))
    }

    @Test
    func startupRecoveryChoosesNewestTranscriptAcrossDirectoryBatches() async throws {
        let home = try temporaryDirectory(prefix: "startup-global-newest")
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionID = "startup-global-newest"
        let workingDirectory = "/tmp/startup-global-newest"
        let transcript = try writeClaudeTranscript(
            home: home,
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
        let olderContent = try String(contentsOf: transcript, encoding: .utf8)
        _ = try #require(snapshotValue(
            AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: .init(
                    kind: .claude,
                    sessionId: sessionID,
                    workingDirectory: workingDirectory
                ),
                homeDirectory: home.path,
                snapshotDirectory: snapshots,
                maximumRecoveryStorageFileCount: 20_000,
                recoveryMetadataOwnerProcessIdentity: nil
            )
        ))
        for index in 0..<1_100 {
            try Data().write(to: snapshots.appendingPathComponent("filler-\(index)"))
        }
        let newerContent = olderContent
            + #"{"type":"assistant","message":{"content":"newest across batch"}}"#
            + "\n"
        try newerContent.write(to: transcript, atomically: true, encoding: .utf8)
        _ = try #require(snapshotValue(
            AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: .init(
                    kind: .claude,
                    sessionId: sessionID,
                    workingDirectory: workingDirectory
                ),
                homeDirectory: home.path,
                snapshotDirectory: snapshots,
                maximumRecoveryStorageFileCount: 20_000,
                recoveryMetadataOwnerProcessIdentity: nil
            )
        ))
        try #"{"type":"mode","mode":"default"}"#.appending("\n").write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )

        #expect(await AgentHibernationTranscriptGuard.recoverPendingSnapshotsAwaitingLock(
            snapshotDirectory: snapshots
        ) == 1)
        #expect(try String(contentsOf: transcript, encoding: .utf8).hasPrefix(newerContent))
    }

    @Test
    func startupRecoveryMakesDurableProgressPastLaunchEntryCap() async throws {
        let home = try temporaryDirectory(prefix: "startup-entry-cap")
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for index in 0..<16_500 {
            try Data().write(to: snapshots.appendingPathComponent("filler-\(index)"))
        }
        let sessionID = "startup-entry-cap"
        let workingDirectory = "/tmp/startup-entry-cap"
        let transcript = try writeClaudeTranscript(
            home: home,
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
        let protected = try String(contentsOf: transcript, encoding: .utf8)
        _ = try #require(snapshotValue(
            AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: .init(
                    kind: .claude,
                    sessionId: sessionID,
                    workingDirectory: workingDirectory
                ),
                homeDirectory: home.path,
                snapshotDirectory: snapshots,
                maximumRecoveryStorageFileCount: 20_000,
                recoveryMetadataOwnerProcessIdentity: nil
            )
        ))
        try #"{"type":"mode","mode":"default"}"#.appending("\n").write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )

        #expect(await AgentHibernationTranscriptGuard
            .recoverPendingSnapshotsAwaitingLock(snapshotDirectory: snapshots) == 1)
        #expect(try String(contentsOf: transcript, encoding: .utf8).hasPrefix(protected))
    }

    @Test
    func quarantinePruningExaminesAtMostOneBoundedBatch() throws {
        let home = try temporaryDirectory(prefix: "bounded-quarantine")
        let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
        let quarantine = snapshots.appendingPathComponent(".recovery-quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for index in 0..<1_200 {
            try Data([0]).write(to: quarantine.appendingPathComponent("invalid-\(index).jsonl"))
        }
        let sessionID = "bounded-quarantine"
        let workingDirectory = "/tmp/bounded-quarantine"
        _ = try writeClaudeTranscript(
            home: home,
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )

        _ = AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
            agent: .init(
                kind: .claude,
                sessionId: sessionID,
                workingDirectory: workingDirectory
            ),
            homeDirectory: home.path,
            snapshotDirectory: snapshots
        )

        let remaining = try FileManager.default.contentsOfDirectory(atPath: quarantine.path).count
        #expect(remaining == 176)
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

    private func temporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-hibernation-\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeClaudeTranscript(
        home: URL,
        workingDirectory: String,
        sessionID: String
    ) throws -> URL {
        let transcript = home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(
                RestorableAgentSessionIndex.encodeClaudeProjectDir(workingDirectory),
                isDirectory: true
            )
            .appendingPathComponent("\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"type":"user","message":{"content":"protected"}}"#.appending("\n").write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )
        return transcript
    }

    private func snapshotValue(
        _ outcome: AgentHibernationTranscriptGuard.TeardownSnapshotOutcome
    ) -> AgentHibernationTranscriptGuard.TeardownTranscriptSnapshot? {
        guard case .snapshot(let snapshot) = outcome else { return nil }
        return snapshot
    }

    @MainActor
    private func resetSharedHibernationState(_ controller: AgentHibernationController) {
        controller.cancelPostTeardownRestoreTasks()
    }
}

private actor AgentHibernationRestoreTestFlag {
    private(set) var value = false

    func set() {
        value = true
    }
}

private actor AgentHibernationRestoreConcurrencyProbe {
    private(set) var active = 0
    private(set) var maximum = 0

    func enter() {
        active += 1
        maximum = max(maximum, active)
    }

    func leave() {
        active -= 1
    }
}
