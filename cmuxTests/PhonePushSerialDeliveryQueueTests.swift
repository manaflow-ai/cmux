import CmuxAuthRuntime
import CmuxPhonePush
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct PhonePushSerialDeliveryQueueTests {
    @MainActor
    @Test func inFlightOlderEventCannotCompleteAfterNewerEvent() async throws {
        let probe = FirstDeliveryGate()
        let queue = PhonePushSerialDeliveryQueue {
            await probe.deliver($0)
        }
        let first = requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000001"
        )
        let second = requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000002"
        )

        #expect(queue.enqueue(first))
        #expect(queue.enqueue(second))
        await probe.waitForCount(1)
        #expect(
            await probe.correlationIDs
                == [first.correlationID]
        )

        await probe.releaseFirst()
        await probe.waitForCount(2)
        #expect(
            await probe.correlationIDs
                == [first.correlationID, second.correlationID]
        )
    }

    @MainActor
    @Test func declaredTwoHundredEventBurstDoesNotCoalesceOrDrop() async {
        let probe = RecordingDeliveryProbe()
        let queue = PhonePushSerialDeliveryQueue {
            await probe.deliver($0)
        }
        let envelopes = (0..<200).map {
            requestEnvelope(
                correlationID: String(
                    format: "00000000-0000-4000-8000-%012d",
                    $0
                )
            )
        }

        for envelope in envelopes {
            #expect(queue.enqueue(envelope))
        }
        await probe.waitForCount(envelopes.count)

        #expect(
            await probe.correlationIDs
                == envelopes.map(\.correlationID)
        )
    }

    @MainActor
    @Test func queueIsBoundedAndReportsOverflow() {
        let queue = PhonePushSerialDeliveryQueue(
            capacity: 2,
            sender: { _ in .accepted(sent: 1, devices: 1, pruned: 0) }
        )

        #expect(queue.enqueue(requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000001"
        )))
        #expect(queue.enqueue(requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000002"
        )))
        #expect(!queue.enqueue(requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000003"
        )))
    }

    @MainActor
    @Test func saturatedQueueEvictsAStaleNotifyToPreserveDismissal() async {
        let probe = RecordingDeliveryProbe()
        let queue = PhonePushSerialDeliveryQueue(
            capacity: 2,
            startsImmediately: false,
            sender: { await probe.deliver($0) }
        )
        let oldNotify = requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000001",
            coalescingID: "notification-a"
        )
        let currentNotify = requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000002",
            coalescingID: "notification-b"
        )
        let dismiss = requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000003"
        )

        #expect(queue.enqueue(oldNotify))
        #expect(queue.enqueue(currentNotify))
        #expect(queue.enqueuePrioritizingDismiss(dismiss))
        queue.start()
        await probe.waitForCount(2)

        #expect(await probe.correlationIDs == [
            currentNotify.correlationID,
            dismiss.correlationID,
        ])
    }

    @MainActor
    @Test func saturatedDismissQueueNeverEvictsAnEarlierDismissal() {
        let queue = PhonePushSerialDeliveryQueue(
            capacity: 1,
            startsImmediately: false,
            sender: { _ in .accepted(sent: 1, devices: 1, pruned: 0) }
        )
        #expect(queue.enqueuePrioritizingDismiss(requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000001"
        )))
        #expect(!queue.enqueuePrioritizingDismiss(requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000002"
        )))
    }

    @MainActor
    @Test func cancellationClearsQueuedWorkAndStopsAfterTheInFlightEvent() async {
        let probe = FirstDeliveryGate()
        let queue = PhonePushSerialDeliveryQueue {
            await probe.deliver($0)
        }
        let first = requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000001"
        )
        let second = requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000002"
        )

        #expect(queue.enqueue(first))
        #expect(queue.enqueue(second))
        await probe.waitForCount(1)

        queue.cancelAll()
        await probe.releaseFirst()
        await queue.waitUntilIdle()

        #expect(await probe.correlationIDs == [first.correlationID])
        #expect(queue.pendingCount == 0)
    }

    @MainActor
    @Test func cancellationCannotLeaveAStaleCoalescingExemption() async {
        let probe = FirstDeliveryGate()
        let queue = PhonePushSerialDeliveryQueue {
            await probe.deliver($0)
        }
        let original = requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000001",
            coalescingID: "notification-a"
        )
        let replacement = requestEnvelope(
            correlationID: original.correlationID,
            coalescingID: "notification-a"
        )

        #expect(queue.enqueue(original))
        await probe.waitForCount(1)
        queue.cancelAll()
        #expect(queue.enqueue(replacement))
        #expect(queue.enqueue(replacement))

        await probe.releaseFirst()
        await probe.waitForCount(2)
        await queue.waitUntilIdle()

        #expect(await probe.correlationIDs == [
            original.correlationID,
            replacement.correlationID,
        ])
    }

    @MainActor
    @Test func accountSwitchDropsOldAccountWorkBeforeStartingTheQueue() async {
        let probe = RecordingDeliveryProbe()
        let queue = PhonePushSerialDeliveryQueue(
            startsImmediately: false,
            sender: { await probe.deliver($0) }
        )
        let oldAccount = requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000001",
            expectedAccountID: "account-a"
        )
        let newAccount = requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000002",
            expectedAccountID: "account-b"
        )
        #expect(queue.enqueue(oldAccount))
        #expect(queue.enqueue(newAccount))

        queue.retainOnly(accountID: "account-b")
        queue.start()
        await probe.waitForCount(1)

        #expect(await probe.correlationIDs == [newAccount.correlationID])
    }

    @MainActor
    @Test func sessionSwitchDropsOldGenerationWorkBeforeStartingTheQueue() async {
        let probe = RecordingDeliveryProbe()
        let queue = PhonePushSerialDeliveryQueue(
            startsImmediately: false,
            sender: { await probe.deliver($0) }
        )
        let staleSession = requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000001",
            expectedAccountID: "account-a",
            expectedSessionGeneration: 1
        )
        let currentSession = requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000002",
            expectedAccountID: "account-a",
            expectedSessionGeneration: 2
        )
        #expect(queue.enqueue(staleSession))
        #expect(queue.enqueue(currentSession))

        queue.retainOnly(accountID: "account-a", generation: 2)
        queue.start()
        await probe.waitForCount(1)

        #expect(await probe.correlationIDs == [currentSession.correlationID])
    }

    @MainActor
    @Test func restoredQueueKeepsDistinctIDsAndOnlyTheLatestSameIDValue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "phone-push-queue-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhonePushQueueStore(
            fileURL: directory.appendingPathComponent("queue.json")
        )
        let oldA = requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000001",
            coalescingID: "notification-a"
        )
        let distinctB = requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000002",
            coalescingID: "notification-b"
        )
        let latestA = requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000003",
            coalescingID: "notification-a"
        )
        try await store.save([oldA, distinctB, latestA])

        let directoryMode = try #require(
            FileManager.default.attributesOfItem(atPath: directory.path)[
                .posixPermissions
            ] as? NSNumber
        ).intValue
        let fileMode = try #require(
            FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent("queue.json").path
            )[.posixPermissions] as? NSNumber
        ).intValue
        #expect(directoryMode & 0o777 == 0o700)
        #expect(fileMode & 0o777 == 0o600)

        let restored = try await store.load(nowEpochSeconds: 1_750_000_000)
        let probe = RecordingDeliveryProbe()
        let queue = PhonePushSerialDeliveryQueue(
            startsImmediately: false,
            sender: { await probe.deliver($0) }
        )
        queue.restore(restored)
        queue.start()
        await probe.waitForCount(2)

        #expect(
            await probe.correlationIDs
                == [distinctB.correlationID, latestA.correlationID]
        )
    }

    @MainActor
    @Test func restartDropsExpiredEventsBeforeTheyCanSend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "phone-push-expiry-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhonePushQueueStore(
            fileURL: directory.appendingPathComponent("queue.json")
        )
        try await store.save([
            PhonePushRequestEnvelope(
                correlationID: "00000000-0000-4000-8000-000000000001",
                expirationEpochSeconds: 999,
                body: Data()
            ),
        ])

        #expect(try await store.load(nowEpochSeconds: 1_000).isEmpty)
    }

    @Test func corruptQueueIsRemovedAfterTheFirstFailedLoad() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "phone-push-corrupt-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("queue.json")
        try Data("not-json".utf8).write(to: fileURL)
        let store = PhonePushQueueStore(fileURL: fileURL)

        await #expect(throws: (any Error).self) {
            try await store.load(nowEpochSeconds: 1_000)
        }
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try await store.load(nowEpochSeconds: 1_000).isEmpty)
    }

    @Test func abandonedTemporaryQueueSnapshotsAreScavenged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "phone-push-stale-tmp-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("queue.json")
        let store = PhonePushQueueStore(fileURL: fileURL)
        let staleBeforeLoad = directory.appendingPathComponent(
            ".queue.json.00000000-0000-4000-8000-000000000001.tmp"
        )
        let freshWriterSnapshot = directory.appendingPathComponent(
            ".queue.json.00000000-0000-4000-8000-000000000004.tmp"
        )
        try Data("stale".utf8).write(to: staleBeforeLoad)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -10 * 60)],
            ofItemAtPath: staleBeforeLoad.path
        )
        try Data("active".utf8).write(to: freshWriterSnapshot)

        #expect(try await store.load(nowEpochSeconds: 1_000).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: staleBeforeLoad.path))
        #expect(FileManager.default.fileExists(atPath: freshWriterSnapshot.path))

        let staleBeforeSave = directory.appendingPathComponent(
            ".queue.json.00000000-0000-4000-8000-000000000002.tmp"
        )
        try Data("stale".utf8).write(to: staleBeforeSave)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -10 * 60)],
            ofItemAtPath: staleBeforeSave.path
        )
        try await store.save([
            requestEnvelope(
                correlationID: "00000000-0000-4000-8000-000000000003"
            ),
        ])

        #expect(!FileManager.default.fileExists(atPath: staleBeforeSave.path))
        #expect(FileManager.default.fileExists(atPath: freshWriterSnapshot.path))
    }

    @Test func scavengerWaitsForAWriterHoldingTheStoreLock() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "phone-push-live-writer-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("queue.json")
        let lockURL = directory.appendingPathComponent(".queue.json.lock")
        let liveWriterSnapshot = directory.appendingPathComponent(
            ".queue.json.00000000-0000-4000-8000-000000000005.tmp"
        )
        try Data("active".utf8).write(to: liveWriterSnapshot)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -10 * 60)],
            ofItemAtPath: liveWriterSnapshot.path
        )

        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT,
            S_IRUSR | S_IWUSR
        )
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        var lockHeld = flock(descriptor, LOCK_EX) == 0
        #expect(lockHeld)
        defer {
            if lockHeld { _ = flock(descriptor, LOCK_UN) }
            _ = Darwin.close(descriptor)
        }

        let lockSequence = StoreLockSequenceProbe()
        let store = PhonePushQueueStore(
            fileURL: fileURL,
            beforeLockAttempt: { lockSequence.noteAttempt() },
            lockAcquired: { lockSequence.noteAcquired() }
        )
        let load = Task { try await store.load(nowEpochSeconds: 1_000) }
        await lockSequence.waitForAttempt()

        #expect(
            FileManager.default.fileExists(atPath: liveWriterSnapshot.path),
            "An old temporary file is still live while its writer holds the lock"
        )
        lockSequence.noteExternalRelease()
        _ = flock(descriptor, LOCK_UN)
        lockHeld = false
        #expect(try await load.value.isEmpty)
        #expect(!lockSequence.acquiredBeforeExternalRelease())
        #expect(!FileManager.default.fileExists(atPath: liveWriterSnapshot.path))
    }

    @Test func queuedEventCannotRebindToTheNextSignedInAccount() {
        let envelope = PhonePushRequestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000001",
            expirationEpochSeconds: 1_750_000_120,
            body: Data(),
            expectedAccountID: "account-a"
        )
        let original = AuthenticatedSessionSnapshot(
            generation: 1,
            accountID: "account-a",
            accessToken: "access-a",
            refreshToken: "refresh-a"
        )
        let replacement = AuthenticatedSessionSnapshot(
            generation: 2,
            accountID: "account-b",
            accessToken: "access-b",
            refreshToken: "refresh-b"
        )

        #expect(envelope.belongs(to: original))
        #expect(!envelope.belongs(to: replacement))
        #expect(PhonePushDeliveryAuthorization().permits(
            envelope: envelope,
            session: original,
            sessionIsCurrent: true
        ))
        #expect(!PhonePushDeliveryAuthorization().permits(
            envelope: envelope,
            session: original,
            sessionIsCurrent: false
        ))
    }

    private func requestEnvelope(
        correlationID: String,
        coalescingID: String? = nil,
        expectedAccountID: String? = nil,
        expectedSessionGeneration: UInt64? = nil
    ) -> PhonePushRequestEnvelope {
        PhonePushRequestEnvelope(
            correlationID: correlationID,
            expirationEpochSeconds: 1_750_000_120,
            body: Data(),
            coalescingID: coalescingID,
            expectedAccountID: expectedAccountID,
            expectedSessionGeneration: expectedSessionGeneration
        )
    }
}

private final class StoreLockSequenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var attempted = false
    private var externalReleased = false
    private var acquiredBeforeRelease = false
    private var attemptWaiters: [CheckedContinuation<Void, Never>] = []

    func noteAttempt() {
        lock.lock()
        attempted = true
        let waiters = attemptWaiters
        attemptWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    func waitForAttempt() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if attempted {
                lock.unlock()
                continuation.resume()
            } else {
                attemptWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func noteExternalRelease() {
        lock.lock()
        externalReleased = true
        lock.unlock()
    }

    func noteAcquired() {
        lock.lock()
        acquiredBeforeRelease = !externalReleased
        lock.unlock()
    }

    func acquiredBeforeExternalRelease() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return acquiredBeforeRelease
    }
}

private actor RecordingDeliveryProbe {
    private var values: [String] = []
    private var countWaiters:
        [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var correlationIDs: [String] { values }

    func deliver(
        _ envelope: PhonePushRequestEnvelope
    ) -> PhonePushHTTPResult {
        values.append(envelope.correlationID)
        resumeSatisfiedWaiters()
        return .accepted(sent: 1, devices: 1, pruned: 0)
    }

    func waitForCount(_ count: Int) async {
        guard values.count < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    private func resumeSatisfiedWaiters() {
        let ready = countWaiters.filter { values.count >= $0.target }
        countWaiters.removeAll { values.count >= $0.target }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

private actor FirstDeliveryGate {
    private var values: [String] = []
    private var firstRelease:
        CheckedContinuation<Void, Never>?
    private var countWaiters:
        [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var firstWasReleased = false

    var correlationIDs: [String] { values }

    func deliver(
        _ envelope: PhonePushRequestEnvelope
    ) async -> PhonePushHTTPResult {
        values.append(envelope.correlationID)
        resumeSatisfiedWaiters()
        if values.count == 1, !firstWasReleased {
            await withCheckedContinuation { continuation in
                firstRelease = continuation
            }
        }
        return .accepted(sent: 1, devices: 1, pruned: 0)
    }

    func waitForCount(_ count: Int) async {
        guard values.count < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func releaseFirst() {
        firstWasReleased = true
        firstRelease?.resume()
        firstRelease = nil
    }

    private func resumeSatisfiedWaiters() {
        let ready = countWaiters.filter { values.count >= $0.target }
        countWaiters.removeAll { values.count >= $0.target }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}
