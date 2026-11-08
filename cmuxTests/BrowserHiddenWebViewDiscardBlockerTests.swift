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
/// the hidden memory budget must not discard a pane whose state a restore
/// cannot bring back. Typed input the restore never replays (a password, a
/// rich-text editor) keeps the pane until the system is under memory
/// pressure, and Picture in Picture and the keep-active pin keep it alive
/// like playing media.
@MainActor
final class BrowserHiddenWebViewDiscardBlockerTests: XCTestCase {
    private static let policyKeys = [
        BrowserHiddenWebViewDiscardPolicy.enabledKey,
        BrowserHiddenWebViewDiscardPolicy.modeKey
    ]

    private var fixtureDirectory: URL!
    private var hostWindow: NSWindow!
    private var previousPolicyValues: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in Self.policyKeys {
            previousPolicyValues[key] = defaults.object(forKey: key)
        }
        defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        defaults.removeObject(forKey: BrowserHiddenWebViewDiscardPolicy.modeKey)
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-discard-blockers-\(UUID().uuidString)", isDirectory: true)
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
        for key in Self.policyKeys {
            if let value = previousPolicyValues[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    func testTypedPasswordBlocksBudgetDiscardButNotMemoryPressure() throws {
        let panel = try loadPage(body: #"<form><input id="secret" type="password"></form>"#)
        defer { panel.close() }
        typeValue("hunter2", intoFieldWithID: "secret", in: panel)

        panel.noteWebViewVisibility(false, reason: "test.hidden")

        XCTAssertFalse(panel.discardHiddenWebViewForMemoryBudget(now: Date().addingTimeInterval(3600)))
        XCTAssertNotEqual(panel.webViewLifecycleState, .discarded)
        XCTAssertTrue(panel.discardHiddenWebViewForSystemMemoryPressure())
        XCTAssertEqual(panel.webViewLifecycleState, .discarded)
    }

    func testContentEditableEditBlocksBudgetDiscard() throws {
        let panel = try loadPage(body: #"<div id="editor" contenteditable="true"></div>"#)
        defer { panel.close() }
        _ = evaluate(
            """
            (() => {
              const editor = document.getElementById("editor");
              editor.focus();
              document.execCommand("insertText", false, "draft reply");
              return editor.textContent;
            })()
            """,
            in: panel.webView
        )
        XCTAssertEqual(evaluate("document.getElementById('editor').textContent", in: panel.webView) as? String, "draft reply")
        waitUntil("rich-text edit reported") { panel.pageRestoration.hasUnrestorableLiveInput }

        panel.noteWebViewVisibility(false, reason: "test.hidden")

        XCTAssertFalse(panel.discardHiddenWebViewForMemoryBudget(now: Date().addingTimeInterval(3600)))
        XCTAssertNotEqual(panel.webViewLifecycleState, .discarded)
    }

    /// Input the restore replays must not keep the pane alive.
    func testRestorableTypedInputDoesNotBlockBudgetDiscard() throws {
        let panel = try loadPage(body: #"<form><input id="name" type="text"></form>"#)
        defer { panel.close() }
        typeValue("typed name", intoFieldWithID: "name", in: panel)

        panel.noteWebViewVisibility(false, reason: "test.hidden")

        XCTAssertTrue(panel.discardHiddenWebViewForMemoryBudget(now: Date().addingTimeInterval(3600)))
        XCTAssertEqual(panel.webViewLifecycleState, .discarded)
    }

    func testPictureInPictureBlocksBudgetAndPressureDiscard() throws {
        let panel = try loadPage(body: "<video></video>")
        defer { panel.close() }
        // The media hook reports from its isolated content world; post the
        // report a paused Picture in Picture video sends.
        _ = evaluate(
            """
            window.webkit.messageHandlers.cmuxMediaPlayback.postMessage(
              { frameID: "pip-frame", playing: false, audible: false, pip: true }
            );
            true;
            """,
            in: panel.webView,
            contentWorld: BrowserPanel.mediaPlaybackContentWorld
        )
        _ = evaluate("true", in: panel.webView, contentWorld: BrowserPanel.mediaPlaybackContentWorld)

        panel.noteWebViewVisibility(false, reason: "test.hidden")

        XCTAssertFalse(panel.discardHiddenWebViewForMemoryBudget(now: Date().addingTimeInterval(3600)))
        XCTAssertFalse(panel.discardHiddenWebViewForSystemMemoryPressure())
        XCTAssertNotEqual(panel.webViewLifecycleState, .discarded)
    }

    /// A popup the page opens is built from the opener's configuration, so it
    /// shares the opener's content controller and its reports reach the
    /// opener's handlers. They must not replace the opener's typed input or
    /// keep the opener from being discarded.
    func testPopupReportsDoNotChangeOpenerPageState() throws {
        let panel = try loadPage(body: #"<form><input id="name" type="text"></form>"#)
        defer { panel.close() }
        typeValue("opener draft", intoFieldWithID: "name", in: panel)

        let popupPage = fixtureDirectory.appendingPathComponent("popup.html")
        try "<html><head><title>Popup</title></head><body>popup</body></html>"
            .write(to: popupPage, atomically: true, encoding: .utf8)
        let popup = WKWebView(frame: .zero, configuration: panel.webView.configuration)
        hostWindow.contentView?.addSubview(popup)
        defer { popup.removeFromSuperview() }
        popup.loadFileURL(popupPage, allowingReadAccessTo: fixtureDirectory)
        waitUntil("popup load") {
            popup.url?.standardizedFileURL == popupPage.standardizedFileURL && !popup.isLoading
        }

        _ = evaluate(
            """
            window.webkit.messageHandlers.cmuxFormState.postMessage({
              url: String(location.href),
              fields: [{ k: "id:name", v: "popup value" }],
              unrestorable: true
            });
            true;
            """,
            in: popup,
            contentWorld: .browserFormState
        )
        _ = evaluate(
            """
            window.webkit.messageHandlers.cmuxMediaPlayback.postMessage(
              { frameID: "popup-frame", playing: true, audible: true, pip: true }
            );
            true;
            """,
            in: popup,
            contentWorld: BrowserPanel.mediaPlaybackContentWorld
        )
        // WebKit delivers a page's script messages before the result of a
        // later evaluation in the same page.
        _ = evaluate("true", in: popup, contentWorld: .browserFormState)
        _ = evaluate("true", in: popup, contentWorld: BrowserPanel.mediaPlaybackContentWorld)

        XCTAssertEqual(panel.pageRestoration.liveFormState?.fields.compactMap(\.value), ["opener draft"])
        XCTAssertFalse(panel.pageRestoration.hasUnrestorableLiveInput)
        XCTAssertFalse(panel.isPlayingMedia)

        panel.noteWebViewVisibility(false, reason: "test.hidden")
        XCTAssertTrue(panel.discardHiddenWebViewForMemoryBudget(now: Date().addingTimeInterval(3600)))
    }

    func testKeepActivePinBlocksDiscardAndSurvivesSessionRestore() throws {
        let panel = try loadPage(body: "<p>pinned</p>")
        defer { panel.close() }
        panel.keepsPageActiveWhileHidden = true

        panel.noteWebViewVisibility(false, reason: "test.hidden")

        XCTAssertFalse(panel.discardHiddenWebViewForMemoryBudget(now: Date().addingTimeInterval(3600)))
        XCTAssertFalse(panel.discardHiddenWebViewForSystemMemoryPressure())
        XCTAssertNotEqual(panel.webViewLifecycleState, .discarded)

        let snapshot = SessionBrowserPanelSnapshot(
            urlString: panel.webView.url?.absoluteString,
            profileID: nil,
            shouldRenderWebView: true,
            pageZoom: 1,
            developerToolsVisible: false,
            backHistoryURLStrings: nil,
            forwardHistoryURLStrings: nil,
            keepsPageActive: panel.keepsPageActiveForSessionSnapshot
        )
        let decoded = try JSONDecoder().decode(
            SessionBrowserPanelSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        let restored = BrowserPanel(workspaceId: UUID(), isRemoteWorkspace: false)
        defer { restored.close() }
        restored.restoreSessionSnapshot(decoded)
        XCTAssertTrue(restored.keepsPageActiveWhileHidden)

        restored.keepsPageActiveWhileHidden = false
        XCTAssertNil(restored.keepsPageActiveForSessionSnapshot)
    }

    private func loadPage(body: String) throws -> BrowserPanel {
        let page = fixtureDirectory.appendingPathComponent("page.html")
        try "<html><head><title>Page</title></head><body>\(body)</body></html>"
            .write(to: page, atomically: true, encoding: .utf8)
        let panel = BrowserPanel(workspaceId: UUID(), initialURL: page, isRemoteWorkspace: false)
        panel.webView.frame = hostWindow.contentView?.bounds ?? .zero
        hostWindow.contentView?.addSubview(panel.webView)
        waitUntil("load of \(page.lastPathComponent)") {
            panel.webView.url?.standardizedFileURL == page.standardizedFileURL
                && !panel.webView.isLoading
                && !panel.isLoading
        }
        return panel
    }

    private func typeValue(_ value: String, intoFieldWithID id: String, in panel: BrowserPanel) {
        _ = evaluate(
            """
            (() => {
              const field = document.getElementById("\(id)");
              field.focus();
              field.value = "\(value)";
              field.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: "\(value)" }));
              field.blur();
              return field.value;
            })()
            """,
            in: panel.webView
        )
        // The observer reports the value, or flags a field it never replays.
        waitUntil("input into #\(id) reported") {
            panel.pageRestoration.liveFormState?.fields.contains { $0.value == value } == true
                || panel.pageRestoration.hasUnrestorableLiveInput
        }
    }

    private func evaluate(
        _ script: String,
        in webView: WKWebView,
        contentWorld: WKContentWorld? = nil
    ) -> Any? {
        var result: Any?
        var finished = false
        webView.evaluateJavaScript(script, in: nil, in: contentWorld ?? .page) { outcome in
            result = try? outcome.get()
            finished = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !finished, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return result
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        predicate: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        continueAfterFailure = false
        XCTFail("Timed out waiting for \(description)")
    }
}
