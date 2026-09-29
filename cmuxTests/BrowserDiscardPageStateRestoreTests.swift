import AppKit
import CmuxBrowser
import CmuxCore
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
    var fixtureDirectory: URL!
    private var hostWindow: NSWindow!
    /// The stored `browser.autoRestoreUnloadedPages` key, spelled out so a
    /// rename that would drop users' saved choice fails here.
    private static let autoRestoreKey = "browserAutoRestoreUnloadedPages"

    private var previousDiscardEnabled: Any?
    private var previousAutoRestore: Any?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        previousDiscardEnabled = defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        previousAutoRestore = defaults.object(forKey: Self.autoRestoreKey)
        defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        defaults.removeObject(forKey: Self.autoRestoreKey)
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
        if let previousAutoRestore {
            defaults.set(previousAutoRestore, forKey: Self.autoRestoreKey)
        } else {
            defaults.removeObject(forKey: Self.autoRestoreKey)
        }
        super.tearDown()
    }

    func testDiscardedPaneRestoresHistoryScrollAndTypedInput() async throws {
        let (panel, pageA, pageB) = try await loadScrolledFormPage()
        defer { panel.close() }

        panel.noteWebViewVisibility(false, reason: "test.hidden")
        let discardedWebView = panel.webView
        XCTAssertTrue(panel.discardHiddenWebViewForSystemMemoryPressure())
        XCTAssertFalse(panel.webView === discardedWebView)
        XCTAssertEqual(panel.webViewLifecycleState, .discarded)
        discardedWebView.removeFromSuperview()

        host(panel.webView)
        panel.noteWebViewVisibility(true, reason: "test.visible")
        await assertRestoredPageState(panel, pageA: pageA, pageB: pageB)
    }

    /// A WebContent process that dies while its pane is hidden must not cost
    /// the page: the pane restores its last session state when shown, instead
    /// of waiting behind the manual Reload overlay and reloading the URL.
    func testHiddenWebContentTerminationRestoresPageStateOnReveal() async throws {
        let (panel, pageA, pageB) = try await loadScrolledFormPage()
        defer { panel.close() }

        panel.noteWebViewVisibility(false, reason: "test.hidden")
        let terminatedWebView = try terminateWebContent(of: panel)
        terminatedWebView.removeFromSuperview()

        panel.noteWebViewVisibility(true, reason: "test.visible")
        XCTAssertFalse(panel.hasRecoverableWebContentTermination)
        XCTAssertFalse(panel.webView === terminatedWebView)
        host(panel.webView)
        await assertRestoredPageState(panel, pageA: pageA, pageB: pageB)
    }

    /// A load that had not committed when the process died is not what the
    /// user was looking at, so it must not turn the restore into a reload.
    func testHiddenTerminationDuringUnfinishedLoadRestoresCommittedPage() async throws {
        let (panel, pageA, pageB) = try await loadScrolledFormPage()
        defer { panel.close() }
        let pageC = fixtureDirectory.appendingPathComponent("c.html")
        try "<html><head><title>C</title></head><body>C</body></html>"
            .write(to: pageC, atomically: true, encoding: .utf8)

        panel.noteWebViewVisibility(false, reason: "test.hidden")
        panel.navigationDelegate?.recordAttemptedRequest(URLRequest(url: pageC))
        panel.isMainFrameProvisionalNavigationActive = true
        let terminatedWebView = try terminateWebContent(of: panel)
        terminatedWebView.removeFromSuperview()

        panel.noteWebViewVisibility(true, reason: "test.visible")
        XCTAssertFalse(panel.hasRecoverableWebContentTermination)
        host(panel.webView)
        await assertRestoredPageState(panel, pageA: pageA, pageB: pageB)
    }

    /// With automatic restore off (https://github.com/manaflow-ai/cmux/issues/9561),
    /// showing a discarded pane must not load anything until the user asks,
    /// and that restore still brings back the page state.
    func testManualRestoreModeWaitsForUserBeforeRestoringPageState() async throws {
        UserDefaults.standard.set(false, forKey: Self.autoRestoreKey)
        let (panel, pageA, pageB) = try await loadScrolledFormPage()
        defer { panel.close() }

        panel.noteWebViewVisibility(false, reason: "test.hidden")
        let discardedWebView = panel.webView
        XCTAssertTrue(panel.discardHiddenWebViewForSystemMemoryPressure())
        discardedWebView.removeFromSuperview()

        host(panel.webView)
        panel.noteWebViewVisibility(true, reason: "test.visible")
        await assertWaitsForManualRestore(panel, instead: pageB)

        panel.restoreDiscardedWebViewIfNeeded(reason: "test.manual_restore")
        await assertRestoredPageState(panel, pageA: pageA, pageB: pageB)
    }

    /// A page whose WebContent process died while hidden waits the same way.
    func testManualRestoreModeHoldsPageTerminatedWhileHidden() async throws {
        UserDefaults.standard.set(false, forKey: Self.autoRestoreKey)
        let (panel, pageA, pageB) = try await loadScrolledFormPage()
        defer { panel.close() }

        panel.noteWebViewVisibility(false, reason: "test.hidden")
        let terminatedWebView = try terminateWebContent(of: panel)
        terminatedWebView.removeFromSuperview()

        panel.noteWebViewVisibility(true, reason: "test.visible")
        XCTAssertFalse(panel.hasRecoverableWebContentTermination)
        XCTAssertFalse(panel.webView === terminatedWebView)
        host(panel.webView)
        await assertWaitsForManualRestore(panel, instead: pageB)

        panel.restoreDiscardedWebViewIfNeeded(reason: "test.manual_restore")
        await assertRestoredPageState(panel, pageA: pageA, pageB: pageB)
    }

    /// Stop keeps a shown pane from reloading, but a WebContent process that
    /// dies while hidden leaves no live page for Stop to keep.
    func testHiddenTerminationAfterStopRestoresPageStateOnReveal() async throws {
        let (panel, pageA, pageB) = try await loadScrolledFormPage()
        defer { panel.close() }

        panel.stopLoading()
        panel.noteWebViewVisibility(false, reason: "test.hidden")
        let terminatedWebView = try terminateWebContent(of: panel)
        terminatedWebView.removeFromSuperview()

        panel.noteWebViewVisibility(true, reason: "test.visible")
        XCTAssertFalse(panel.hasRecoverableWebContentTermination)
        XCTAssertFalse(panel.webView === terminatedWebView)
        host(panel.webView)
        await assertRestoredPageState(panel, pageA: pageA, pageB: pageB)
    }

    /// A remote workspace pane restores by loading its URL, which waits while
    /// the workspace's proxy is reconnecting. The typed input must still come
    /// back once that queued load runs.
    func testRemotePaneRestoreQueuedForProxyRefillsTypedInput() async throws {
        let endpoint = BrowserProxyEndpoint(
            host: "127.0.0.1",
            port: 9876,
            credential: .random()
        )
        let (panel, _, pageB) = try await loadScrolledFormPage { url in
            let workspaceId = UUID()
            return BrowserPanel(
                workspaceId: workspaceId,
                initialURL: url,
                proxyEndpoint: endpoint,
                isRemoteWorkspace: true,
                remoteWebsiteDataStoreIdentifier: workspaceId
            )
        }
        defer { panel.close() }

        panel.noteWebViewVisibility(false, reason: "test.hidden")
        let discardedWebView = panel.webView
        XCTAssertTrue(panel.discardHiddenWebViewForSystemMemoryPressure())
        discardedWebView.removeFromSuperview()

        panel.setRemoteProxyEndpoint(nil)
        host(panel.webView)
        panel.noteWebViewVisibility(true, reason: "test.visible")
        XCTAssertTrue(panel.hasPendingRemoteNavigation)

        panel.setRemoteProxyEndpoint(endpoint)
        await waitForPage(panel, url: pageB, timeout: 10)
        await waitUntil("typed input restored", timeout: 10) {
            (await self.evaluate(
                "document.getElementById('name').value + '|' + document.getElementById('notes').value",
                in: panel.webView
            ) as? String) == "typed name|typed notes"
        }
    }

    /// A back/forward cache return keeps the typed input on screen, but its
    /// commit clears the pane's copy, so the page must report it again.
    func testBackForwardCacheReturnReportsTypedInputAgain() async throws {
        let (panel, _, _) = try await loadScrolledFormPage()
        defer { panel.close() }
        XCTAssertNotNil(panel.pageRestoration.liveFormState)

        _ = await evaluate(
            "window.dispatchEvent(new PageTransitionEvent('pagehide', { persisted: true })); true",
            in: panel.webView
        )
        panel.pageRestoration.noteDocumentCommitted(isDiscardRestoreCommit: false)
        XCTAssertNil(panel.pageRestoration.liveFormState)

        _ = await evaluate(
            "window.dispatchEvent(new PageTransitionEvent('pageshow', { persisted: true })); true",
            in: panel.webView
        )
        await waitUntil("typed input reported again") {
            panel.pageRestoration.liveFormState?.isEmpty == false
        }
    }

    /// Loads page A, then a scrolled page B with typed form input, and returns
    /// the hosted panel showing B. `makePanel` builds the panel for page A; a
    /// local workspace panel by default.
    func loadScrolledFormPage(
        makePanel: ((URL) throws -> BrowserPanel)? = nil
    ) async throws -> (panel: BrowserPanel, pageA: URL, pageB: URL) {
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

        let panel = try makePanel?(pageA)
            ?? BrowserPanel(workspaceId: UUID(), initialURL: pageA, isRemoteWorkspace: false)
        host(panel.webView)
        await waitForPage(panel, url: pageA)

        browserLoadRequest(URLRequest(url: pageB), in: panel.webView)
        await waitForPage(panel, url: pageB)
        let historyBeforeScroll = try XCTUnwrap(
            sessionHistory(of: panel.webView),
            "WebKit's session state format changed; update sessionHistory(of:)"
        )

        _ = await evaluate(
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
        await waitUntil("page scrolled before hide") {
            (await self.evaluate("window.scrollY", in: panel.webView) as? Double) == 1500
        }
        // The restore replays the scroll position WebKit saved in the history
        // item, which it saves 300 ms after scrolling stops. Once page B has
        // loaded, nothing else changes its item.
        await waitUntil("scroll position saved in the history item") {
            self.sessionHistory(of: panel.webView) != historyBeforeScroll
        }
        await waitUntil("typed input reported") {
            let values = Set(panel.pageRestoration.liveFormState?.fields.compactMap(\.value) ?? [])
            return values.isSuperset(of: ["typed name", "typed notes"])
        }
        return (panel, pageA, pageB)
    }

    /// Delivers WebKit's process termination callback for the panel's web
    /// view, which the panel must keep until a later recovery replaces it.
    func terminateWebContent(of panel: BrowserPanel) throws -> WKWebView {
        let webView = panel.webView
        let delegate = try XCTUnwrap(webView.navigationDelegate as? BrowserNavigationDelegate)
        delegate.webViewWebContentProcessDidTerminate(webView)
        XCTAssertTrue(panel.hasRecoverableWebContentTermination)
        XCTAssertTrue(panel.webView === webView)
        return webView
    }

    /// The back/forward list in the web view's session state, which is a
    /// 4-byte version followed by a binary property list. The render tree size
    /// beside it changes on its own, so it is left out.
    private func sessionHistory(of webView: WKWebView) -> NSDictionary? {
        guard let data = webView.interactionState as? Data, data.count > 4,
              let state = try? PropertyListSerialization.propertyList(from: Data(data.dropFirst(4)), format: nil)
        else { return nil }
        return (state as? NSDictionary)?["SessionHistory"] as? NSDictionary
    }

    private func assertRestoredPageState(
        _ panel: BrowserPanel,
        pageA: URL,
        pageB: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await waitForPage(panel, url: pageB, timeout: 10, file: file, line: line)

        XCTAssertEqual(
            panel.webView.backForwardList.backItem?.url.standardizedFileURL,
            pageA.standardizedFileURL,
            "Restore must bring back the native WebKit back/forward list",
            file: file,
            line: line
        )
        XCTAssertTrue(panel.webView.canGoBack, file: file, line: line)
        await waitUntil("scroll position restored", timeout: 10, file: file, line: line) {
            (await self.evaluate("window.scrollY", in: panel.webView) as? Double) == 1500
        }
        await waitUntil("typed input restored", timeout: 10, file: file, line: line) {
            (await self.evaluate(
                "document.getElementById('name').value + '|' + document.getElementById('notes').value",
                in: panel.webView
            ) as? String) == "typed name|typed notes"
        }
    }

    private func assertWaitsForManualRestore(
        _ panel: BrowserPanel,
        instead page: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        // Give a restore that should not have started time to show up.
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(panel.webViewLifecycleState, .discarded, file: file, line: line)
        XCTAssertFalse(panel.shouldRenderWebView, file: file, line: line)
        XCTAssertFalse(panel.webView.isLoading, file: file, line: line)
        XCTAssertNotEqual(panel.webView.url?.standardizedFileURL, page.standardizedFileURL, file: file, line: line)
    }

    func host(_ webView: WKWebView) {
        webView.frame = hostWindow.contentView?.bounds ?? .zero
        webView.autoresizingMask = [.width, .height]
        hostWindow.contentView?.addSubview(webView)
    }

    func evaluate(_ script: String, in webView: WKWebView) async -> Any? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value)
            }
        }
    }

    func waitForPage(
        _ panel: BrowserPanel,
        url: URL,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await waitUntil("load of \(url.lastPathComponent)", timeout: timeout, file: file, line: line) {
            panel.webView.url?.standardizedFileURL == url.standardizedFileURL
                && !panel.webView.isLoading
                && panel.webView.backForwardList.currentItem?.url.standardizedFileURL == url.standardizedFileURL
                && !panel.isLoading
        }
    }

    func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        predicate: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            await Task.yield()
        }
        continueAfterFailure = false
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }
}
