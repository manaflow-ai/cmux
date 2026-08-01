import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for
/// https://github.com/manaflow-ai/cmux/issues/5830.
///
/// Control-socket command handlers that wait on an async callback (a
/// `browser eval`/`screenshot`/`cookies` WKWebView completion, etc.) bridge it
/// to a synchronous socket reply through `socketAwaitCallback`. That waiter
/// must never run on the **main thread**: historically it spun a nested
/// `CFRunLoopRun()` there, freezing the whole app (sidebar + every other CLI
/// client serialized behind it) for the full command timeout.
///
/// The control-command execution policy already routes every callback-waiting
/// command onto the socket-worker thread, so reaching the waiter on the main
/// thread is a programming error. The contract verified here: a main-thread
/// call returns `nil` immediately **without** kicking off the async work, so
/// the dispatcher surfaces a fast timeout instead of parking AppKit.
@Suite struct SocketCallbackAwaiterMainThreadTests {
    @Test func mainThreadWaitRefusesToBlockOrStartWork() {
        nonisolated(unsafe) var startInvoked = false
        let result: Int? = socketAwaitCallback(timeout: 0.3, isMainThread: true) { _ in
            // A never-resolving callback. With the old nested-runloop behavior
            // this branch ran and pinned the thread until the timeout lapsed;
            // the fix returns before `start` is ever called.
            startInvoked = true
        }

        #expect(result == nil)
        #expect(startInvoked == false)
    }

    @Test func offMainThreadStillDeliversTheCallbackResult() {
        // The off-main worker-thread path is unchanged: it must keep blocking on
        // the callback and returning its value.
        let result: Int? = socketAwaitCallback(timeout: 1.0, isMainThread: false) { finish in
            finish(42)
        }

        #expect(result == 42)
    }

    @Test func offMainThreadReturnsNilOnTimeout() {
        let result: Int? = socketAwaitCallback(timeout: 0.05, isMainThread: false) { _ in
            // Never resolves: the off-main path must time out cleanly to `nil`.
        }

        #expect(result == nil)
    }

    @Test
    func timedOutReloadWaiterRetainsAdmissionUntilCallbackRetires() {
        let admission =
            SocketReloadConfigurationWaiterAdmission(
                maximumConcurrentWaiters: 1
            )
        let lease = admission.claim()
        #expect(lease != nil)
        nonisolated(unsafe) var retireCallback:
            (() -> Void)?

        let result: Void? = socketAwaitCallback(
            timeout: 0.01,
            isMainThread: false
        ) { completion in
            retireCallback = {
                completion(())
                lease?.retire()
            }
        }

        #expect(result == nil)
        #expect(admission.claim() == nil)

        retireCallback?()
        let replacement = admission.claim()
        #expect(replacement != nil)
        replacement?.retire()
    }
}

@Suite struct WindowScreenshotCaptureRoutingTests {
    @Test func windowNumberConversionRejectsValuesOutsideCGWindowIDRange() {
        #expect(windowScreenshotCGWindowID(exactly: 42) == 42)
        #expect(windowScreenshotCGWindowID(exactly: Int(UInt32.max)) == UInt32.max)
        #expect(windowScreenshotCGWindowID(exactly: -1) == nil)
        #expect(windowScreenshotCGWindowID(exactly: Int(UInt32.max) + 1) == nil)
    }

    @Test func timeoutLatchPermanentlyDisablesCompositorCapture() {
        var latch = WindowScreenshotCaptureTimeoutLatch()

        #expect(latch.allowsCapture)
        latch.recordTimeout()
        #expect(!latch.allowsCapture)
        latch.recordTimeout()
        #expect(!latch.allowsCapture)
    }

    @Test func onlyUnavailableCaptureFallsBackToAppKit() {
        let data = Data([0x89, 0x50, 0x4E, 0x47])

        #expect(
            windowScreenshotCaptureAction(for: .captured(data))
                == .useCaptured(data)
        )
        #expect(
            windowScreenshotCaptureAction(for: .unavailable)
                == .captureWithAppKit
        )
        #expect(
            windowScreenshotCaptureAction(for: .busy)
                == .fail("screenshot capture already in progress")
        )
        #expect(
            windowScreenshotCaptureAction(for: .timedOut)
                == .fail("screenshot capture timed out")
        )
    }
}
