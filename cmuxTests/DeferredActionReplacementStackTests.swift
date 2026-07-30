import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct DeferredActionReplacementStackTests {
    private final class ReleaseStackRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var minimumAddress = UInt.max
        private var maximumAddress: UInt = 0
        private var releaseCount = 0
        private var offMainReleaseCount = 0

        // The lock protects synchronous deinit observations that may arrive from
        // task cleanup. It is test-only and never crosses into production code.
        func record(address: UInt, isMainThread: Bool) {
            lock.lock()
            minimumAddress = min(minimumAddress, address)
            maximumAddress = max(maximumAddress, address)
            releaseCount += 1
            if !isMainThread {
                offMainReleaseCount += 1
            }
            lock.unlock()
        }

        var snapshot: (count: Int, offMain: Int, addressSpan: UInt) {
            lock.lock()
            defer { lock.unlock() }
            let span = minimumAddress == UInt.max ? 0 : maximumAddress - minimumAddress
            return (releaseCount, offMainReleaseCount, span)
        }
    }

    private final class ClosureLifetimeProbe {
        let identifier: Int
        let recorder: ReleaseStackRecorder
        let deinitialized: AsyncStream<Int>.Continuation

        init(
            identifier: Int,
            recorder: ReleaseStackRecorder,
            deinitialized: AsyncStream<Int>.Continuation
        ) {
            self.identifier = identifier
            self.recorder = recorder
            self.deinitialized = deinitialized
        }

        deinit {
            var stackMarker: UInt8 = 0
            let address = withUnsafePointer(to: &stackMarker) {
                UInt(bitPattern: UnsafeRawPointer($0))
            }
            recorder.record(address: address, isMainThread: Thread.isMainThread)
            deinitialized.yield(identifier)
        }
    }

    @MainActor
    private final class TimerActionOwner {
        var fireCount = 0
    }

    @MainActor
    private func legacyWorkItemReleaseSnapshot(
        count: Int,
        recorder: ReleaseStackRecorder
    ) -> (count: Int, offMain: Int, addressSpan: UInt) {
        let deinitializations = AsyncStream<Int>.makeStream()
        defer { deinitializations.continuation.finish() }
        var head: DispatchWorkItem?

        for identifier in 0..<count {
            let previous = head
            let probe = ClosureLifetimeProbe(
                identifier: identifier,
                recorder: recorder,
                deinitialized: deinitializations.continuation
            )
            head = DispatchWorkItem { [previous, probe] in
                _ = previous
                _ = probe
            }
        }

        head = nil
        return recorder.snapshot
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func schedulerTracksCancellationAndReschedulingFromAction() async {
        let clock = SidebarTestManualClock()
        let scheduler = MainActorDeferredActionScheduler(clock: clock)
        var actionStates: [Bool] = []

        #expect(!scheduler.isScheduled)
        scheduler.schedule(after: .milliseconds(100)) {
            actionStates.append(true)
        }
        #expect(scheduler.isScheduled)
        await clock.waitUntilSleeping(for: .milliseconds(100))

        scheduler.cancel()
        #expect(!scheduler.isScheduled)
        await clock.waitUntilIdle()
        clock.advance(by: .milliseconds(100))
        for _ in 0..<3 {
            await Task.yield()
        }
        #expect(actionStates.isEmpty)

        let successorFired = AsyncStream<Void>.makeStream()
        defer { successorFired.continuation.finish() }
        var successorIterator = successorFired.stream.makeAsyncIterator()
        scheduler.schedule(after: .milliseconds(20)) {
            actionStates.append(scheduler.isScheduled)
            scheduler.schedule(after: .milliseconds(10)) {
                actionStates.append(scheduler.isScheduled)
                successorFired.continuation.yield()
            }
            actionStates.append(scheduler.isScheduled)
        }
        #expect(scheduler.isScheduled)
        await clock.waitUntilSleeping(for: .milliseconds(20))

        clock.advance(by: .milliseconds(20))
        await clock.waitUntilSleeping(for: .milliseconds(10))
        #expect(actionStates == [false, true])
        #expect(scheduler.isScheduled)

        clock.advance(by: .milliseconds(10))
        _ = await successorIterator.next()
        #expect(actionStates == [false, true, false])
        #expect(!scheduler.isScheduled)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func coalescingDeadlineTimerReusesOneHandleAcrossBurst() async {
        let owner = TimerActionOwner()
        let fires = AsyncStream<Void>.makeStream()
        defer { fires.continuation.finish() }
        var fireIterator = fires.stream.makeAsyncIterator()
        let timer = MainActorCoalescingDeadlineTimer(owner: owner) { owner in
            owner.fireCount += 1
            fires.continuation.yield()
        }

        for _ in 0..<5_000 {
            timer.schedule(after: .milliseconds(20))
        }

        #expect(timer.isScheduled)
        _ = await fireIterator.next()
        #expect(owner.fireCount == 1)
        #expect(!timer.isScheduled)
    }

    @Test
    @MainActor
    func legacyWorkItemHarnessShowsProportionalRecursiveReleaseDepth() {
        let shortChain = legacyWorkItemReleaseSnapshot(
            count: 16,
            recorder: ReleaseStackRecorder()
        )
        let longChain = legacyWorkItemReleaseSnapshot(
            count: 128,
            recorder: ReleaseStackRecorder()
        )

        #expect(shortChain.count == 16)
        #expect(longChain.count == 128)
        #expect(shortChain.offMain == 0)
        #expect(longChain.offMain == 0)
        #expect(longChain.addressSpan > shortChain.addressSpan * 2)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func sharedSchedulerReplacementBurstKeepsReleaseStackBounded() async throws {
        let replacementCount = 5_000
        let recorder = ReleaseStackRecorder()
        let deinitializations = AsyncStream<Int>.makeStream()
        defer { deinitializations.continuation.finish() }
        var deinitializationIterator = deinitializations.stream.makeAsyncIterator()
        let releases = AsyncStream<Int>.makeStream()
        defer { releases.continuation.finish() }
        var releaseIterator = releases.stream.makeAsyncIterator()
        let scheduler = MainActorDeferredActionScheduler()

        for identifier in 0..<replacementCount {
            let probe = ClosureLifetimeProbe(
                identifier: identifier,
                recorder: recorder,
                deinitialized: deinitializations.continuation
            )
            scheduler.schedule { [probe, scheduler] in
                // Mirror a SwiftUI value snapshot that transitively retains the
                // scheduler while its deferred closure is queued.
                _ = scheduler
                _ = probe
                releases.continuation.yield(identifier)
            }
        }

        let firedIdentifier = try #require(await releaseIterator.next())
        #expect(firedIdentifier == replacementCount - 1)

        var deinitializedIdentifiers: Set<Int> = []
        for _ in 0..<replacementCount {
            deinitializedIdentifiers.insert(try #require(await deinitializationIterator.next()))
        }
        #expect(deinitializedIdentifiers == Set(0..<replacementCount))

        let snapshot = recorder.snapshot
        #expect(snapshot.count == replacementCount)
        #expect(snapshot.offMain == 0)
        // Independent task cleanup reuses a shallow executor stack. A linked
        // release chain would move this marker once per replacement (or exhaust
        // the 8 MB main-thread stack before reaching this assertion).
        #expect(snapshot.addressSpan < 512 * 1_024)
    }
}
