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
struct BrowserPortalFirstRevealScrollTests {
    private final class RecordingWebView: WKWebView {
        var frameSizeCalls: [NSSize] = []

        override func setFrameSize(_ newSize: NSSize) {
            frameSizeCalls.append(newSize)
            super.setFrameSize(newSize)
        }
    }

    private final class WKCompanionTestView: NSView {}

    private struct WindowFixture {
        let window: NSWindow
        let anchor: NSView
    }

    private func makeWindowFixture(anchorFrame: NSRect = NSRect(x: 20, y: 20, width: 300, height: 180)) -> WindowFixture {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
        let window = NSWindow(
            contentRect: contentView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        let anchor = NSView(frame: anchorFrame)
        contentView.addSubview(anchor)
        contentView.layoutSubtreeIfNeeded()
        // The nudge only fires inside a genuinely presented window, so the
        // fixture must be ordered on screen like a real workspace window.
        window.orderFrontRegardless()
        window.displayIfNeeded()
        return WindowFixture(window: window, anchor: anchor)
    }

    private func waitForNextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func size(_ size: NSSize, approximatelyEquals expected: NSSize, epsilon: CGFloat = 0.5) -> Bool {
        abs(size.width - expected.width) <= epsilon &&
            abs(size.height - expected.height) <= epsilon
    }

    @Test func coldFileNavigationStartedWithoutWindowSetsPendingFirstRevealNudge() {
        let webView = RecordingWebView(frame: .zero, configuration: WKWebViewConfiguration())
        defer { webView.stopLoading() }

        #expect(!webView.browserPortalRequiresFirstSizedRevealNudge)

        _ = browserLoadRequest(URLRequest(url: URL(fileURLWithPath: #filePath)), in: webView)

        #expect(webView.browserPortalRequiresFirstSizedRevealNudge)
    }

    @Test func navigationStartedInAlphaZeroBackgroundHostSetsPendingFirstRevealNudge() throws {
        let hostFrame = NSRect(x: -10_000, y: -10_000, width: 800, height: 600)
        let window = NSWindow(
            contentRect: hostFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let contentView = NSView(frame: hostFrame)
        let webView = RecordingWebView(frame: contentView.bounds, configuration: WKWebViewConfiguration())
        contentView.addSubview(webView)
        window.contentView = contentView
        window.orderFrontRegardless()
        defer {
            webView.stopLoading()
            window.orderOut(nil)
            window.close()
        }

        #expect(webView.window === window)
        #expect(webView.frame.width == 800)
        #expect(webView.frame.height == 600)
        #expect(!webView.browserPortalRequiresFirstSizedRevealNudge)

        let navigationURL = try #require(URL(string: "about:blank"))
        _ = browserLoadRequest(URLRequest(url: navigationURL), in: webView)

        #expect(webView.browserPortalRequiresFirstSizedRevealNudge)
    }

    @Test func navigationStartedInSizedButOrderedOutWindowSetsPendingFirstRevealNudge() throws {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
        let window = NSWindow(
            contentRect: contentView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        let webView = RecordingWebView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 180),
            configuration: WKWebViewConfiguration()
        )
        contentView.addSubview(webView)
        defer {
            webView.stopLoading()
            window.close()
        }

        #expect(webView.window === window)
        #expect(!window.isVisible)
        #expect(!webView.browserPortalRequiresFirstSizedRevealNudge)

        let navigationURL = try #require(URL(string: "about:blank"))
        _ = browserLoadRequest(URLRequest(url: navigationURL), in: webView)

        #expect(webView.browserPortalRequiresFirstSizedRevealNudge)
    }

    @Test func nudgeStaysPendingWhileWindowIsNotPresented() async {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
        let window = NSWindow(
            contentRect: contentView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        let webView = RecordingWebView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 180),
            configuration: WKWebViewConfiguration()
        )
        contentView.addSubview(webView)
        defer {
            window.orderOut(nil)
            window.close()
        }

        webView.browserPortalNotifyHidden(reason: "unitTestOrderedOut")
        webView.frameSizeCalls.removeAll()
        #expect(!window.isVisible)

        let firedWhileOrderedOut = webView.browserPortalApplyFirstSizedRevealGeometryNudgeIfNeeded(
            reason: "unitTestOrderedOut",
            hasCompanionWKSubviews: false,
            managedByExternalFullscreenWindow: false
        )

        #expect(!firedWhileOrderedOut)
        #expect(webView.frameSizeCalls.isEmpty)
        #expect(webView.browserPortalRequiresFirstSizedRevealNudge)

        window.orderFrontRegardless()
        let firedOnceRevealed = webView.browserPortalApplyFirstSizedRevealGeometryNudgeIfNeeded(
            reason: "unitTestOrderedOut",
            hasCompanionWKSubviews: false,
            managedByExternalFullscreenWindow: false
        )
        await waitForNextMainTurn()

        #expect(firedOnceRevealed)
        #expect(!webView.frameSizeCalls.isEmpty)
        #expect(!webView.browserPortalRequiresFirstSizedRevealNudge)
        #expect(size(webView.frame.size, approximatelyEquals: NSSize(width: 300, height: 180)))
    }

    @Test func navigationStartedInVisibleSizedWindowDoesNotSetPendingFirstRevealNudge() throws {
        let fixture = makeWindowFixture()
        let webView = RecordingWebView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 180),
            configuration: WKWebViewConfiguration()
        )
        fixture.window.contentView?.addSubview(webView)
        fixture.window.orderFrontRegardless()
        defer {
            webView.stopLoading()
            fixture.window.orderOut(nil)
            fixture.window.close()
        }

        #expect(webView.window === fixture.window)
        #expect(fixture.window.alphaValue > 0.01)
        #expect(!webView.browserPortalRequiresFirstSizedRevealNudge)

        let navigationURL = try #require(URL(string: "about:blank"))
        _ = browserLoadRequest(URLRequest(url: navigationURL), in: webView)

        #expect(!webView.browserPortalRequiresFirstSizedRevealNudge)
    }

    @Test func hiddenHostRevealThroughPortalNudgesFrameOnceAndClearsFlag() async throws {
        let fixture = makeWindowFixture()
        defer { fixture.window.orderOut(nil) }
        let focusView = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        fixture.window.contentView?.addSubview(focusView)
        #expect(fixture.window.makeFirstResponder(focusView))
        let firstResponder = fixture.window.firstResponder
        let webView = RecordingWebView(frame: .zero, configuration: WKWebViewConfiguration())
        defer { BrowserWindowPortalRegistry.detach(webView: webView) }

        webView.browserPortalPrepareForHiddenHostAdoption()
        #expect(webView.browserPortalRequiresFirstSizedRevealNudge)

        BrowserWindowPortalRegistry.bind(webView: webView, to: fixture.anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(fixture.anchor)
        await waitForNextMainTurn()

        let slot = try #require(webView.superview as? WindowBrowserSlotView)
        let revealedSize = slot.bounds.size
        let nudgedSize = NSSize(width: revealedSize.width, height: max(1, revealedSize.height - 1))

        #expect(webView.frameSizeCalls.filter { size($0, approximatelyEquals: nudgedSize) }.count == 1)
        #expect(webView.frameSizeCalls.contains { size($0, approximatelyEquals: revealedSize) })
        #expect(size(webView.frame.size, approximatelyEquals: revealedSize))
        #expect(!webView.browserPortalRequiresFirstSizedRevealNudge)
        #expect(fixture.window.firstResponder === firstResponder)

        webView.frameSizeCalls.removeAll()
        BrowserWindowPortalRegistry.synchronizeForAnchor(fixture.anchor)
        await waitForNextMainTurn()

        #expect(!webView.frameSizeCalls.contains { size($0, approximatelyEquals: nudgedSize) })
        #expect(fixture.window.firstResponder === firstResponder)
    }

    @Test func companionWebKitSubviewSkipsAndClearsPendingNudge() async {
        let fixture = makeWindowFixture()
        defer { fixture.window.orderOut(nil) }
        let webView = RecordingWebView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 180),
            configuration: WKWebViewConfiguration()
        )
        fixture.window.contentView?.addSubview(webView)
        webView.browserPortalNotifyHidden(reason: "unitTestCompanion")
        webView.frameSizeCalls.removeAll()

        let fired = webView.browserPortalApplyFirstSizedRevealGeometryNudgeIfNeeded(
            reason: "unitTestCompanion",
            hasCompanionWKSubviews: true,
            managedByExternalFullscreenWindow: false
        )
        await waitForNextMainTurn()

        #expect(!fired)
        #expect(webView.frameSizeCalls.isEmpty)
        #expect(!webView.browserPortalRequiresFirstSizedRevealNudge)
    }

    @Test func slotCompanionDetectionMatchesDockedWebKitSubviewCondition() throws {
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        let webView = RecordingWebView(frame: slot.bounds, configuration: WKWebViewConfiguration())
        slot.addSubview(webView)

        #expect(!slot.hasVisibleWebKitCompanionSubview(for: webView))

        let companion = WKCompanionTestView(frame: NSRect(x: 0, y: 0, width: 60, height: 180))
        slot.addSubview(companion)

        #expect(slot.hasVisibleWebKitCompanionSubview(for: webView))
    }

    @Test func externalFullscreenWindowSkipsAndClearsPendingNudge() async {
        let fixture = makeWindowFixture()
        defer { fixture.window.orderOut(nil) }
        let webView = RecordingWebView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 180),
            configuration: WKWebViewConfiguration()
        )
        fixture.window.contentView?.addSubview(webView)
        webView.browserPortalNotifyHidden(reason: "unitTestExternalFullscreen")
        webView.frameSizeCalls.removeAll()

        let fired = webView.browserPortalApplyFirstSizedRevealGeometryNudgeIfNeeded(
            reason: "unitTestExternalFullscreen",
            hasCompanionWKSubviews: false,
            managedByExternalFullscreenWindow: true
        )
        await waitForNextMainTurn()

        #expect(!fired)
        #expect(webView.frameSizeCalls.isEmpty)
        #expect(!webView.browserPortalRequiresFirstSizedRevealNudge)
    }
}
