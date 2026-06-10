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
    // Regression test: "Open Link in Default Browser" must open the link the
    // user actually right-clicked (the DOM contextmenu target), not whatever a
    // later elementFromPoint hit test finds at the AppKit event coordinates.
    // The two diverge under page zoom and inside iframes, which opened the
    // wrong link.
    func testOpenLinkInDefaultBrowserOpensTheLinkUnderTheRightClick() async throws {
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

        // The DOM contextmenu event lands on #clicked, like a real right-click
        // on that link. The NSEvent point below intentionally maps to #decoy to
        // model the coordinate skew between AppKit space and CSS space (page
        // zoom, iframes); the skew must not change which link opens.
        _ = try await webView.evaluateJavaScript(
            "document.getElementById('clicked').dispatchEvent(new MouseEvent('contextmenu', {bubbles: true})); 0"
        )
        // Extra script-bridge round trips so the capture report has arrived.
        _ = try await webView.evaluateJavaScript("0")
        try await Task.sleep(nanoseconds: 200_000_000)

        let menu = NSMenu()
        let openLinkItem = NSMenuItem(title: "Open Link", action: nil, keyEquivalent: "")
        openLinkItem.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLink")
        menu.addItem(openLinkItem)

        var openedURL: URL?
        webView.contextMenuDefaultBrowserOpener = { url in
            openedURL = url
            return true
        }

        // View-local (50, 550) in AppKit bottom-left coordinates is CSS
        // (50, 50), inside #decoy.
        guard let rightMouseDown = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 50, y: 550),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            XCTFail("Failed to create rightMouseDown event")
            return
        }
        webView.willOpenMenu(menu, with: rightMouseDown)

        let item = try XCTUnwrap(menu.items.first { $0.title == "Open Link in Default Browser" })
        let action = try XCTUnwrap(item.action)
        _ = NSApp.sendAction(action, to: item.target, from: item)

        let deadline = Date().addingTimeInterval(5)
        while openedURL == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(openedURL?.absoluteString, "https://example.test/clicked")
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
