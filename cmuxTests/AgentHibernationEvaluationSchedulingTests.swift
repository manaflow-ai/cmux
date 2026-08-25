import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct AgentHibernationEvaluationSchedulingTests {
    @MainActor
    @Test
    func activeEvaluationRejectsLaterTimerRequests() async throws {
        let controller = AgentHibernationController.shared
        controller.cancelEvaluation()
        defer { controller.cancelEvaluation() }

        let evaluationStarted = AsyncStream<Void>.makeStream()
        let releaseEvaluation = AsyncStream<Void>.makeStream()
        let activeEvaluationFinished = AsyncStream<Void>.makeStream()
        let counter = Counter()

        #expect(controller.startEvaluationIfIdle {
            counter.begin()
            defer { counter.end() }
            evaluationStarted.continuation.yield()
            await Self.waitForSignal(releaseEvaluation.stream)
            activeEvaluationFinished.continuation.yield()
        })
        await Self.waitForSignal(evaluationStarted.stream)

        #expect(!controller.startEvaluationIfIdle {
            counter.begin()
        })
        #expect(!controller.startEvaluationIfIdle {
            counter.begin()
        })

        releaseEvaluation.continuation.yield()
        await Self.waitForSignal(activeEvaluationFinished.stream)

        let finalEvaluationFinished = AsyncStream<Void>.makeStream()
        #expect(controller.startEvaluationIfIdle {
            counter.begin()
            defer { counter.end() }
            finalEvaluationFinished.continuation.yield()
        })
        await Self.waitForSignal(finalEvaluationFinished.stream)
        await Task.yield()

        #expect(counter.value == 2)
        #expect(counter.maximumActiveCount == 1)
    }

    @MainActor
    @Test
    func lateCompletionFromCancelledEvaluationDoesNotFinishReplacement() async {
        let controller = AgentHibernationController.shared
        controller.cancelEvaluation()
        defer { controller.cancelEvaluation() }

        let oldGate = Gate()
        let oldStarted = AsyncStream<Void>.makeStream()
        let oldFinished = AsyncStream<Void>.makeStream()
        #expect(controller.startEvaluationIfIdle {
            oldStarted.continuation.yield()
            await oldGate.wait()
            oldFinished.continuation.yield()
        })
        await Self.waitForSignal(oldStarted.stream)

        controller.cancelEvaluation()

        let replacementGate = Gate()
        let replacementStarted = AsyncStream<Void>.makeStream()
        let replacementFinished = AsyncStream<Void>.makeStream()
        #expect(controller.startEvaluationIfIdle {
            replacementStarted.continuation.yield()
            await replacementGate.wait()
            replacementFinished.continuation.yield()
        })
        await Self.waitForSignal(replacementStarted.stream)

        oldGate.open()
        await Self.waitForSignal(oldFinished.stream)
        #expect(!controller.startEvaluationIfIdle {})

        replacementGate.open()
        await Self.waitForSignal(replacementFinished.stream)
        #expect(controller.startEvaluationIfIdle {})
    }

    @MainActor
    @Test
    func immediateRefreshBypassesFreshCacheAndCoalescesCallers() async {
        let hookStoreDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-refresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookStoreDirectory) }

        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadCount.withLock { $0 += 1 }
                return (
                    index: RestorableAgentSessionIndex.empty,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            hookStoreDirectoryProvider: { hookStoreDirectory.path }
        )

        _ = await sharedIndex.indexRefreshingNow()
        #expect(loadCount.withLock { $0 } == 1)
        _ = sharedIndex.currentIndexSchedulingRefresh()
        await Task.yield()
        #expect(loadCount.withLock { $0 } == 1)
        _ = await sharedIndex.indexRefreshingNow()
        #expect(loadCount.withLock { $0 } == 2)

        let coalescedLoadCount = OSAllocatedUnfairLock(initialState: 0)
        let loaderStarted = AsyncStream<Void>.makeStream()
        let releaseLoader = DispatchSemaphore(value: 0)
        let coalescingIndex = SharedLiveAgentIndex(
            indexLoader: {
                coalescedLoadCount.withLock { $0 += 1 }
                loaderStarted.continuation.yield()
                releaseLoader.wait()
                return (
                    index: RestorableAgentSessionIndex.empty,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            hookStoreDirectoryProvider: { hookStoreDirectory.path }
        )

        let first = Task { @MainActor in await coalescingIndex.indexRefreshingNow() }
        await Self.waitForSignal(loaderStarted.stream)
        let second = Task { @MainActor in await coalescingIndex.indexRefreshingNow() }
        await Task.yield()
        releaseLoader.signal()
        _ = await first.value
        _ = await second.value
        #expect(coalescedLoadCount.withLock { $0 } == 1)
    }

    private static func waitForSignal(_ stream: AsyncStream<Void>) async {
        for await _ in stream {
            return
        }
    }

    @MainActor
    private final class Counter {
        var value = 0
        var activeCount = 0
        var maximumActiveCount = 0

        func begin() {
            value += 1
            activeCount += 1
            maximumActiveCount = max(maximumActiveCount, activeCount)
        }

        func end() {
            activeCount -= 1
        }
    }

    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }
}
