import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SharedLiveAgentIndexStallRecoveryTests {
    @Test
    func hookChangeAfterCapturingTimeoutStartsSuccessor() async {
        let timeoutWaiter = ManualTimeoutWaiter()
        let firstStarted = DispatchSemaphore(value: 0)
        let successorStarted = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseSuccessor = DispatchSemaphore(value: 0)
        defer {
            releaseFirst.signal()
            releaseSuccessor.signal()
        }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                (invocation == 1 ? firstStarted : successorStarted).signal()
                (invocation == 1 ? releaseFirst : releaseSuccessor).wait()
                completed.signal()
                return Self.loadResult(sessionId: "post-timeout-hook-\(invocation)")
            },
            generationTimeoutWaiter: { await timeoutWaiter.wait() },
            hookStoreDirectoryProvider: { Self.temporaryDirectory.path }
        )
        let first = Task { @MainActor in await sharedIndex.resumeIndexesCapturedAfterRequest() }
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: firstStarted))
        await timeoutWaiter.waitUntilPendingCount(1)
        await timeoutWaiter.fireNext()
        #expect((await first.value) == nil)
        #expect(loadCount.withLock { $0 } == 1)

        sharedIndex.handleHookStoreChange()

        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: successorStarted))
        #expect(loadCount.withLock { $0 } == 2)
        releaseSuccessor.signal()
        releaseFirst.signal()
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: completed))
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: completed))
        await timeoutWaiter.cancelAll()
    }

    @Test
    func capturingTimeoutDrainsPendingHookChangeIntoSuccessor() async {
        let timeoutWaiter = ManualTimeoutWaiter()
        let firstStarted = DispatchSemaphore(value: 0)
        let firstCompleted = DispatchSemaphore(value: 0)
        let successorStarted = DispatchSemaphore(value: 0)
        let successorCompleted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseSuccessor = DispatchSemaphore(value: 0)
        defer {
            releaseFirst.signal()
            releaseSuccessor.signal()
        }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                (invocation == 1 ? firstStarted : successorStarted).signal()
                (invocation == 1 ? releaseFirst : releaseSuccessor).wait()
                (invocation == 1 ? firstCompleted : successorCompleted).signal()
                return Self.loadResult(sessionId: "capturing-timeout-\(invocation)")
            },
            generationTimeoutWaiter: { await timeoutWaiter.wait() },
            hookStoreDirectoryProvider: { Self.temporaryDirectory.path }
        )
        let first = Task { @MainActor in await sharedIndex.resumeIndexesCapturedAfterRequest() }
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: firstStarted))
        await timeoutWaiter.waitUntilPendingCount(1)

        sharedIndex.handleHookStoreChange()
        await timeoutWaiter.fireNext()

        #expect((await first.value) == nil)
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: successorStarted))
        #expect(loadCount.withLock { $0 } == 2)
        #expect(!sharedIndex.changePending)
        releaseSuccessor.signal()
        releaseFirst.signal()
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: successorCompleted))
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: firstCompleted))
        await timeoutWaiter.cancelAll()
    }

    @Test
    func pendingHookChangeWaitsForCapacityThenStartsAfterCompletion() async {
        let timeoutWaiter = ManualTimeoutWaiter()
        let firstStarted = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let thirdStarted = DispatchSemaphore(value: 0)
        let completed = [
            DispatchSemaphore(value: 0),
            DispatchSemaphore(value: 0),
            DispatchSemaphore(value: 0),
        ]
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        let releaseThird = DispatchSemaphore(value: 0)
        defer {
            releaseFirst.signal()
            releaseSecond.signal()
            releaseThird.signal()
        }
        let loadState = OSAllocatedUnfairLock(initialState: (active: 0, maximum: 0, count: 0))
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadState.withLock { state in
                    state.active += 1
                    state.maximum = max(state.maximum, state.active)
                    state.count += 1
                    return state.count
                }
                switch invocation {
                case 1:
                    firstStarted.signal()
                    releaseFirst.wait()
                case 2:
                    secondStarted.signal()
                    releaseSecond.wait()
                default:
                    thirdStarted.signal()
                    releaseThird.wait()
                }
                loadState.withLock { $0.active -= 1 }
                completed[invocation - 1].signal()
                return Self.loadResult(sessionId: "capacity-\(invocation)")
            },
            generationTimeoutWaiter: { await timeoutWaiter.wait() },
            hookStoreDirectoryProvider: { Self.temporaryDirectory.path }
        )
        let first = Task { @MainActor in await sharedIndex.resumeIndexesCapturedAfterRequest() }
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: firstStarted))
        await timeoutWaiter.waitUntilPendingCount(1)
        await timeoutWaiter.fireNext()
        #expect((await first.value) == nil)
        let second = Task { @MainActor in await sharedIndex.resumeIndexesCapturedAfterRequest() }
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: secondStarted))
        await timeoutWaiter.waitUntilPendingCount(1)

        sharedIndex.handleHookStoreChange()
        await timeoutWaiter.fireNext()

        #expect((await second.value) == nil)
        #expect(sharedIndex.changePending)
        #expect(loadState.withLock { $0.count } == 2)
        releaseSecond.signal()
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: thirdStarted))
        #expect(!sharedIndex.changePending)
        #expect(loadState.withLock { $0.count } == 3)
        #expect(loadState.withLock { $0.maximum } == 2)
        releaseThird.signal()
        releaseFirst.signal()
        for completion in completed {
            #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: completion))
        }
        await timeoutWaiter.cancelAll()
    }

    @Test
    func queuedTimeoutDrainsPendingHookChangeWithoutAnotherEvent() async {
        let timeoutWaiter = ManualTimeoutWaiter()
        let firstStarted = DispatchSemaphore(value: 0)
        let replacementStarted = DispatchSemaphore(value: 0)
        let replacementCompleted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseReplacement = DispatchSemaphore(value: 0)
        defer {
            releaseFirst.signal()
            releaseReplacement.signal()
        }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                (invocation == 1 ? firstStarted : replacementStarted).signal()
                (invocation == 1 ? releaseFirst : releaseReplacement).wait()
                if invocation != 1 { replacementCompleted.signal() }
                return Self.loadResult(sessionId: "hook-replacement-\(invocation)")
            },
            generationTimeoutWaiter: { await timeoutWaiter.wait() },
            hookStoreDirectoryProvider: { Self.temporaryDirectory.path }
        )
        let first = Task { @MainActor in await sharedIndex.resumeIndexesCapturedAfterRequest() }
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: firstStarted))
        await timeoutWaiter.waitUntilPendingCount(1)
        let queued = Task { @MainActor in await sharedIndex.resumeIndexesCapturedAfterRequest() }
        await timeoutWaiter.waitUntilPendingCount(2)

        sharedIndex.handleHookStoreChange()
        await timeoutWaiter.fireLast()

        #expect((await queued.value) == nil)
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: replacementStarted))
        #expect(loadCount.withLock { $0 } == 2)
        releaseReplacement.signal()
        releaseFirst.signal()
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: replacementCompleted))
        #expect((await first.value) != nil)
        await timeoutWaiter.cancelAll()
    }

    @Test
    func queuedGenerationTimeoutIncludesPredecessorWait() async {
        let timeoutWaiter = ManualTimeoutWaiter()
        let firstStarted = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal() }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                (invocation == 1 ? firstStarted : secondStarted).signal()
                if invocation == 1 { releaseFirst.wait() }
                return Self.loadResult(sessionId: "queued-\(invocation)")
            },
            generationTimeoutWaiter: { await timeoutWaiter.wait() },
            hookStoreDirectoryProvider: { Self.temporaryDirectory.path }
        )
        let first = Task { @MainActor in await sharedIndex.resumeIndexesCapturedAfterRequest() }
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: firstStarted))
        await timeoutWaiter.waitUntilPendingCount(1)
        let second = Task { @MainActor in await sharedIndex.resumeIndexesCapturedAfterRequest() }
        await timeoutWaiter.waitUntilPendingCount(2)

        await timeoutWaiter.fireLast()
        #expect((await second.value) == nil)
        #expect(!(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: secondStarted, timeout: 0.2)))
        #expect(loadCount.withLock { $0 } == 1)

        releaseFirst.signal()
        #expect((await first.value) != nil)
        await timeoutWaiter.cancelAll()
    }

    @Test
    func successorRemainsSingleFlightWhenPredecessorCompletes() async {
        let timeoutWaiter = ManualTimeoutWaiter()
        let firstStarted = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        defer {
            releaseFirst.signal()
            releaseSecond.signal()
        }
        let loadState = OSAllocatedUnfairLock(initialState: (active: 0, maximum: 0, count: 0))
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadState.withLock { state in
                    state.active += 1
                    state.maximum = max(state.maximum, state.active)
                    state.count += 1
                    return state.count
                }
                (invocation == 1 ? firstStarted : secondStarted).signal()
                (invocation == 1 ? releaseFirst : releaseSecond).wait()
                loadState.withLock { $0.active -= 1 }
                return Self.loadResult(sessionId: "normal-\(invocation)")
            },
            generationTimeoutWaiter: { await timeoutWaiter.wait() },
            hookStoreDirectoryProvider: { Self.temporaryDirectory.path }
        )

        let first = Task { @MainActor in await sharedIndex.scopedIndexCapturedAfterRequest() }
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: firstStarted))
        await timeoutWaiter.waitUntilPendingCount(1)

        let second = Task { @MainActor in await sharedIndex.scopedIndexCapturedAfterRequest() }
        #expect(!(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: secondStarted, timeout: 0.2)))

        releaseFirst.signal()
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: secondStarted))
        #expect(loadState.withLock { $0.maximum } == 1)
        releaseSecond.signal()

        _ = await first.value
        _ = await second.value
        #expect(loadState.withLock { $0.count } == 2)
        #expect(loadState.withLock { $0.maximum } == 1)
        await timeoutWaiter.cancelAll()
    }

    @Test
    func twoStalledGenerationsReturnUnavailableWithoutLaunchingThird() async {
        let timeoutWaiter = ManualTimeoutWaiter()
        let firstStarted = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let firstCompleted = DispatchSemaphore(value: 0)
        let secondCompleted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        defer {
            releaseFirst.signal()
            releaseSecond.signal()
        }
        let workspaceId = UUID()
        let panelId = UUID()
        let loadState = OSAllocatedUnfairLock(initialState: (active: 0, maximum: 0, count: 0))
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadState.withLock { state in
                    state.active += 1
                    state.maximum = max(state.maximum, state.active)
                    state.count += 1
                    return state.count
                }
                (invocation == 1 ? firstStarted : secondStarted).signal()
                (invocation == 1 ? releaseFirst : releaseSecond).wait()
                loadState.withLock { $0.active -= 1 }
                (invocation == 1 ? firstCompleted : secondCompleted).signal()
                return Self.loadResult(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    sessionId: "stalled-\(invocation)"
                )
            },
            generationTimeoutWaiter: { await timeoutWaiter.wait() },
            hookStoreDirectoryProvider: { Self.temporaryDirectory.path }
        )

        let first = Task { @MainActor in await sharedIndex.resumeIndexesCapturedAfterRequest() }
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: firstStarted))
        await timeoutWaiter.waitUntilPendingCount(1)

        await timeoutWaiter.fireNext()
        #expect(await first.value == nil)

        let second = Task { @MainActor in await sharedIndex.indexRefreshingIfNeeded() }
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: secondStarted))
        await timeoutWaiter.waitUntilPendingCount(1)
        #expect(loadState.withLock { $0.maximum } == 2)

        let third = await sharedIndex.resumeIndexesCapturedAfterRequest()
        #expect(third == nil)
        #expect(loadState.withLock { $0.count } == 2)

        await timeoutWaiter.fireNext()
        #expect(await second.value == nil)

        releaseSecond.signal()
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: secondCompleted))
        releaseFirst.signal()
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: firstCompleted))
        #expect(loadState.withLock { $0.maximum } == 2)
        #expect(sharedIndex.cachedIndex()?.snapshot(
            workspaceId: workspaceId,
            panelId: panelId
        )?.sessionId == "stalled-2")
        await timeoutWaiter.cancelAll()
    }

    private static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shared-index-stall-\(UUID().uuidString)", isDirectory: true)
    }

    nonisolated private static func loadResult(
        workspaceId: UUID = UUID(),
        panelId: UUID = UUID(),
        sessionId: String
    ) -> SharedLiveAgentIndexLoader.LoadResult {
        (
            index: SharedLiveAgentIndexLoadCoalescingTests.index(
                workspaceId: workspaceId,
                panelId: panelId,
                sessionId: sessionId
            ),
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: [],
            forkValidatedPanels: []
        )
    }

    private actor ManualTimeoutWaiter {
        private var pending: [CheckedContinuation<Bool, Never>] = []
        private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func wait() async -> Bool {
            await withCheckedContinuation { continuation in
                pending.append(continuation)
                resumeSatisfiedCountWaiters()
            }
        }

        func waitUntilPendingCount(_ count: Int) async {
            guard pending.count < count else { return }
            await withCheckedContinuation { continuation in
                countWaiters.append((count: count, continuation: continuation))
            }
        }

        func fireNext() {
            guard !pending.isEmpty else { return }
            pending.removeFirst().resume(returning: true)
        }

        func fireLast() {
            guard !pending.isEmpty else { return }
            pending.removeLast().resume(returning: true)
        }

        func cancelAll() {
            let pending = self.pending
            self.pending.removeAll()
            for continuation in pending {
                continuation.resume(returning: false)
            }
            let countWaiters = self.countWaiters
            self.countWaiters.removeAll()
            for waiter in countWaiters {
                waiter.continuation.resume()
            }
        }

        private func resumeSatisfiedCountWaiters() {
            var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
            for waiter in countWaiters {
                if pending.count >= waiter.count {
                    waiter.continuation.resume()
                } else {
                    remaining.append(waiter)
                }
            }
            countWaiters = remaining
        }
    }
}
