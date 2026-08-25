import AppKit
import AVKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class WindowScreenshotTestOwnedOverlay: NSView,
    WindowScreenshotOwnedNativeOverlay {}

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

    @Test func coordinatorBoundsBackendLifetimesIndependently() throws {
        let coordinator = WindowScreenshotCaptureCoordinator()
        let appKitLease = try #require(coordinator.claimAppKit())
        let screenCaptureKitLease = try #require(
            coordinator.claimScreenCaptureKit()
        )
        #expect(coordinator.claimAppKit() == nil)
        #expect(coordinator.claimScreenCaptureKit() == nil)

        appKitLease.retire()
        let replacementAppKitLease = try #require(coordinator.claimAppKit())
        appKitLease.retire()
        #expect(coordinator.claimAppKit() == nil)
        #expect(coordinator.claimScreenCaptureKit() == nil)

        replacementAppKitLease.retire()
        screenCaptureKitLease.retire()
    }

    @Test func screenCapturePolicyRequiresExistingAccessWithoutCurrentProcessAPI() {
        let legacyWithoutAccess = WindowScreenshotScreenCapturePolicy(
            currentProcessAPIAvailable: false,
            screenCaptureAccessGranted: false
        )
        let legacyWithAccess = WindowScreenshotScreenCapturePolicy(
            currentProcessAPIAvailable: false,
            screenCaptureAccessGranted: true
        )
        let currentProcessAPI = WindowScreenshotScreenCapturePolicy(
            currentProcessAPIAvailable: true,
            screenCaptureAccessGranted: false
        )

        #expect(!legacyWithoutAccess.allowsScreenCaptureKit)
        #expect(legacyWithAccess.allowsScreenCaptureKit)
        #expect(currentProcessAPI.allowsScreenCaptureKit)
    }

    @MainActor
    @Test func ownedBrowserOverlaysExcludeUnownedWebKitSubviews() {
        let webView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let webKitInternalView = NSView(frame: webView.bounds)
        let ownedOverlay = WindowScreenshotTestOwnedOverlay(frame: webView.bounds)
        webView.addSubview(webKitInternalView)
        webView.addSubview(ownedOverlay)

        let candidates = WindowAppKitCapture.ownedNativeOverlayCandidates(
            inside: webView
        )

        #expect(candidates.count == 1)
        #expect(candidates.first === ownedOverlay)
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

    @MainActor
    @Test func appKitCaptureRootIncludesNativeWindowChrome() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let contentView = try #require(window.contentView)

        let captureRoot = try #require(WindowAppKitCapture.rootView(for: window))

        #expect(captureRoot !== contentView)
        #expect(contentView.isDescendant(of: captureRoot))
        #expect(captureRoot.bounds.height > contentView.bounds.height)
    }

    @MainActor
    @Test func overlayVisibleRectHonorsClippingAncestors() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let clippingAncestor = NSView(
            frame: NSRect(x: 10, y: 20, width: 40, height: 30)
        )
        clippingAncestor.clipsToBounds = true
        let externalView = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 70))
        root.addSubview(clippingAncestor)
        clippingAncestor.addSubview(externalView)

        let visibleRect = try #require(
            WindowAppKitCapture.visibleRect(of: externalView, through: root)
        )

        #expect(visibleRect == NSRect(x: 10, y: 20, width: 40, height: 30))
    }

    @MainActor
    @Test func detectsSystemCompositorBackedPanelContent() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let playerView = AVPlayerView(frame: root.bounds)
        root.addSubview(playerView)

        #expect(WindowAppKitCapture.containsSystemCompositorContent(in: root))
    }

    @MainActor
    @Test func preservesNativeChildrenAboveExternalSurfaceImages() {
        let externalSurface = NSView(
            frame: NSRect(x: 0, y: 0, width: 100, height: 100)
        )
        let nativeCursorOverlay = NSView(
            frame: NSRect(x: 10, y: 20, width: 2, height: 18)
        )
        externalSurface.addSubview(nativeCursorOverlay)

        let candidates = WindowAppKitCapture.nativeOverlayCandidates(
            inside: externalSurface
        )

        #expect(candidates.count == 1)
        #expect(candidates.first === nativeCursorOverlay)
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
