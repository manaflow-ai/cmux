import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Paste preparation owns workers through reaping")
struct TerminalPastePreparationReapingTests {
    @Test("cancellation completes only after worker teardown and result cleanup",
          arguments: [false, true])
    func cancellationWaitsForReaping(deadlineExpires: Bool) async throws {
        let events = AsyncStream<String>.makeStream()
        let worker = DelayedPastePreparationTermination(events: events.continuation)
        let deadlines = ControlledPastePreparationDeadlines()
        let service = TerminalImageTransferPreparationService(
            deadlineSleep: { _ in try await deadlines.sleep() },
            operation: { request in
                if request.pasteboard.pasteboardName == "next" {
                    return .terminal(.insertText("first\nsecond\n日本語\n"))
                }
                return await worker.run()
            },
            cleanup: { _ in events.continuation.yield("cleanup") },
            failureSignal: { failure in
                events.continuation.yield("failure:\(failure)")
            }
        )
        let paste = Task {
            let result = await service.prepare(
                request: TerminalPasteboardReadRequest(
                    pasteboardName: "cancelled",
                    changeCount: 0
                ),
                mode: .paste
            )
            events.continuation.yield("returned")
            return result
        }
        var started = worker.started.makeAsyncIterator()
        _ = await started.next()
        await deadlines.waitForArrivalCount(1)
        if deadlineExpires {
            #expect(await deadlines.fireNext())
        } else {
            paste.cancel()
        }

        #expect(await paste.value == .reject)
        // Drain the simulated external reaper even when the regression fails,
        // so a failed assertion cannot leave a worker in another test's lane.
        var reaped = worker.finished.makeAsyncIterator()
        _ = await reaped.next()
        let next = await service.prepare(
            request: TerminalPasteboardReadRequest(
                pasteboardName: "next",
                changeCount: 0
            ),
            mode: .paste
        )
        #expect(next == .insertText("first\nsecond\n日本語\n"))
        events.continuation.finish()
        var observed: [String] = []
        for await event in events.stream { observed.append(event) }
        let expected = deadlineExpires
            ? ["reaped", "cleanup", "failure:deadlineExceeded", "returned"]
            : ["reaped", "cleanup", "returned"]
        #expect(observed == expected)
    }
}
