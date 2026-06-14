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
struct CmuxWebViewContextMenuLinkCaptureTests {
    // Regression test: "Open Link in Default Browser" must open the link the
    // user actually right-clicked (the DOM contextmenu target), not whatever a
    // later elementFromPoint hit test finds at the AppKit event coordinates.
    // The two diverge under page zoom and inside iframes, which opened the
    // wrong link.
    @Test
    func openLinkInDefaultBrowserOpensTheLinkUnderTheRightClick() async throws {
        // Tests can only dispatch synthetic (untrusted) contextmenu events;
        // a real right-click produces a trusted one. The flag is baked into
        // the injected script when the web view is created.
        CmuxWebView.contextMenuLinkCaptureAcceptsUntrustedEventsForTesting = true
        defer { CmuxWebView.contextMenuLinkCaptureAcceptsUntrustedEventsForTesting = false }
        let webView = try await makeLoadedTwoLinkWebView()

        // Like a real right-click: the AppKit mouse event happens first, then
        // WebKit dispatches the DOM contextmenu event on #clicked. The NSEvent
        // point below intentionally maps away from #clicked to model the
        // coordinate skew between AppKit space and CSS space (page zoom,
        // iframes); the skew must not change which link opens.
        let mouseEventTimestamp = ProcessInfo.processInfo.systemUptime
        _ = try await webView.evaluateJavaScript(
            "document.getElementById('clicked').dispatchEvent(new MouseEvent('contextmenu', {bubbles: true})); 0"
        )
        // Extra script-bridge round trips so the capture report has arrived.
        _ = try await webView.evaluateJavaScript("0")
        try await Task.sleep(nanoseconds: 200_000_000)

        let openedURL = try await openLinkInDefaultBrowser(
            webView,
            menuEventLocation: NSPoint(x: 50, y: 550),
            menuEventTimestamp: mouseEventTimestamp
        )
        #expect(openedURL?.absoluteString == "https://example.test/clicked")
    }

    // Regression test: a capture left over from a previous right-click must
    // not pair with a menu opened by a later event (keyboard or accessibility
    // menu paths never clear the capture via rightMouseDown). The menu event
    // below is newer than the capture, so the capture is stale and the action
    // must resolve from coordinates instead, which point at #decoy.
    @Test
    func staleCaptureFromPreviousClickIsNotReusedForALaterMenu() async throws {
        CmuxWebView.contextMenuLinkCaptureAcceptsUntrustedEventsForTesting = true
        defer { CmuxWebView.contextMenuLinkCaptureAcceptsUntrustedEventsForTesting = false }
        let webView = try await makeLoadedTwoLinkWebView()

        _ = try await webView.evaluateJavaScript(
            "document.getElementById('clicked').dispatchEvent(new MouseEvent('contextmenu', {bubbles: true})); 0"
        )
        _ = try await webView.evaluateJavaScript("0")
        try await Task.sleep(nanoseconds: 200_000_000)

        let openedURL = try await openLinkInDefaultBrowser(
            webView,
            menuEventLocation: NSPoint(x: 60, y: 60),
            menuEventTimestamp: ProcessInfo.processInfo.systemUptime
        )
        #expect(openedURL?.absoluteString == "https://example.test/decoy")
    }

    // Regression test: a synthetic contextmenu event dispatched by page
    // JavaScript (isTrusted == false) must not be able to plant a decoy link.
    // With the capture ignored, the action falls back to the coordinate hit
    // test at the real menu event point, which is on #decoy here.
    @Test
    func syntheticContextMenuEventCannotPlantDecoyLink() async throws {
        let webView = try await makeLoadedTwoLinkWebView()

        _ = try await webView.evaluateJavaScript(
            "document.getElementById('clicked').dispatchEvent(new MouseEvent('contextmenu', {bubbles: true})); 0"
        )
        _ = try await webView.evaluateJavaScript("0")
        try await Task.sleep(nanoseconds: 200_000_000)

        // (60, 60) is inside #decoy in CSS space; the windowless view-local
        // point is identical because CmuxWebView (WKWebView) is flipped.
        let openedURL = try await openLinkInDefaultBrowser(
            webView,
            menuEventLocation: NSPoint(x: 60, y: 60),
            menuEventTimestamp: ProcessInfo.processInfo.systemUptime
        )
        #expect(openedURL?.absoluteString == "https://example.test/decoy")
    }

    // Regression test: WKWebView is a flipped view on macOS, so view-local
    // points are already top-left-origin. Re-flipping them mirrored the
    // fallback hit test vertically, which resolved links on the opposite side
    // of the page (observed live: right-clicking the top link resolved the
    // bottom link).
    @Test
    func cssViewportPointDoesNotReflipFlippedViewCoordinates() {
        _ = NSApplication.shared
        let webView = CmuxWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: WKWebViewConfiguration()
        )
        #expect(webView.isFlipped)

        let css = webView.cssViewportPoint(for: NSPoint(x: 10, y: 10))
        #expect(abs(css.x - 10) < 0.001)
        #expect(abs(css.y - 10) < 0.001)

        webView.pageZoom = 2
        let zoomed = webView.cssViewportPoint(for: NSPoint(x: 10, y: 10))
        #expect(abs(zoomed.x - 5) < 0.001)
        #expect(abs(zoomed.y - 5) < 0.001)
    }

    // MARK: - Harness

    /// Loads a page with #decoy at CSS (0,0)-(120,120) and #clicked at
    /// CSS (300,300)-(420,420).
    private func makeLoadedTwoLinkWebView() async throws -> CmuxWebView {
        _ = NSApplication.shared
        let webView = CmuxWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: WKWebViewConfiguration()
        )

        let loadDelegate = ContextMenuLinkTestNavigationDelegate()
        webView.navigationDelegate = loadDelegate
        webView.loadHTMLString(
            """
            <!doctype html><html><body style="margin:0">
            <a id="decoy" href="https://example.test/decoy" \
            style="position:fixed;left:0;top:0;width:120px;height:120px;display:block">decoy</a>
            <a id="clicked" href="https://example.test/clicked" \
            style="position:fixed;left:300px;top:300px;width:120px;height:120px;display:block">clicked</a>
            </body></html>
            """,
            baseURL: URL(string: "https://example.test/links")
        )
        let deadline = Date().addingTimeInterval(10)
        while !loadDelegate.finished, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(loadDelegate.finished, "context menu test page did not load")
        #expect(loadDelegate.error == nil)
        webView.navigationDelegate = nil
        return webView
    }

    /// Opens the synthesized context menu at `menuEventLocation` and invokes
    /// "Open Link in Default Browser", returning the URL handed to the opener.
    private func openLinkInDefaultBrowser(
        _ webView: CmuxWebView,
        menuEventLocation: NSPoint,
        menuEventTimestamp: TimeInterval
    ) async throws -> URL? {
        let menu = NSMenu()
        let openLinkItem = NSMenuItem(title: "Open Link", action: nil, keyEquivalent: "")
        openLinkItem.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLink")
        menu.addItem(openLinkItem)

        let opened = OpenedURLBox()
        webView.contextMenuDefaultBrowserOpener = { url in
            opened.url = url
            return true
        }

        let rightMouseDown = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: menuEventLocation,
                modifierFlags: [],
                timestamp: menuEventTimestamp,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1.0
            )
        )
        webView.willOpenMenu(menu, with: rightMouseDown)

        let item = try #require(menu.items.first { $0.title == "Open Link in Default Browser" })
        let action = try #require(item.action)
        _ = NSApp.sendAction(action, to: item.target, from: item)

        let deadline = Date().addingTimeInterval(5)
        while opened.url == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return opened.url
    }
}

@MainActor
private final class OpenedURLBox {
    var url: URL?
}

private final class ContextMenuLinkTestNavigationDelegate: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error
        finished = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
        finished = true
    }
}
