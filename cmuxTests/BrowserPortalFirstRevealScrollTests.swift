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

        #expect(!webView.browserPortalNeedsFirstSizedRevealNudge)

        _ = browserLoadRequest(URLRequest(url: URL(fileURLWithPath: #filePath)), in: webView)

        #expect(webView.browserPortalNeedsFirstSizedRevealNudge)
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
        #expect(!webView.browserPortalNeedsFirstSizedRevealNudge)

        let navigationURL = try #require(URL(string: "about:blank"))
        _ = browserLoadRequest(URLRequest(url: navigationURL), in: webView)

        #expect(webView.browserPortalNeedsFirstSizedRevealNudge)
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
        #expect(!webView.browserPortalNeedsFirstSizedRevealNudge)

        let navigationURL = try #require(URL(string: "about:blank"))
        _ = browserLoadRequest(URLRequest(url: navigationURL), in: webView)

        #expect(!webView.browserPortalNeedsFirstSizedRevealNudge)
    }

    @Test func navigationStartedInHiddenFullSizedSlotSetsPendingFirstRevealNudge() throws {
        let fixture = makeWindowFixture()
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        let webView = RecordingWebView(frame: slot.bounds, configuration: WKWebViewConfiguration())
        slot.addSubview(webView)
        fixture.window.contentView?.addSubview(slot)
        slot.isHidden = true
        fixture.window.orderFrontRegardless()
        defer {
            webView.stopLoading()
            fixture.window.orderOut(nil)
            fixture.window.close()
        }

        #expect(webView.window === fixture.window)
        #expect(fixture.window.alphaValue > 0.01)
        #expect(webView.frame.width == 300)
        #expect(webView.frame.height == 180)
        #expect(webView.isHiddenOrHasHiddenAncestor)
        #expect(!webView.browserPortalNeedsFirstSizedRevealNudge)

        let navigationURL = try #require(URL(string: "about:blank"))
        _ = browserLoadRequest(URLRequest(url: navigationURL), in: webView)

        #expect(webView.browserPortalNeedsFirstSizedRevealNudge)
    }

    @Test func orderedOutWindowMarksAndDefersPendingNudgeUntilVisible() async {
        let fixture = makeWindowFixture()
        defer {
            fixture.window.orderOut(nil)
            fixture.window.close()
        }
        let webView = RecordingWebView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 180),
            configuration: WKWebViewConfiguration()
        )
        fixture.window.contentView?.addSubview(webView)
        fixture.window.orderOut(nil)

        #expect(!fixture.window.isVisible)
        webView.browserPortalMarkFirstSizedRevealNudgeIfNavigationStartsWithoutPresentation(
            reason: "unitTestOrderedOutNavigation"
        )
        #expect(webView.browserPortalNeedsFirstSizedRevealNudge)
        #expect(!webView.browserPortalApplyFirstSizedRevealGeometryNudgeIfNeeded(
            reason: "unitTestOrderedOutReveal",
            hasCompanionWKSubviews: false,
            managedByExternalFullscreenWindow: false
        ))
        #expect(webView.browserPortalNeedsFirstSizedRevealNudge)

        fixture.window.orderFrontRegardless()
        #expect(fixture.window.isVisible)
        #expect(webView.browserPortalApplyFirstSizedRevealGeometryNudgeIfNeeded(
            reason: "unitTestOrderedInReveal",
            hasCompanionWKSubviews: false,
            managedByExternalFullscreenWindow: false
        ))
        await waitForNextMainTurn()
        #expect(!webView.browserPortalNeedsFirstSizedRevealNudge)
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
        #expect(webView.browserPortalNeedsFirstSizedRevealNudge)

        BrowserWindowPortalRegistry.bind(webView: webView, to: fixture.anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(fixture.anchor)
        await waitForNextMainTurn()

        let slot = try #require(webView.superview as? WindowBrowserSlotView)
        let revealedSize = slot.bounds.size
        let nudgedSize = NSSize(width: revealedSize.width, height: max(1, revealedSize.height - 1))

        #expect(webView.frameSizeCalls.filter { size($0, approximatelyEquals: nudgedSize) }.count == 1)
        #expect(webView.frameSizeCalls.contains { size($0, approximatelyEquals: revealedSize) })
        #expect(size(webView.frame.size, approximatelyEquals: revealedSize))
        #expect(!webView.browserPortalNeedsFirstSizedRevealNudge)
        #expect(fixture.window.firstResponder === firstResponder)

        webView.frameSizeCalls.removeAll()
        BrowserWindowPortalRegistry.synchronizeForAnchor(fixture.anchor)
        await waitForNextMainTurn()

        #expect(!webView.frameSizeCalls.contains { size($0, approximatelyEquals: nudgedSize) })
        #expect(fixture.window.firstResponder === firstResponder)
    }

    @Test func hiddenHostRevealThroughLocalInlineHostNudgesFrameOnceAndClearsFlag() async throws {
        let fixture = makeWindowFixture()
        defer { fixture.window.orderOut(nil) }
        let host = WebViewRepresentable.HostContainerView(frame: fixture.anchor.frame)
        fixture.window.contentView?.addSubview(host)
        let slot = host.ensureLocalInlineSlotView()
        host.layoutSubtreeIfNeeded()

        let webView = RecordingWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.browserPortalPrepareForHiddenHostAdoption()
        #expect(webView.browserPortalRequiresRenderingStateReattach)
        slot.addSubview(webView)
        host.pinHostedWebView(webView, in: slot)
        webView.frameSizeCalls.removeAll()

        host.refreshHostedWebKitPresentation(reason: "unitTestLocalInlineReveal")
        await waitForNextMainTurn()

        let revealedSize = slot.bounds.size
        let nudgedSize = NSSize(width: revealedSize.width, height: max(1, revealedSize.height - 1))
        #expect(webView.frameSizeCalls.filter { size($0, approximatelyEquals: nudgedSize) }.count == 1)
        #expect(webView.frameSizeCalls.contains { size($0, approximatelyEquals: revealedSize) })
        #expect(size(webView.frame.size, approximatelyEquals: revealedSize))
        #expect(!webView.browserPortalRequiresRenderingStateReattach)
        #expect(!webView.browserPortalNeedsFirstSizedRevealNudge)

        webView.frameSizeCalls.removeAll()
        host.refreshHostedWebKitPresentation(reason: "unitTestLocalInlineRevealAgain")
        await waitForNextMainTurn()

        #expect(!webView.frameSizeCalls.contains { size($0, approximatelyEquals: nudgedSize) })
    }

    @Test func localInlineHostDefersNudgeUntilViewAndWindowAreVisible() async {
        let fixture = makeWindowFixture()
        defer { fixture.window.orderOut(nil) }
        let host = WebViewRepresentable.HostContainerView(frame: fixture.anchor.frame)
        fixture.window.contentView?.addSubview(host)
        let slot = host.ensureLocalInlineSlotView()
        host.layoutSubtreeIfNeeded()

        let webView = RecordingWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.browserPortalPrepareForHiddenHostAdoption()
        slot.addSubview(webView)
        host.pinHostedWebView(webView, in: slot)
        webView.frameSizeCalls.removeAll()
        let revealedSize = slot.bounds.size
        let nudgedSize = NSSize(width: revealedSize.width, height: max(1, revealedSize.height - 1))

        host.isHidden = true
        host.refreshHostedWebKitPresentation(reason: "unitTestLocalInlineHiddenAncestor")

        #expect(webView.browserPortalNeedsFirstSizedRevealNudge)
        #expect(!webView.frameSizeCalls.contains { size($0, approximatelyEquals: nudgedSize) })

        host.isHidden = false
        fixture.window.alphaValue = 0
        host.refreshHostedWebKitPresentation(reason: "unitTestLocalInlineAlphaZeroWindow")

        #expect(webView.browserPortalNeedsFirstSizedRevealNudge)
        #expect(!webView.frameSizeCalls.contains { size($0, approximatelyEquals: nudgedSize) })

        fixture.window.alphaValue = 1
        host.refreshHostedWebKitPresentation(reason: "unitTestLocalInlineVisibleReveal")
        await waitForNextMainTurn()

        #expect(webView.frameSizeCalls.filter { size($0, approximatelyEquals: nudgedSize) }.count == 1)
        #expect(webView.frameSizeCalls.contains { size($0, approximatelyEquals: revealedSize) })
        #expect(size(webView.frame.size, approximatelyEquals: revealedSize))
        #expect(!webView.browserPortalNeedsFirstSizedRevealNudge)
    }

    @Test func localInlineHostCompanionSkipsAndClearsPendingNudge() async {
        let fixture = makeWindowFixture()
        defer { fixture.window.orderOut(nil) }
        let host = WebViewRepresentable.HostContainerView(frame: fixture.anchor.frame)
        fixture.window.contentView?.addSubview(host)
        let slot = host.ensureLocalInlineSlotView()
        host.layoutSubtreeIfNeeded()

        let webView = RecordingWebView(frame: slot.bounds, configuration: WKWebViewConfiguration())
        slot.addSubview(webView)
        host.pinHostedWebView(webView, in: slot)
        let companion = WKCompanionTestView(frame: NSRect(x: 0, y: 0, width: 60, height: slot.bounds.height))
        slot.addSubview(companion)
        webView.browserPortalNotifyHidden(reason: "unitTestLocalInlineCompanion")
        webView.frameSizeCalls.removeAll()

        host.refreshHostedWebKitPresentation(reason: "unitTestLocalInlineCompanion")
        await waitForNextMainTurn()

        let nudgedSize = NSSize(width: slot.bounds.width, height: max(1, slot.bounds.height - 1))
        #expect(!webView.frameSizeCalls.contains { size($0, approximatelyEquals: nudgedSize) })
        #expect(!webView.browserPortalNeedsFirstSizedRevealNudge)
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
        #expect(!webView.browserPortalNeedsFirstSizedRevealNudge)
    }

    @Test func slotCompanionDetectionMatchesDockedWebKitSubviewCondition() throws {
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        let webView = RecordingWebView(frame: slot.bounds, configuration: WKWebViewConfiguration())
        slot.addSubview(webView)

        #expect(!slot.browserPortalHasVisibleWebKitCompanionSubview(for: webView))

        let companion = WKCompanionTestView(frame: NSRect(x: 0, y: 0, width: 60, height: 180))
        slot.addSubview(companion)

        #expect(slot.browserPortalHasVisibleWebKitCompanionSubview(for: webView))
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
        #expect(!webView.browserPortalNeedsFirstSizedRevealNudge)
    }

    @Test func noDeltaAtMinimumHeightKeepsPendingNudgeForLaterSizedReveal() async {
        let fixture = makeWindowFixture()
        defer { fixture.window.orderOut(nil) }
        let webView = RecordingWebView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 1.25),
            configuration: WKWebViewConfiguration()
        )
        fixture.window.contentView?.addSubview(webView)
        webView.browserPortalNotifyHidden(reason: "unitTestNoDelta")
        webView.frameSizeCalls.removeAll()

        let firedAtMinimumHeight = webView.browserPortalApplyFirstSizedRevealGeometryNudgeIfNeeded(
            reason: "unitTestNoDelta",
            hasCompanionWKSubviews: false,
            managedByExternalFullscreenWindow: false
        )

        #expect(!firedAtMinimumHeight)
        #expect(webView.browserPortalNeedsFirstSizedRevealNudge)
        #expect(webView.frameSizeCalls.isEmpty)

        let revealedSize = NSSize(width: 300, height: 180)
        webView.setFrameSize(revealedSize)
        webView.frameSizeCalls.removeAll()
        let firedAfterSizing = webView.browserPortalApplyFirstSizedRevealGeometryNudgeIfNeeded(
            reason: "unitTestNoDeltaRetry",
            hasCompanionWKSubviews: false,
            managedByExternalFullscreenWindow: false
        )
        await waitForNextMainTurn()

        let nudgedSize = NSSize(width: revealedSize.width, height: revealedSize.height - 1)
        #expect(firedAfterSizing)
        #expect(webView.frameSizeCalls.contains { size($0, approximatelyEquals: nudgedSize) })
        #expect(size(webView.frame.size, approximatelyEquals: revealedSize))
        #expect(!webView.browserPortalNeedsFirstSizedRevealNudge)
    }

    @Test func nextTurnRestoreSurvivesOriginChange() async {
        let fixture = makeWindowFixture()
        defer { fixture.window.orderOut(nil) }
        let originalFrame = NSRect(x: 0, y: 0, width: 300, height: 180)
        let webView = RecordingWebView(
            frame: originalFrame,
            configuration: WKWebViewConfiguration()
        )
        fixture.window.contentView?.addSubview(webView)
        webView.browserPortalNotifyHidden(reason: "unitTestOriginChangeRestore")

        let fired = webView.browserPortalApplyFirstSizedRevealGeometryNudgeIfNeeded(
            reason: "unitTestOriginChangeRestore",
            hasCompanionWKSubviews: false,
            managedByExternalFullscreenWindow: false
        )
        let movedOrigin = NSPoint(x: 25, y: 30)
        webView.setFrameOrigin(movedOrigin)
        await waitForNextMainTurn()

        #expect(fired)
        #expect(webView.frame.origin == movedOrigin)
        #expect(size(webView.frame.size, approximatelyEquals: originalFrame.size))
    }

    @Test func nextTurnRestoreSurvivesDetachment() async {
        let fixture = makeWindowFixture()
        defer { fixture.window.orderOut(nil) }
        let originalSize = NSSize(width: 300, height: 180)
        let webView = RecordingWebView(
            frame: NSRect(origin: .zero, size: originalSize),
            configuration: WKWebViewConfiguration()
        )
        fixture.window.contentView?.addSubview(webView)
        webView.browserPortalNotifyHidden(reason: "unitTestDetachmentRestore")

        let fired = webView.browserPortalApplyFirstSizedRevealGeometryNudgeIfNeeded(
            reason: "unitTestDetachmentRestore",
            hasCompanionWKSubviews: false,
            managedByExternalFullscreenWindow: false
        )
        webView.removeFromSuperview()
        await waitForNextMainTurn()

        #expect(fired)
        #expect(webView.window == nil)
        #expect(size(webView.frame.size, approximatelyEquals: originalSize))
    }

    @Test func nextTurnRestoreDoesNotOverwriteRealSizeChange() async {
        let fixture = makeWindowFixture()
        defer { fixture.window.orderOut(nil) }
        let webView = RecordingWebView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 180),
            configuration: WKWebViewConfiguration()
        )
        fixture.window.contentView?.addSubview(webView)
        webView.browserPortalNotifyHidden(reason: "unitTestRealSizeChange")

        let fired = webView.browserPortalApplyFirstSizedRevealGeometryNudgeIfNeeded(
            reason: "unitTestRealSizeChange",
            hasCompanionWKSubviews: false,
            managedByExternalFullscreenWindow: false
        )
        let resizedSize = NSSize(width: 320, height: 200)
        webView.setFrameSize(resizedSize)
        await waitForNextMainTurn()

        #expect(fired)
        #expect(size(webView.frame.size, approximatelyEquals: resizedSize))
    }
}
