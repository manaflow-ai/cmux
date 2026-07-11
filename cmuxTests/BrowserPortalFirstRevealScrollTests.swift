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

        #expect(!webView.browserPortalHasPendingFirstSizedRevealNudgeForTesting)

        _ = browserLoadRequest(URLRequest(url: URL(fileURLWithPath: #filePath)), in: webView)

        #expect(webView.browserPortalHasPendingFirstSizedRevealNudgeForTesting)
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
        #expect(webView.browserPortalHasPendingFirstSizedRevealNudgeForTesting)

        BrowserWindowPortalRegistry.bind(webView: webView, to: fixture.anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(fixture.anchor)
        await waitForNextMainTurn()

        let slot = try #require(webView.superview as? WindowBrowserSlotView)
        let revealedSize = slot.bounds.size
        let nudgedSize = NSSize(width: revealedSize.width, height: max(1, revealedSize.height - 1))

        #expect(webView.frameSizeCalls.filter { size($0, approximatelyEquals: nudgedSize) }.count == 1)
        #expect(webView.frameSizeCalls.contains { size($0, approximatelyEquals: revealedSize) })
        #expect(size(webView.frame.size, approximatelyEquals: revealedSize))
        #expect(!webView.browserPortalHasPendingFirstSizedRevealNudgeForTesting)
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
        #expect(!webView.browserPortalHasPendingFirstSizedRevealNudgeForTesting)
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
        #expect(!webView.browserPortalHasPendingFirstSizedRevealNudgeForTesting)
    }
}
