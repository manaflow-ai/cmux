import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Models a cancelled subprocess whose termination callback has not arrived yet.
actor DelayedPastePreparationTermination {
    nonisolated let started: AsyncStream<Void>
    nonisolated let finished: AsyncStream<Void>
    private let startSignal: AsyncStream<Void>.Continuation
    private let finishSignal: AsyncStream<Void>.Continuation
    private let events: AsyncStream<String>.Continuation
    private var continuation: CheckedContinuation<TerminalPastePreparationResult, Never>?

    init(events: AsyncStream<String>.Continuation) {
        let start = AsyncStream<Void>.makeStream()
        started = start.stream
        startSignal = start.continuation
        let finish = AsyncStream<Void>.makeStream()
        finished = finish.stream
        finishSignal = finish.continuation
        self.events = events
    }

    func run() async -> TerminalPastePreparationResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                startSignal.yield()
                startSignal.finish()
            }
        } onCancel: {
            Task { await self.terminate() }
        }
    }

    private func terminate() async {
        // This is simulated subprocess teardown latency, not a wait for the
        // assertion to become true. The assertion checks the actual event order.
        try? await ContinuousClock().sleep(for: .seconds(1))
        events.yield("reaped")
        continuation?.resume(returning: .terminal(.fileURLs([
            URL(fileURLWithPath: "/unused-paste-worker-result.png")
        ])))
        continuation = nil
        finishSignal.yield()
        finishSignal.finish()
    }
}
