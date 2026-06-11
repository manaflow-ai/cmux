import AppKit
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CmuxWebViewContextMenuLinkCaptureTests: XCTestCase {
    override func tearDown() {
        CmuxWebView.contextMenuLinkCaptureAcceptsUntrustedEventsForTesting = false
        super.tearDown()
    }

    // Regression test: "Open Link in Default Browser" must open the link the
    // user actually right-clicked (the DOM contextmenu target), not whatever a
    // later elementFromPoint hit test finds at the AppKit event coordinates.
    // The two diverge under page zoom and inside iframes, which opened the
    // wrong link.
    func testOpenLinkInDefaultBrowserOpensTheLinkUnderTheRightClick() async throws {
        // Tests can only dispatch synthetic (untrusted) contextmenu events;
        // a real right-click produces a trusted one.
        CmuxWebView.contextMenuLinkCaptureAcceptsUntrustedEventsForTesting = true
        let webView = try await makeLoadedTwoLinkWebView()

        // The DOM contextmenu event lands on #clicked, like a real right-click
        // on that link. The NSEvent point below intentionally maps away from
        // #clicked to model the coordinate skew between AppKit space and CSS
        // space (page zoom, iframes); the skew must not change which link
        // opens.
        _ = try await webView.evaluateJavaScript(
            "document.getElementById('clicked').dispatchEvent(new MouseEvent('contextmenu', {bubbles: true})); 0"
        )
        // Extra script-bridge round trips so the capture report has arrived.
        _ = try await webView.evaluateJavaScript("0")
        try await Task.sleep(nanoseconds: 200_000_000)

        let openedURL = try await openLinkInDefaultBrowser(
            webView,
            menuEventLocation: NSPoint(x: 50, y: 550)
        )
        XCTAssertEqual(openedURL?.absoluteString, "https://example.test/clicked")
    }

    // Regression test: a synthetic contextmenu event dispatched by page
    // JavaScript (isTrusted == false) must not be able to plant a decoy link.
    // With the capture ignored, the action falls back to the coordinate hit
    // test at the real menu event point, which is on #decoy here.
    func testSyntheticContextMenuEventCannotPlantDecoyLink() async throws {
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
            menuEventLocation: NSPoint(x: 60, y: 60)
        )
        XCTAssertEqual(openedURL?.absoluteString, "https://example.test/decoy")
    }

    // Regression test: WKWebView is a flipped view on macOS, so view-local
    // points are already top-left-origin. Re-flipping them mirrored the
    // fallback hit test vertically, which resolved links on the opposite side
    // of the page (observed live: right-clicking the top link resolved the
    // bottom link).
    func testCssViewportPointDoesNotReflipFlippedViewCoordinates() {
        _ = NSApplication.shared
        let webView = CmuxWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: WKWebViewConfiguration()
        )
        XCTAssertTrue(webView.isFlipped)

        let css = webView.cssViewportPoint(for: NSPoint(x: 10, y: 10))
        XCTAssertEqual(css.x, 10, accuracy: 0.001)
        XCTAssertEqual(css.y, 10, accuracy: 0.001)

        webView.pageZoom = 2
        let zoomed = webView.cssViewportPoint(for: NSPoint(x: 10, y: 10))
        XCTAssertEqual(zoomed.x, 5, accuracy: 0.001)
        XCTAssertEqual(zoomed.y, 5, accuracy: 0.001)
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

        let loaded = expectation(description: "context menu test page loaded")
        let loadDelegate = ContextMenuLinkTestNavigationDelegate(expectation: loaded)
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
        await fulfillment(of: [loaded], timeout: 10)
        XCTAssertNil(loadDelegate.error)
        return webView
    }

    /// Opens the synthesized context menu at `menuEventLocation` and invokes
    /// "Open Link in Default Browser", returning the URL handed to the opener.
    private func openLinkInDefaultBrowser(
        _ webView: CmuxWebView,
        menuEventLocation: NSPoint
    ) async throws -> URL? {
        let menu = NSMenu()
        let openLinkItem = NSMenuItem(title: "Open Link", action: nil, keyEquivalent: "")
        openLinkItem.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLink")
        menu.addItem(openLinkItem)

        var openedURL: URL?
        webView.contextMenuDefaultBrowserOpener = { url in
            openedURL = url
            return true
        }

        let rightMouseDown = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: menuEventLocation,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1.0
            )
        )
        webView.willOpenMenu(menu, with: rightMouseDown)

        let item = try XCTUnwrap(menu.items.first { $0.title == "Open Link in Default Browser" })
        let action = try XCTUnwrap(item.action)
        _ = NSApp.sendAction(action, to: item.target, from: item)

        let deadline = Date().addingTimeInterval(5)
        while openedURL == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return openedURL
    }
}

private final class ContextMenuLinkTestNavigationDelegate: NSObject, WKNavigationDelegate {
    let expectation: XCTestExpectation
    var error: Error?

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        expectation.fulfill()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error
        expectation.fulfill()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
        expectation.fulfill()
    }
}
