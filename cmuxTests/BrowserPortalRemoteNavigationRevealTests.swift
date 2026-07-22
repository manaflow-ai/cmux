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
struct BrowserPortalRemoteNavigationRevealTests {
    private final class RecordingWebView: WKWebView {
        var frameSizeCalls: [NSSize] = []

        override func setFrameSize(_ newSize: NSSize) {
            frameSizeCalls.append(newSize)
            super.setFrameSize(newSize)
        }
    }

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

    @Test func hiddenHTTPSNavigationRevealsWithoutTransientGeometryNudge() async throws {
        let fixture = makeWindowFixture()
        defer {
            fixture.window.orderOut(nil)
            fixture.window.close()
        }
        let webView = RecordingWebView(frame: .zero, configuration: WKWebViewConfiguration())
        defer {
            webView.stopLoading()
            BrowserWindowPortalRegistry.detach(webView: webView)
        }

        let navigationURL = try #require(URL(string: "https://docs.google.com/spreadsheets/d/example/edit"))
        _ = browserLoadRequest(URLRequest(url: navigationURL), in: webView)
        webView.frameSizeCalls.removeAll()

        BrowserWindowPortalRegistry.bind(webView: webView, to: fixture.anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(fixture.anchor)
        await waitForNextMainTurn()

        let slot = try #require(webView.superview as? WindowBrowserSlotView)
        let revealedSize = slot.bounds.size
        let nudgedSize = NSSize(width: revealedSize.width, height: max(1, revealedSize.height - 1))

        #expect(!webView.frameSizeCalls.contains { size($0, approximatelyEquals: nudgedSize) })
        #expect(size(webView.frame.size, approximatelyEquals: revealedSize))
        #expect(!webView.browserPortalNeedsFirstSizedRevealNudge)
    }
}
