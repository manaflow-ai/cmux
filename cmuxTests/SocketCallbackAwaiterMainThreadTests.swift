import AppKit
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
        #expect(WindowScreenshotTarget(windowNumber: 42)?.windowID == 42)
        #expect(
            WindowScreenshotTarget(windowNumber: Int(UInt32.max))?.windowID
                == UInt32.max
        )
        #expect(WindowScreenshotTarget(windowNumber: -1) == nil)
        #expect(WindowScreenshotTarget(windowNumber: Int(UInt32.max) + 1) == nil)
    }

    @Test func coordinatorSerializesCaptureAndDisablesTimedOutCompositor() throws {
        let coordinator = WindowScreenshotCaptureCoordinator()

        let firstClaim = coordinator.claim()
        let first = try #require(firstClaim)
        #expect(first.allowsScreenCaptureKit)
        let contendedClaim = coordinator.claim()
        #expect(contendedClaim == nil)

        coordinator.finish(first, screenCaptureKitDidTimeOut: true)

        let secondClaim = coordinator.claim()
        let second = try #require(secondClaim)
        #expect(!second.allowsScreenCaptureKit)
        coordinator.finish(second, screenCaptureKitDidTimeOut: false)
        let third = coordinator.claim()
        #expect(third != nil)
        if let third {
            coordinator.finish(third, screenCaptureKitDidTimeOut: false)
        }
    }

    @Test func coordinatorReleasesAdmissionBeforeFinishReturns() throws {
        let coordinator = WindowScreenshotCaptureCoordinator()
        let first = try #require(coordinator.claim())

        coordinator.finish(first, screenCaptureKitDidTimeOut: false)

        let replacement = try #require(coordinator.claim())
        #expect(replacement.id != first.id)
        coordinator.finish(first, screenCaptureKitDidTimeOut: false)
        #expect(coordinator.claim() == nil)
        coordinator.finish(replacement, screenCaptureKitDidTimeOut: false)
        let final = try #require(coordinator.claim())
        coordinator.finish(final, screenCaptureKitDidTimeOut: false)
    }

    @MainActor
    @Test func keyAuxiliaryWindowWinsOverMainTerminalWindow() throws {
        let auxiliaryWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let terminalWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        let selected = WindowScreenshotWindowSelector.select(
            eligibleWindows: [terminalWindow, auxiliaryWindow],
            keyWindow: auxiliaryWindow,
            mainWindow: terminalWindow,
            terminalWindow: terminalWindow
        )

        #expect(selected === auxiliaryWindow)
    }

    @Test func screenshotLabelsCannotCreatePathComponents() {
        #expect(WindowScreenshotLabel("").value == "")
        #expect(
            WindowScreenshotLabel("issue-9065.window").value
                == "issue-9065.window"
        )
        #expect(WindowScreenshotLabel("../../outside/file").value == "outside-file")
        #expect(WindowScreenshotLabel("///").value == "capture")

        let unicodeLabel = WindowScreenshotLabel(String(repeating: "界", count: 80)).value
        #expect(unicodeLabel.utf8.count <= 80)
        #expect(unicodeLabel == String(repeating: "界", count: 26))
    }
}
