import AppKit
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserDesignModeScreenshotEvaluatorTests {
    @Test func returnsCompletedCapture() async throws {
        let expected = NSImage(size: NSSize(width: 20, height: 10))
        let evaluator = BrowserDesignModeScreenshotEvaluator(timeout: 1) { _, completion in
            completion(.success(expected))
        }

        let captured = try await evaluator.captureVisibleViewport(from: WKWebView())

        #expect(captured === expected)
    }

    @Test func cancelAllReleasesPendingCapture() async {
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let evaluator = BrowserDesignModeScreenshotEvaluator(timeout: 60) { _, _ in
            startedContinuation.yield(())
        }
        let task = Task { @MainActor in
            try await evaluator.captureVisibleViewport(from: WKWebView())
        }
        var startedIterator = started.makeAsyncIterator()
        _ = await startedIterator.next()

        evaluator.cancelAll()
        startedContinuation.finish()

        do {
            _ = try await task.value
            Issue.record("Expected capture cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func timesOutWhenWebKitDoesNotComplete() async {
        let evaluator = BrowserDesignModeScreenshotEvaluator(timeout: 0) { _, _ in }

        do {
            _ = try await evaluator.captureVisibleViewport(from: WKWebView())
            Issue.record("Expected capture timeout")
        } catch {
            #expect(error as? BrowserDesignModeSendError == .operationTimedOut)
        }
    }
}
