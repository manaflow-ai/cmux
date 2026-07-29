import Foundation
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
        let counter = Counter()

        #expect(controller.startEvaluationIfIdle {
            counter.value += 1
            evaluationStarted.continuation.yield()
            await Self.waitForSignal(releaseEvaluation.stream)
        })
        await Self.waitForSignal(evaluationStarted.stream)

        #expect(!controller.startEvaluationIfIdle {
            counter.value += 1
        })
        #expect(!controller.startEvaluationIfIdle {
            counter.value += 1
        })

        let activeEvaluation = try #require(controller.evaluationTask)
        releaseEvaluation.continuation.yield()
        await activeEvaluation.value

        let finalEvaluationFinished = AsyncStream<Void>.makeStream()
        #expect(controller.startEvaluationIfIdle {
            counter.value += 1
            finalEvaluationFinished.continuation.yield()
        })
        await Self.waitForSignal(finalEvaluationFinished.stream)
        await Task.yield()

        #expect(counter.value == 2)
    }

    private static func waitForSignal(_ stream: AsyncStream<Void>) async {
        for await _ in stream {
            return
        }
    }

    @MainActor
    private final class Counter {
        var value = 0
    }
}
