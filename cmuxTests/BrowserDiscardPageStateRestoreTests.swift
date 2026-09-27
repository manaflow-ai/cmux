import AppKit
import CmuxBrowser
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/15069:
/// a hidden pane that is discarded for memory must come back with the page
/// state the user left, like a Chrome tab discard: native back/forward
/// history, scroll position, and typed form input. Restoring by replaying the
/// URL loses all three.
@MainActor
final class BrowserDiscardPageStateRestoreTests: XCTestCase {
    private var fixtureDirectory: URL!
    private var hostWindow: NSWindow!
    private var previousDiscardEnabled: Any?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        previousDiscardEnabled = defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-discard-state-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        hostWindow.isReleasedWhenClosed = false
    }

    override func tearDown() {
        hostWindow.orderOut(nil)
        hostWindow = nil
        if let fixtureDirectory {
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }
        let defaults = UserDefaults.standard
        if let previousDiscardEnabled {
            defaults.set(previousDiscardEnabled, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        } else {
            defaults.removeObject(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        }
        super.tearDown()
    }

    func testDiscardedPaneRestoresHistoryScrollAndTypedInput() throws {
        let pageA = fixtureDirectory.appendingPathComponent("a.html")
        let pageB = fixtureDirectory.appendingPathComponent("b.html")
        try "<html><head><title>A</title></head><body>A</body></html>"
            .write(to: pageA, atomically: true, encoding: .utf8)
        try """
        <html><head><title>B</title></head>
        <body style="margin:0">
        <form><input id="name" type="text"><textarea id="notes"></textarea></form>
        <div style="height:6000px;background:linear-gradient(red,blue)"></div>
        </body></html>
        """.write(to: pageB, atomically: true, encoding: .utf8)

        let panel = BrowserPanel(workspaceId: UUID(), initialURL: pageA, isRemoteWorkspace: false)
        defer { panel.close() }
        host(panel.webView)
        waitForPage(panel, url: pageA)

        browserLoadRequest(URLRequest(url: pageB), in: panel.webView)
        waitForPage(panel, url: pageB)

        _ = evaluate(
            """
            (() => {
              for (const [id, value] of [["name", "typed name"], ["notes", "typed notes"]]) {
                const field = document.getElementById(id);
                field.focus();
                field.value = value;
                field.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: value }));
              }
              document.activeElement.blur();
              window.scrollTo(0, 1500);
              return window.scrollY;
            })()
            """,
            in: panel.webView
        )
        waitUntil("page scrolled before hide") {
            (self.evaluate("window.scrollY", in: panel.webView) as? Double) == 1500
        }
        // Let passive page-state observers deliver their script messages.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        panel.noteWebViewVisibility(false, reason: "test.hidden")
        let discardedWebView = panel.webView
        XCTAssertTrue(panel.discardHiddenWebViewForSystemMemoryPressure())
        XCTAssertFalse(panel.webView === discardedWebView)
        XCTAssertEqual(panel.webViewLifecycleState, .discarded)
        discardedWebView.removeFromSuperview()

        host(panel.webView)
        panel.noteWebViewVisibility(true, reason: "test.visible")
        waitForPage(panel, url: pageB, timeout: 10)

        XCTAssertEqual(
            panel.webView.backForwardList.backItem?.url.standardizedFileURL,
            pageA.standardizedFileURL,
            "Restore must bring back the native WebKit back/forward list"
        )
        XCTAssertTrue(panel.webView.canGoBack)
        waitUntil("scroll position restored", timeout: 10) {
            (self.evaluate("window.scrollY", in: panel.webView) as? Double) == 1500
        }
        waitUntil("typed input restored", timeout: 10) {
            (self.evaluate(
                "document.getElementById('name').value + '|' + document.getElementById('notes').value",
                in: panel.webView
            ) as? String) == "typed name|typed notes"
        }
    }

    private func host(_ webView: WKWebView) {
        webView.frame = hostWindow.contentView?.bounds ?? .zero
        webView.autoresizingMask = [.width, .height]
        hostWindow.contentView?.addSubview(webView)
    }

    private func evaluate(_ script: String, in webView: WKWebView) -> Any? {
        var result: Any?
        var finished = false
        webView.evaluateJavaScript(script) { value, _ in
            result = value
            finished = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !finished, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return result
    }

    private func waitForPage(
        _ panel: BrowserPanel,
        url: URL,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitUntil("load of \(url.lastPathComponent)", timeout: timeout, file: file, line: line) {
            panel.webView.url?.standardizedFileURL == url.standardizedFileURL
                && !panel.webView.isLoading
                && panel.webView.backForwardList.currentItem?.url.standardizedFileURL == url.standardizedFileURL
                && !panel.isLoading
        }
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        predicate: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        continueAfterFailure = false
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }
}
