import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Darwin
import Testing
import CmuxBrowser

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private func drainBrowserPanelMainQueue() {
    let expectation = XCTestExpectation(description: "drain main queue")
    DispatchQueue.main.async {
        expectation.fulfill()
    }
    XCTWaiter().wait(for: [expectation], timeout: 1.0)
}

private final class BrowserPanelTestNavigationDelegate: NSObject, WKNavigationDelegate {
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

private final class BrowserPanelTestScriptMessageHandler: NSObject, WKScriptMessageHandler {
    let expectation: XCTestExpectation
    var body: Any?

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        body = message.body
        expectation.fulfill()
    }
}

@MainActor
private final class BrowserHiddenWebViewDiscardTestDelegate: BrowserHiddenWebViewDiscardManagerDelegate {
    var snapshot: BrowserHiddenWebViewDiscardManager.BlockerSnapshot
    var hiddenAt: Date?
    var webViewInstanceID = UUID()
    var discardRequestCount = 0

    init(snapshot: BrowserHiddenWebViewDiscardManager.BlockerSnapshot, hiddenAt: Date?) {
        self.snapshot = snapshot
        self.hiddenAt = hiddenAt
    }

    var hiddenWebViewDiscardSnapshot: BrowserHiddenWebViewDiscardManager.BlockerSnapshot {
        snapshot
    }

    var hiddenWebViewDiscardHiddenAt: Date? {
        hiddenAt
    }

    var hiddenWebViewDiscardWebViewInstanceID: UUID {
        webViewInstanceID
    }

    func hiddenWebViewDiscardManagerDidRequestDiscard(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    ) {
        discardRequestCount += 1
    }

    func hiddenWebViewDiscardManagerPolicyDidChange(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    ) {}
}

@MainActor
private func makeHiddenWebViewDiscardBlockerSnapshot(
    hasActiveMainFrameProvisionalNavigation: Bool = false,
    isVisualAutomationCaptureActive: Bool = false,
    isCapturingMedia: Bool = false,
    isPlayingMedia: Bool = false
) -> BrowserHiddenWebViewDiscardManager.BlockerSnapshot {
    BrowserHiddenWebViewDiscardManager.BlockerSnapshot(
        isClosing: false,
        isVisibleInUI: false,
        shouldRenderWebView: true,
        hasPendingRemoteNavigation: false,
        hasCurrentURL: true,
        isLoading: false,
        webViewIsLoading: false,
        hasActiveMainFrameProvisionalNavigation: hasActiveMainFrameProvisionalNavigation,
        isDownloading: false,
        activeDownloadCount: 0,
        preferredDeveloperToolsVisible: false,
        isDeveloperToolsVisible: false,
        isElementFullscreenActive: false,
        isReactGrabActive: false,
        isVisualAutomationCaptureActive: isVisualAutomationCaptureActive,
        hasPopups: false,
        isCapturingMedia: isCapturingMedia,
        isPlayingMedia: isPlayingMedia
    )
}

@MainActor
private func withHiddenWebViewDiscardPolicyEnabled(_ body: () -> Void) {
    let defaults = UserDefaults.standard
    let previousEnabled = defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
    defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
    defer {
        if let previousEnabled {
            defaults.set(previousEnabled, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        } else {
            defaults.removeObject(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        }
    }
    body()
}

@MainActor
@Suite(.serialized)
struct BrowserHiddenWebViewDiscardMediaPlaybackTests {
    /// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5409:
    /// a hidden pane that is actively playing media (e.g. a backgrounded YouTube
    /// video) must be exempted from memory discard so switching workspaces does
    /// not stop playback or reload the page. The media_capture blocker only
    /// covers camera/mic capture, not <video>/<audio> playback.
    @Test func activeMediaPlaybackBlocksHiddenWebViewDiscardScheduling() {
        withHiddenWebViewDiscardPolicyEnabled {
            let snapshot = makeHiddenWebViewDiscardBlockerSnapshot(isPlayingMedia: true)
            let manager = BrowserHiddenWebViewDiscardManager()
            let delegate = BrowserHiddenWebViewDiscardTestDelegate(snapshot: snapshot, hiddenAt: Date())
            manager.delegate = delegate

            #expect(manager.blockers(for: snapshot) == ["media_playback"])

            manager.scheduleIfNeeded(reason: "test.hidden")

            #expect(!manager.hasScheduledDiscard)
            #expect(delegate.discardRequestCount == 0)
        }
    }

    /// An idle hidden pane (no playing media) must still be eligible for discard
    /// so the memory bound from https://github.com/manaflow-ai/cmux/issues/4539
    /// is preserved.
    @Test func idlePaneWithoutMediaPlaybackStillSchedulesHiddenWebViewDiscard() {
        withHiddenWebViewDiscardPolicyEnabled {
            let snapshot = makeHiddenWebViewDiscardBlockerSnapshot(isPlayingMedia: false)
            let manager = BrowserHiddenWebViewDiscardManager()
            let delegate = BrowserHiddenWebViewDiscardTestDelegate(snapshot: snapshot, hiddenAt: Date())
            manager.delegate = delegate

            #expect(manager.blockers(for: snapshot) == [])

            manager.scheduleIfNeeded(reason: "test.hidden")

            #expect(manager.hasScheduledDiscard)
            #expect(delegate.discardRequestCount == 0)
        }
    }
}

@MainActor
final class BrowserHiddenWebViewDiscardManagerTests: XCTestCase {
    private var previousEnabled: Any?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        previousEnabled = defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        if let previousEnabled {
            defaults.set(previousEnabled, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        } else {
            defaults.removeObject(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        }
        super.tearDown()
    }

    func testActiveMediaCaptureBlocksHiddenWebViewDiscardScheduling() {
        let snapshot = makeHiddenWebViewDiscardBlockerSnapshot(isCapturingMedia: true)
        let manager = BrowserHiddenWebViewDiscardManager()
        let delegate = BrowserHiddenWebViewDiscardTestDelegate(snapshot: snapshot, hiddenAt: Date())
        manager.delegate = delegate

        XCTAssertEqual(manager.blockers(for: snapshot), ["media_capture"])

        manager.scheduleIfNeeded(reason: "test.hidden")

        XCTAssertFalse(manager.hasScheduledDiscard)
        XCTAssertEqual(delegate.discardRequestCount, 0)
    }

    func testVisualAutomationCaptureBlocksHiddenWebViewDiscardScheduling() {
        let snapshot = makeHiddenWebViewDiscardBlockerSnapshot(isVisualAutomationCaptureActive: true)

        let manager = BrowserHiddenWebViewDiscardManager()
        let delegate = BrowserHiddenWebViewDiscardTestDelegate(snapshot: snapshot, hiddenAt: Date())
        manager.delegate = delegate

        XCTAssertEqual(manager.blockers(for: snapshot), ["visual_automation"])

        manager.scheduleIfNeeded(reason: "test.visualAutomation")

        XCTAssertFalse(manager.hasScheduledDiscard)
        XCTAssertEqual(delegate.discardRequestCount, 0)
    }

    // Regression coverage for https://github.com/manaflow-ai/cmux/issues/5261:
    // a main-frame provisional navigation (e.g. a cross-origin process swap in
    // flight) must block a hidden-webview discard from replacing the WKWebView.
    func testMainFrameProvisionalNavigationBlocksHiddenWebViewDiscardScheduling() {
        let snapshot = makeHiddenWebViewDiscardBlockerSnapshot(
            hasActiveMainFrameProvisionalNavigation: true
        )
        let manager = BrowserHiddenWebViewDiscardManager()
        let delegate = BrowserHiddenWebViewDiscardTestDelegate(snapshot: snapshot, hiddenAt: Date())
        manager.delegate = delegate

        XCTAssertEqual(manager.blockers(for: snapshot), ["provisional_navigation"])

        manager.scheduleIfNeeded(reason: "test.provisional")

        XCTAssertFalse(manager.hasScheduledDiscard)
        XCTAssertEqual(delegate.discardRequestCount, 0)
    }

    // Regression coverage for https://github.com/manaflow-ai/cmux/issues/5261:
    // a discard countdown that elapsed across system sleep must restart from
    // wake instead of discarding the webview immediately after wake, while
    // WebKit pages are still reconnecting/renavigating.
    func testSystemWakeRestartsHiddenWebViewDiscardCountdown() {
        let snapshot = makeHiddenWebViewDiscardBlockerSnapshot()
        let manager = BrowserHiddenWebViewDiscardManager()
        let delegate = BrowserHiddenWebViewDiscardTestDelegate(
            snapshot: snapshot,
            hiddenAt: Date(timeIntervalSinceNow: -7200)
        )
        manager.delegate = delegate

        manager.noteSystemDidWake(now: Date())
        manager.scheduleIfNeeded(reason: "test.postWake")

        XCTAssertEqual(delegate.discardRequestCount, 0)
        XCTAssertTrue(manager.hasScheduledDiscard)
    }

    // Regression coverage for https://github.com/manaflow-ai/cmux/issues/5261:
    // sleep cancels an armed discard countdown and blocks re-arming until wake,
    // and wake re-arms a fresh countdown without discarding.
    func testSystemSleepCancelsArmedHiddenWebViewDiscard() {
        let snapshot = makeHiddenWebViewDiscardBlockerSnapshot()
        let manager = BrowserHiddenWebViewDiscardManager()
        let delegate = BrowserHiddenWebViewDiscardTestDelegate(snapshot: snapshot, hiddenAt: Date())
        manager.delegate = delegate

        manager.scheduleIfNeeded(reason: "test.hidden")
        XCTAssertTrue(manager.hasScheduledDiscard)

        manager.noteSystemWillSleep()
        XCTAssertFalse(manager.hasScheduledDiscard)
        XCTAssertEqual(manager.blockers(for: snapshot), ["system_sleeping"])

        manager.scheduleIfNeeded(reason: "test.whileSleeping")
        XCTAssertFalse(manager.hasScheduledDiscard)
        XCTAssertEqual(delegate.discardRequestCount, 0)

        manager.noteSystemDidWake(now: Date())
        XCTAssertTrue(manager.hasScheduledDiscard)
        XCTAssertEqual(manager.blockers(for: snapshot), [])
        XCTAssertEqual(delegate.discardRequestCount, 0)
    }

    func testFocusedBrowserPanelBlocksHiddenWebViewDiscard() throws {
        let workspace = Workspace(initialSurface: .browser)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? BrowserPanel)
        defer { panel.close() }

        let url = try XCTUnwrap(URL(string: "about:blank"))
        panel.navigate(to: url)
        let deadline = Date().addingTimeInterval(1.0)
        while panel.webView.isLoading,
              RunLoop.main.run(mode: .default, before: deadline),
              Date() < deadline {}
        XCTAssertFalse(panel.webView.isLoading, "Timed out waiting for about:blank to finish loading")

        let hiddenAt = Date(timeIntervalSince1970: 6_000)
        panel.noteWebViewVisibility(false, reason: "test.portalHidden", now: hiddenAt)
        workspace.focusPanel(panel.id)

        let originalWebView = panel.webView
        XCTAssertFalse(
            panel.discardHiddenWebViewForSystemMemoryPressure(now: hiddenAt.addingTimeInterval(1)),
            "Focused browser panes must not be memory-discarded while still active in the workspace."
        )
        XCTAssertTrue(panel.webView === originalWebView)
    }
}

@MainActor
final class BrowserPanelVisualAutomationRestoreHostTests: XCTestCase {
    func testRestoredDiscardedHiddenWebViewGetsRestoreHostBeforeOffscreenCapture() {
        let discardedAt = Date(timeIntervalSince1970: 400)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        let deadline = Date().addingTimeInterval(1.0)
        while panel.webView.isLoading,
              RunLoop.main.run(mode: .default, before: deadline),
              Date() < deadline {}
        XCTAssertFalse(panel.webView.isLoading, "Timed out waiting for about:blank to finish loading")

        panel.noteWebViewVisibility(false, reason: "test.hidden", now: discardedAt)
        let originalWebView = panel.webView

        XCTAssertTrue(panel.discardHiddenWebViewForMemory(reason: "test.discard", now: discardedAt))
        XCTAssertFalse(panel.webView === originalWebView)
        XCTAssertNil(panel.webView.superview)
        XCTAssertFalse(panel.hasBackgroundPreloadHost)

        XCTAssertTrue(panel.restoreDiscardedWebViewIfNeeded(reason: "test.restore"))
        XCTAssertEqual(panel.webViewLifecycleState, .liveHidden)
        XCTAssertNil(panel.webView.superview)

        XCTAssertTrue(panel.ensureVisualAutomationRestoreHostIfNeeded(reason: "test.visualAutomation"))
        XCTAssertTrue(panel.hasBackgroundPreloadHost)
        XCTAssertNotNil(panel.webView.superview)
        XCTAssertNotNil(panel.webView.window)
        XCTAssertFalse(panel.ensureVisualAutomationRestoreHostIfNeeded(reason: "test.visualAutomation.alreadyAttached"))
    }
}

@MainActor
private func makeTemporaryBrowserPanelProfile(named prefix: String) throws -> BrowserProfileDefinition {
    try XCTUnwrap(
        BrowserProfileStore.shared.createProfile(
            named: "\(prefix)-\(UUID().uuidString)"
        )
    )
}

final class BrowserPanelChromeBackgroundColorTests: XCTestCase {
    func testLightModeUsesThemeBackgroundColor() {
        assertResolvedColorMatchesTheme(for: .light)
    }

    func testDarkModeUsesThemeBackgroundColor() {
        assertResolvedColorMatchesTheme(for: .dark)
    }

    func testTransparentGhosttyBackgroundUsesClearBlankBrowserChrome() {
        let baseColor = NSColor(srgbRed: 0.13, green: 0.29, blue: 0.47, alpha: 1.0)
        let themeBackground = GhosttyBackgroundTheme.color(backgroundColor: baseColor, opacity: 0.42)

        guard let actual = resolvedBrowserChromeBackgroundColor(
            for: .dark,
            themeBackgroundColor: themeBackground,
            drawsBackground: false
        ).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(actual.alphaComponent, 0.0, accuracy: 0.001)
    }

    func testGhosttyBackgroundThemeColorCompositesTranslucentBackgrounds() {
        let baseColor = NSColor(srgbRed: 0.02, green: 0.03, blue: 0.04, alpha: 1.0)
        let themeBackground = GhosttyBackgroundTheme.color(backgroundColor: baseColor, opacity: 0.05)

        XCTAssertEqual(themeBackground.alphaComponent, 1.0, accuracy: 0.001)
    }

    func testBrowserChromeColorSchemeAccountsForTranslucentBackground() {
        let darkTranslucentBackground = NSColor(srgbRed: 0.02, green: 0.03, blue: 0.04, alpha: 0.05)

        XCTAssertEqual(
            resolvedBrowserChromeColorScheme(
                for: .dark,
                themeBackgroundColor: darkTranslucentBackground,
                windowBackgroundColor: .white
            ),
            .light
        )
    }

    func testBrowserChromeDrawDecisionMatchesTransparencyOwnership() {
        let cases: [(String, Bool, Bool, Double, Bool, Bool, Bool)] = [
            ("blank transparent Ghostty", true, false, 0.42, false, false, false),
            ("blank glass", true, false, 1.0, true, false, false),
            ("blank transparent window", true, false, 1.0, false, true, false),
            ("real transparent Ghostty", false, false, 0.42, false, false, true),
            ("transparent internal opaque Ghostty", false, true, 1.0, false, false, true),
            ("transparent internal transparent Ghostty", false, true, 0.42, false, false, false),
            ("blank opaque Ghostty", true, false, 1.0, false, false, true),
        ]
        for (name, isBlank, transparentPage, opacity, glass, transparentWindow, expected) in cases {
            XCTAssertEqual(BrowserPanel.drawsWebViewBackground(
                isBlankPage: isBlank,
                usesTransparentBackground: transparentPage,
                opacity: opacity,
                usesGhosttyGlassStyle: glass,
                usesTransparentWindow: transparentWindow
            ), expected, name)
        }
    }

    func testBrowserBlankPageURLDetectionTreatsOnlyEmptyAndAboutBlankAsBlank() throws {
        XCTAssertTrue(BrowserPanel.isBlankBrowserPageURL(nil))
        XCTAssertTrue(BrowserPanel.isBlankBrowserPageURL(try XCTUnwrap(URL(string: "about:blank"))))
        XCTAssertFalse(BrowserPanel.isBlankBrowserPageURL(try XCTUnwrap(URL(string: "https://mail.google.com/"))))
    }

    func testBrowserBlankPageDetectionTreatsPendingRealNavigationAsNonBlank() throws {
        XCTAssertFalse(BrowserPanel.isBlankBrowserPage(
            liveURL: nil,
            currentURL: nil,
            pendingNavigationURL: try XCTUnwrap(URL(string: "https://mail.google.com/")),
            isMainFrameProvisionalNavigationActive: true
        ))
    }

    func testBrowserBlankPageDetectionTreatsInitialPendingRealNavigationAsNonBlank() throws {
        XCTAssertFalse(BrowserPanel.isBlankBrowserPage(
            liveURL: nil,
            currentURL: nil,
            pendingNavigationURL: try XCTUnwrap(URL(string: "https://mail.google.com/")),
            isMainFrameProvisionalNavigationActive: false
        ))
    }

    func testBrowserBlankPageDetectionClearsAfterCommittedAboutBlank() throws {
        XCTAssertTrue(BrowserPanel.isBlankBrowserPage(
            liveURL: try XCTUnwrap(URL(string: "about:blank")),
            currentURL: try XCTUnwrap(URL(string: "about:blank")),
            pendingNavigationURL: try XCTUnwrap(URL(string: "about:blank")),
            isMainFrameProvisionalNavigationActive: false
        ))
    }

    private func assertResolvedColorMatchesTheme(
        for colorScheme: ColorScheme,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let themeBackground = NSColor(srgbRed: 0.13, green: 0.29, blue: 0.47, alpha: 1.0)

        guard
            let actual = resolvedBrowserChromeBackgroundColor(
                for: colorScheme,
                themeBackgroundColor: themeBackground,
                drawsBackground: true
            ).usingColorSpace(.sRGB),
            let expected = themeBackground.usingColorSpace(.sRGB)
        else {
            XCTFail("Expected sRGB-convertible colors", file: file, line: line)
            return
        }

        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.001, file: file, line: line)
    }
}


@MainActor
final class BrowserPanelFileSystemAccessBridgeTests: XCTestCase {
    func testShowOpenFilePickerIsInstalledInBrowserPages() async throws {
        let panel = try await loadFilePickerTestPage()

        let result = try await panel.evaluateJavaScript("typeof window.showOpenFilePicker")
        XCTAssertEqual(result as? String, "function")
    }

    func testShowOpenFilePickerRejectsWhenWindowFocusReturnsWithoutCancelEvent() async throws {
        let panel = try await loadFilePickerTestPage()

        let result = try await panel.webView.callAsyncJavaScript(
            """
            const inputCount = () => document.querySelectorAll("input[type='file']").length;
            const originalClick = HTMLInputElement.prototype.click;
            HTMLInputElement.prototype.click = function() {};
            const pickerPromise = window.showOpenFilePicker();
            HTMLInputElement.prototype.click = originalClick;

            return await new Promise((resolve) => {
              pickerPromise.then(
                () => resolve({ status: "resolved", inputCount: inputCount() }),
                (error) => resolve({
                  status: "rejected",
                  name: error && error.name,
                  inputCount: inputCount(),
                })
              );

              window.dispatchEvent(new Event("focus"));
              setTimeout(() => resolve({ status: "pending", inputCount: inputCount() }), 100);
            });
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let dictionary = try XCTUnwrap(result as? [String: Any])
        let inputCount = try XCTUnwrap(dictionary["inputCount"] as? NSNumber)
        XCTAssertEqual(dictionary["status"] as? String, "rejected")
        XCTAssertEqual(dictionary["name"] as? String, "AbortError")
        XCTAssertEqual(inputCount.intValue, 0)
    }

    func testShowOpenFilePickerDoesNotRejectOnElementFocus() async throws {
        let panel = try await loadFilePickerTestPage()

        let result = try await panel.webView.callAsyncJavaScript(
            """
            const inputCount = () => document.querySelectorAll("input[type='file']").length;
            const originalClick = HTMLInputElement.prototype.click;
            HTMLInputElement.prototype.click = function() {};
            const pickerPromise = window.showOpenFilePicker();
            HTMLInputElement.prototype.click = originalClick;

            let settled = false;
            pickerPromise.finally(() => { settled = true; }).catch(() => {});

            const textInput = document.createElement("input");
            textInput.type = "text";
            document.body.appendChild(textInput);
            textInput.focus();

            await new Promise((resolve) => setTimeout(resolve, 50));
            const beforeWindowFocus = {
              settled,
              inputCount: inputCount(),
            };

            window.dispatchEvent(new Event("focus"));
            const afterWindowFocus = await new Promise((resolve) => {
              pickerPromise.then(
                () => resolve({ status: "resolved", inputCount: inputCount() }),
                (error) => resolve({
                  status: "rejected",
                  name: error && error.name,
                  inputCount: inputCount(),
                })
              );
            });

            return { beforeWindowFocus, afterWindowFocus };
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let dictionary = try XCTUnwrap(result as? [String: Any])
        let beforeWindowFocus = try XCTUnwrap(dictionary["beforeWindowFocus"] as? [String: Any])
        let beforeInputCount = try XCTUnwrap(beforeWindowFocus["inputCount"] as? NSNumber)
        XCTAssertEqual(beforeWindowFocus["settled"] as? Bool, false)
        XCTAssertEqual(beforeInputCount.intValue, 1)

        let afterWindowFocus = try XCTUnwrap(dictionary["afterWindowFocus"] as? [String: Any])
        let afterInputCount = try XCTUnwrap(afterWindowFocus["inputCount"] as? NSNumber)
        XCTAssertEqual(afterWindowFocus["status"] as? String, "rejected")
        XCTAssertEqual(afterWindowFocus["name"] as? String, "AbortError")
        XCTAssertEqual(afterInputCount.intValue, 0)
    }

    private func loadFilePickerTestPage() async throws -> BrowserPanel {
        let panel = BrowserPanel(workspaceId: UUID())
        let baseURL = try XCTUnwrap(URL(string: "https://example.test/file-picker"))
        let loaded = expectation(description: "browser panel test page loaded")
        let previousDelegate = panel.webView.navigationDelegate
        let loadDelegate = BrowserPanelTestNavigationDelegate(expectation: loaded)
        panel.webView.navigationDelegate = loadDelegate
        defer { panel.webView.navigationDelegate = previousDelegate }

        panel.webView.loadHTMLString(
            "<!doctype html><html><body>browser panel test page</body></html>",
            baseURL: baseURL
        )
        await fulfillment(of: [loaded], timeout: 5)
        if let error = loadDelegate.error {
            throw error
        }
        return panel
    }
}


@MainActor
final class BrowserPanelInitialNavigationTests: XCTestCase {
    func testInitialURLCanBePreservedWithoutRenderingWebView() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/custom-layout"))
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            renderInitialNavigation: false
        )

        XCTAssertEqual(panel.currentURL, url)
        XCTAssertFalse(panel.shouldRenderWebView)
        XCTAssertFalse(panel.shouldRenderWebViewForSessionSnapshot())
    }

    func testDiffViewerURLIsNotPersistedForSessionRestore() throws {
        let schemeURL = try XCTUnwrap(URL(string: "\(CmuxDiffViewerURLSchemeHandler.scheme)://token/index.html"))
        let schemePanel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: schemeURL,
            renderInitialNavigation: false
        )

        XCTAssertEqual(schemePanel.preferredURLStringForOmnibar(), schemeURL.absoluteString)
        XCTAssertNil(schemePanel.preferredURLStringForSessionSnapshot())
        XCTAssertFalse(schemePanel.shouldPersistSessionSnapshot())
        XCTAssertFalse(schemePanel.shouldRenderWebViewForSessionSnapshot())

        let loopbackURL = try XCTUnwrap(URL(string: "http://127.0.0.1:49152/token/diff.html#cmux-diff-viewer"))
        let loopbackPanel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: loopbackURL,
            renderInitialNavigation: false
        )
        XCTAssertEqual(loopbackPanel.preferredURLStringForOmnibar(), loopbackURL.absoluteString)
        XCTAssertNil(loopbackPanel.preferredURLStringForSessionSnapshot())
        XCTAssertFalse(loopbackPanel.shouldPersistSessionSnapshot())
        XCTAssertFalse(loopbackPanel.shouldRenderWebViewForSessionSnapshot())

        let aliasURL = try XCTUnwrap(URL(string: "http://cmux-loopback.localtest.me:49152/token/diff.html#cmux-diff-viewer"))
        let aliasPanel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: aliasURL,
            renderInitialNavigation: false
        )
        XCTAssertNil(aliasPanel.preferredURLStringForSessionSnapshot())
        XCTAssertFalse(aliasPanel.shouldPersistSessionSnapshot())

        let normalLocalhostURL = try XCTUnwrap(URL(string: "http://127.0.0.1:49152/app"))
        let normalLocalhostPanel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: normalLocalhostURL,
            renderInitialNavigation: false
        )
        XCTAssertEqual(normalLocalhostPanel.preferredURLStringForSessionSnapshot(), normalLocalhostURL.absoluteString)
        XCTAssertTrue(normalLocalhostPanel.shouldPersistSessionSnapshot())
    }

    func testDiffViewerURLIsNotRecordedInBrowserHistory() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-history-\(UUID().uuidString).json")
        let store = BrowserHistoryStore(fileURL: fileURL)
        defer {
            store.clearHistory()
            try? FileManager.default.removeItem(at: fileURL)
        }

        let schemeURL = try XCTUnwrap(URL(string: "\(CmuxDiffViewerURLSchemeHandler.scheme)://token/index.html"))
        let loopbackURL = try XCTUnwrap(URL(string: "http://127.0.0.1:49152/token/diff.html#cmux-diff-viewer"))
        let aliasURL = try XCTUnwrap(URL(string: "http://cmux-loopback.localtest.me:49152/token/diff.html#cmux-diff-viewer"))
        let normalURL = try XCTUnwrap(URL(string: "https://example.com/page"))

        store.recordVisit(url: schemeURL, title: "Diff")
        store.recordVisit(url: loopbackURL, title: "Diff")
        store.recordVisit(url: aliasURL, title: "Diff")
        store.recordTypedNavigation(url: aliasURL)
        store.recordTypedNavigation(url: loopbackURL)
        XCTAssertTrue(store.entries.isEmpty)

        store.recordVisit(url: normalURL, title: "Normal")
        XCTAssertEqual(store.entries.map(\.url), [normalURL.absoluteString])
    }
}


@MainActor
final class BrowserPanelDiffViewerSchemeTests: XCTestCase {
    private func trustedDiffViewerTestRoot() -> URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func testDiffViewerSchemeRegistrationIsIdempotentForCopiedConfiguration() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(
            CmuxDiffViewerURLSchemeHandler.shared,
            forURLScheme: CmuxDiffViewerURLSchemeHandler.scheme
        )

        BrowserPanel.configureWebViewConfiguration(
            config,
            websiteDataStore: .nonPersistent()
        )

        XCTAssertNotNil(config.urlSchemeHandler(forURLScheme: CmuxDiffViewerURLSchemeHandler.scheme))
    }

    func testDiffViewerSchemeLoadsSameOriginModuleFromAllowlist() throws {
        let token = UUID().uuidString.lowercased()
        let rootURL = trustedDiffViewerTestRoot()
        let assetURL = rootURL
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("mod.mjs", isDirectory: false)
        let workerAssetURL = rootURL
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("worker.js", isDirectory: false)
        let indexURL = rootURL.appendingPathComponent("index.html", isDirectory: false)
        try FileManager.default.createDirectory(at: assetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try """
        export const marker = "module-ok";
        """.write(to: assetURL, atomically: true, encoding: .utf8)
        try """
        export const workerMarker = "js-ok";
        """.write(to: workerAssetURL, atomically: true, encoding: .utf8)
        try """
        <!doctype html>
        <html>
        <body>
        <script type="module">
          import { marker } from "./assets/mod.mjs";
          import { workerMarker } from "./assets/worker.js";
          WebAssembly.compile(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]))
            .then(() => {
              const result = `${marker}:${workerMarker}:wasm-ok`;
              document.body.dataset.loaded = result;
              window.webkit.messageHandlers.moduleLoaded.postMessage(result);
            })
            .catch((error) => {
              const result = `wasm-error:${error.message}`;
              document.body.dataset.loaded = result;
              window.webkit.messageHandlers.moduleLoaded.postMessage(result);
            });
        </script>
        </body>
        </html>
        """.write(to: indexURL, atomically: true, encoding: .utf8)
        let patchURL = rootURL.appendingPathComponent("index.patch", isDirectory: false)
        try "diff --git a/a b/a\n".write(to: patchURL, atomically: true, encoding: .utf8)

        try CmuxDiffViewerURLSchemeHandler.shared.register(
            token: token,
            files: [
                .init(requestPath: "/index.html", fileURL: indexURL, mimeType: "text/html"),
                .init(requestPath: "/assets/mod.mjs", fileURL: assetURL, mimeType: "text/javascript"),
                .init(requestPath: "/assets/worker.js", fileURL: workerAssetURL, mimeType: "text/javascript"),
                .init(requestPath: "/index.patch", fileURL: patchURL, mimeType: "text/x-diff"),
            ]
        )

        let allowedURL = try XCTUnwrap(URL(string: "\(CmuxDiffViewerURLSchemeHandler.scheme)://\(token)/index.html"))
        let allowedPatchURL = try XCTUnwrap(URL(string: "\(CmuxDiffViewerURLSchemeHandler.scheme)://\(token)/index.patch"))
        let blockedURL = try XCTUnwrap(URL(string: "\(CmuxDiffViewerURLSchemeHandler.scheme)://\(token)/not-allowed.html"))
        let queryURL = try XCTUnwrap(URL(string: "\(CmuxDiffViewerURLSchemeHandler.scheme)://\(token)/index.html?copy=1"))
        XCTAssertNotNil(CmuxDiffViewerURLSchemeHandler.shared.registeredFile(for: allowedURL))
        XCTAssertNotNil(CmuxDiffViewerURLSchemeHandler.shared.registeredFile(for: allowedPatchURL))
        XCTAssertNil(CmuxDiffViewerURLSchemeHandler.shared.registeredFile(for: blockedURL))
        XCTAssertNil(CmuxDiffViewerURLSchemeHandler.shared.registeredFile(for: queryURL))

        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        let moduleLoaded = expectation(description: "module evaluated")
        let moduleHandler = BrowserPanelTestScriptMessageHandler(expectation: moduleLoaded)
        contentController.add(moduleHandler, name: "moduleLoaded")
        config.userContentController = contentController
        config.setURLSchemeHandler(
            CmuxDiffViewerURLSchemeHandler.shared,
            forURLScheme: CmuxDiffViewerURLSchemeHandler.scheme
        )
        defer {
            contentController.removeScriptMessageHandler(forName: "moduleLoaded")
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        let loaded = expectation(description: "diff viewer loaded")
        let delegate = BrowserPanelTestNavigationDelegate(expectation: loaded)
        webView.navigationDelegate = delegate
        webView.load(URLRequest(url: allowedURL))
        wait(for: [loaded], timeout: 10)
        XCTAssertNil(delegate.error)
        wait(for: [moduleLoaded], timeout: 10)
        XCTAssertEqual(moduleHandler.body as? String, "module-ok:js-ok:wasm-ok")

        let evaluated = expectation(description: "module evaluated")
        webView.evaluateJavaScript("document.body.dataset.loaded || ''") { value, error in
            XCTAssertNil(error)
            XCTAssertEqual(value as? String, "module-ok:js-ok:wasm-ok")
            evaluated.fulfill()
        }
        wait(for: [evaluated], timeout: 10)
    }

    func testDiffViewerSchemeRejectsSymlinkEscapeFromTrustedRoot() throws {
        let token = UUID().uuidString.lowercased()
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-diff-viewer-security-\(UUID().uuidString)", isDirectory: true)
        let trustedRootURL = trustedDiffViewerTestRoot()
        let outsideURL = temporaryURL.appendingPathComponent("outside.html", isDirectory: false)
        let linkURL = trustedRootURL.appendingPathComponent("link.html", isDirectory: false)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trustedRootURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: trustedRootURL)
        }

        try "<!doctype html>".write(to: outsideURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)

        XCTAssertThrowsError(try CmuxDiffViewerURLSchemeHandler.shared.register(
            token: token,
            files: [
                .init(requestPath: "/link.html", fileURL: linkURL, mimeType: "text/html"),
            ]
        ))
    }

    func testDiffViewerSchemeRejectsMismatchedPatchMimeType() throws {
        let token = UUID().uuidString.lowercased()
        let trustedRootURL = trustedDiffViewerTestRoot()
        let patchURL = trustedRootURL.appendingPathComponent("diff.patch", isDirectory: false)
        try FileManager.default.createDirectory(at: trustedRootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: trustedRootURL) }

        try "diff --git a/a b/a\n".write(to: patchURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try CmuxDiffViewerURLSchemeHandler.shared.register(
            token: token,
            files: [
                .init(requestPath: "/diff.patch", fileURL: patchURL, mimeType: "text/html"),
            ]
        ))
    }
}


final class BrowserPanelOmnibarPillBackgroundColorTests: XCTestCase {
    func testLightModeSlightlyDarkensThemeBackground() {
        assertResolvedColorMatchesExpectedBlend(for: .light, darkenMix: 0.04)
    }

    func testDarkModeSlightlyDarkensThemeBackground() {
        assertResolvedColorMatchesExpectedBlend(for: .dark, darkenMix: 0.05)
    }

    func testTransparentGhosttyBackgroundUsesCompositedOmnibarPill() {
        let baseColor = NSColor(srgbRed: 0.94, green: 0.93, blue: 0.91, alpha: 1.0)
        let themeBackground = GhosttyBackgroundTheme.color(backgroundColor: baseColor, opacity: 0.42)

        guard let actual = resolvedBrowserOmnibarPillBackgroundColor(
            for: .light,
            themeBackgroundColor: themeBackground
        ).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(actual.alphaComponent, 1.0, accuracy: 0.001)
    }

    private func assertResolvedColorMatchesExpectedBlend(
        for colorScheme: ColorScheme,
        darkenMix: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let themeBackground = NSColor(srgbRed: 0.94, green: 0.93, blue: 0.91, alpha: 1.0)
        let expected = themeBackground.blended(withFraction: darkenMix, of: .black) ?? themeBackground

        guard
            let actual = resolvedBrowserOmnibarPillBackgroundColor(
                for: colorScheme,
                themeBackgroundColor: themeBackground
            ).usingColorSpace(.sRGB),
            let expectedSRGB = expected.usingColorSpace(.sRGB),
            let themeSRGB = themeBackground.usingColorSpace(.sRGB)
        else {
            XCTFail("Expected sRGB-convertible colors", file: file, line: line)
            return
        }

        XCTAssertEqual(actual.redComponent, expectedSRGB.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expectedSRGB.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expectedSRGB.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, expectedSRGB.alphaComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertNotEqual(actual.redComponent, themeSRGB.redComponent, file: file, line: line)
    }
}


@MainActor
final class BrowserPanelProfileIsolationTests: XCTestCase {
    func testStaleDidFinishDoesNotRecordVisitIntoSwitchedProfileHistory() throws {
        let alternateProfile = try makeTemporaryBrowserPanelProfile(named: "Switched")
        let defaultStore = BrowserHistoryStore.shared
        let alternateStore = BrowserProfileStore.shared.historyStore(for: alternateProfile.id)
        defaultStore.clearHistory()
        alternateStore.clearHistory()
        defer {
            defaultStore.clearHistory()
            alternateStore.clearHistory()
        }

        let panel = BrowserPanel(
            workspaceId: UUID(),
            profileID: BrowserProfileStore.shared.builtInDefaultProfileID
        )
        let staleWebView = panel.webView
        let staleDelegate = try XCTUnwrap(staleWebView.navigationDelegate)
        let staleURL = try XCTUnwrap(URL(string: "https://example.com/stale-finish"))
        staleWebView.loadHTMLString(
            "<html><head><title>Stale</title></head><body>stale</body></html>",
            baseURL: staleURL
        )

        XCTAssertTrue(
            panel.switchToProfile(alternateProfile.id),
            "Expected profile switch to succeed, current=\(panel.profileID) requested=\(alternateProfile.id) exists=\(BrowserProfileStore.shared.profileDefinition(id: alternateProfile.id) != nil)"
        )
        defaultStore.clearHistory()
        alternateStore.clearHistory()

        staleDelegate.webView?(staleWebView, didFinish: nil)
        drainBrowserPanelMainQueue()

        XCTAssertTrue(
            defaultStore.entries.isEmpty,
            "Expected stale completion callbacks to avoid writing into the old profile history store, found \(defaultStore.entries.map { $0.url })"
        )
        XCTAssertTrue(
            alternateStore.entries.isEmpty,
            "Expected stale completion callbacks to avoid writing into the newly selected profile history store, found \(alternateStore.entries.map { $0.url })"
        )
    }
}


@MainActor
final class BrowserPanelAddressBarFocusRequestTests: XCTestCase {
    func testRequestPersistsUntilAcknowledged() {
        let panel = BrowserPanel(workspaceId: UUID())
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)

        let requestId = panel.requestAddressBarFocus()
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, requestId)
        XCTAssertEqual(panel.pendingAddressBarFocusSelectionIntent, .preserveFieldEditorSelection)
        XCTAssertTrue(panel.shouldSuppressWebViewFocus())

        panel.acknowledgeAddressBarFocusRequest(requestId)
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)
        XCTAssertEqual(panel.pendingAddressBarFocusSelectionIntent, .preserveFieldEditorSelection)

        // Acknowledgement only clears the durable request; focus suppression follows
        // explicit blur state transitions.
        XCTAssertTrue(panel.shouldSuppressWebViewFocus())
        panel.endSuppressWebViewFocusForAddressBar()
        XCTAssertFalse(panel.shouldSuppressWebViewFocus())
    }

    func testRequestCoalescesWhilePending() {
        let panel = BrowserPanel(workspaceId: UUID())
        let firstRequest = panel.requestAddressBarFocus(selectionIntent: .preserveFieldEditorSelection)
        let secondRequest = panel.requestAddressBarFocus()

        XCTAssertEqual(firstRequest, secondRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, firstRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusSelectionIntent, .preserveFieldEditorSelection)
    }

    func testExplicitSelectAllRequestUpgradesPendingPreserveRequest() {
        let panel = BrowserPanel(workspaceId: UUID())
        let firstRequest = panel.requestAddressBarFocus(selectionIntent: .preserveFieldEditorSelection)
        let secondRequest = panel.requestAddressBarFocus(selectionIntent: .selectAll)

        XCTAssertNotEqual(firstRequest, secondRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, secondRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusSelectionIntent, .selectAll)
    }

    func testStaleAcknowledgementDoesNotClearNewestRequest() {
        let panel = BrowserPanel(workspaceId: UUID())
        let firstRequest = panel.requestAddressBarFocus()
        panel.acknowledgeAddressBarFocusRequest(firstRequest)
        let secondRequest = panel.requestAddressBarFocus()

        XCTAssertNotEqual(firstRequest, secondRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, secondRequest)

        panel.acknowledgeAddressBarFocusRequest(firstRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, secondRequest)

        panel.acknowledgeAddressBarFocusRequest(secondRequest)
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)
    }
}


@MainActor
final class BrowserPanelReactGrabBridgeTests: XCTestCase {
    @MainActor
    func testExplicitWebViewFocusDoesNotSuppressOmnibarAutofocusWhenFocusFails() {
        let panel = BrowserPanel(workspaceId: UUID())

        XCTAssertFalse(panel.shouldSuppressOmnibarAutofocus())
        XCTAssertFalse(panel.requestExplicitWebViewFocus())
        XCTAssertFalse(panel.shouldSuppressOmnibarAutofocus())
    }

    func testOmnibarVisibilityIsPanelScopedAndFocusRequestShowsIt() {
        let panel = BrowserPanel(workspaceId: UUID())

        XCTAssertTrue(panel.isOmnibarVisible)
        _ = panel.requestAddressBarFocus()
        XCTAssertNotNil(panel.pendingAddressBarFocusRequestId)

        XCTAssertTrue(panel.setOmnibarVisible(false))
        XCTAssertFalse(panel.isOmnibarVisible)
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)
        XCTAssertEqual(panel.preferredFocusIntent, .webView)
        XCTAssertFalse(panel.shouldSuppressWebViewFocus())

        let requestId = panel.requestAddressBarFocus()
        XCTAssertTrue(panel.isOmnibarVisible)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, requestId)
        XCTAssertEqual(panel.preferredFocusIntent, .addressBar)
    }

    func testCopySuccessPostsPastebackNotificationAndClearsPendingTarget() throws {
        let workspaceId = UUID()
        let terminalId = UUID()
        let panel = BrowserPanel(workspaceId: workspaceId)
        let browserId = panel.id
        let expectation = expectation(description: "react grab pasteback notification")

        let observer = NotificationCenter.default.addObserver(
            forName: .reactGrabDidCopySelection,
            object: nil,
            queue: .main
        ) { notification in
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.workspaceId] as? UUID, workspaceId)
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.browserPanelId] as? UUID, browserId)
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.returnPanelId] as? UUID, terminalId)
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.content] as? String, "<button>Save</button>")
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        panel.armReactGrabRoundTrip(returnTo: terminalId)
        XCTAssertEqual(panel.pendingReactGrabReturnTargetPanelId, terminalId)
        let token = try XCTUnwrap(panel.pendingReactGrabRoundTripToken)

        panel.handleReactGrabBridgeMessage(.copySuccess(content: "<button>Save</button>", token: token))

        wait(for: [expectation], timeout: 1.0)
        XCTAssertNil(panel.pendingReactGrabReturnTargetPanelId)
        XCTAssertNil(panel.pendingReactGrabRoundTripToken)
    }

    func testInactiveStateKeepsPendingTargetUntilCopySuccess() throws {
        let workspaceId = UUID()
        let terminalId = UUID()
        let panel = BrowserPanel(workspaceId: workspaceId)
        let browserId = panel.id
        let expectation = expectation(description: "react grab pasteback notification after deactivate")

        let observer = NotificationCenter.default.addObserver(
            forName: .reactGrabDidCopySelection,
            object: nil,
            queue: .main
        ) { notification in
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.workspaceId] as? UUID, workspaceId)
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.browserPanelId] as? UUID, browserId)
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.returnPanelId] as? UUID, terminalId)
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.content] as? String, "<button>Save</button>")
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        panel.armReactGrabRoundTrip(returnTo: terminalId)
        XCTAssertEqual(panel.pendingReactGrabReturnTargetPanelId, terminalId)
        let token = try XCTUnwrap(panel.pendingReactGrabRoundTripToken)

        panel.handleReactGrabBridgeMessage(.stateChange(isActive: false))

        XCTAssertEqual(panel.pendingReactGrabReturnTargetPanelId, terminalId)
        XCTAssertFalse(panel.isReactGrabActive)

        panel.handleReactGrabBridgeMessage(.copySuccess(content: "<button>Save</button>", token: token))

        wait(for: [expectation], timeout: 1.0)
        XCTAssertNil(panel.pendingReactGrabReturnTargetPanelId)
        XCTAssertNil(panel.pendingReactGrabRoundTripToken)
    }

    func testResetStateCanPreservePendingTargetUntilCopySuccess() throws {
        let workspaceId = UUID()
        let terminalId = UUID()
        let panel = BrowserPanel(workspaceId: workspaceId)
        let browserId = panel.id
        let expectation = expectation(description: "react grab pasteback notification after reset")

        let observer = NotificationCenter.default.addObserver(
            forName: .reactGrabDidCopySelection,
            object: nil,
            queue: .main
        ) { notification in
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.workspaceId] as? UUID, workspaceId)
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.browserPanelId] as? UUID, browserId)
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.returnPanelId] as? UUID, terminalId)
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.content] as? String, "<button>Save</button>")
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        panel.armReactGrabRoundTrip(returnTo: terminalId)
        panel.handleReactGrabBridgeMessage(.stateChange(isActive: true))
        let token = try XCTUnwrap(panel.pendingReactGrabRoundTripToken)

        panel.resetReactGrabState(
            preserveRoundTrip: true,
            reason: "test.navigation"
        )

        XCTAssertFalse(panel.isReactGrabActive)
        XCTAssertEqual(panel.pendingReactGrabReturnTargetPanelId, terminalId)

        panel.handleReactGrabBridgeMessage(.copySuccess(content: "<button>Save</button>", token: token))

        wait(for: [expectation], timeout: 1.0)
        XCTAssertNil(panel.pendingReactGrabReturnTargetPanelId)
        XCTAssertNil(panel.pendingReactGrabRoundTripToken)
    }

    func testMismatchedCopyTokenDropsPastebackAndClearsPendingTarget() {
        let terminalId = UUID()
        let panel = BrowserPanel(workspaceId: UUID())
        let invertedExpectation = expectation(description: "react grab pasteback notification")
        invertedExpectation.isInverted = true

        let observer = NotificationCenter.default.addObserver(
            forName: .reactGrabDidCopySelection,
            object: nil,
            queue: .main
        ) { _ in
            invertedExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        panel.armReactGrabRoundTrip(returnTo: terminalId)
        XCTAssertEqual(panel.pendingReactGrabReturnTargetPanelId, terminalId)
        XCTAssertNotNil(panel.pendingReactGrabRoundTripToken)

        panel.handleReactGrabBridgeMessage(.copySuccess(content: "<button>Save</button>", token: nil))

        wait(for: [invertedExpectation], timeout: 0.1)
        XCTAssertNil(panel.pendingReactGrabReturnTargetPanelId)
        XCTAssertNil(panel.pendingReactGrabRoundTripToken)
    }

    func testCopySuccessStripsDangerousInvisibleScalarsBeforePastebackNotification() throws {
        let workspaceId = UUID()
        let terminalId = UUID()
        let panel = BrowserPanel(workspaceId: workspaceId)
        let expectation = expectation(description: "react grab pasteback notification")
        let rawContent = "<button>Sa\u{202E}v\u{200B}e</button>\u{2069}\n"

        let observer = NotificationCenter.default.addObserver(
            forName: .reactGrabDidCopySelection,
            object: nil,
            queue: .main
        ) { notification in
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.content] as? String, "<button>Save</button>\n")
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        panel.armReactGrabRoundTrip(returnTo: terminalId)
        let token = try XCTUnwrap(panel.pendingReactGrabRoundTripToken)

        panel.handleReactGrabBridgeMessage(.copySuccess(content: rawContent, token: token))

        wait(for: [expectation], timeout: 1.0)
    }

    func testEnsureReactGrabActiveRefreshesBridgeSessionTokenWhenAlreadyActive() async throws {
        let panel = BrowserPanel(workspaceId: UUID())

        _ = try await panel.evaluateJavaScript(
            """
            window['\(panel.reactGrabBridgeSessionUpdaterName)'] = function(token) {
                window.__cmuxTestRoundTripToken = token;
                return true;
            };
            true;
            """
        )

        panel.handleReactGrabBridgeMessage(.stateChange(isActive: true))
        panel.armReactGrabRoundTrip(returnTo: UUID())
        let token = try XCTUnwrap(panel.pendingReactGrabRoundTripToken)

        await panel.ensureReactGrabActive()

        let refreshedToken = try await panel.evaluateJavaScript("window.__cmuxTestRoundTripToken") as? String
        XCTAssertEqual(refreshedToken, token)
    }
}


@MainActor
final class WindowBrowserHostViewTests: XCTestCase {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class FakeTabBarBackgroundNSView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class PrimaryPageProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class WKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class EdgeTransparentWKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = convert(point, from: superview)
            guard bounds.contains(localPoint) else { return nil }
            return localPoint.x <= 12 ? nil : self
        }
    }

    private final class TrailingEdgeTransparentWKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = convert(point, from: superview)
            guard bounds.contains(localPoint) else { return nil }
            return localPoint.x >= bounds.maxX - 12 ? nil : self
        }
    }

    private final class BonsplitMockSplitDelegate: NSObject, NSSplitViewDelegate {}

    private func makeMouseEvent(type: NSEvent.EventType, location: NSPoint, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) mouse event")
        }
        return event
    }

    private func isInspectorOwnedHit(_ hit: NSView?, inspectorView: NSView, pageView: NSView) -> Bool {
        guard let hit else { return false }
        if hit === pageView || hit.isDescendant(of: pageView) {
            return false
        }
        if hit === inspectorView || hit.isDescendant(of: inspectorView) {
            return true
        }
        return inspectorView.isDescendant(of: hit) && !(pageView === hit || pageView.isDescendant(of: hit))
    }

    private struct TabStripPassThroughFixture {
        let host: WindowBrowserHostView
        let pointInHost: NSPoint
    }

    private func installTabStripPassThroughFixture(in window: NSWindow) -> TabStripPassThroughFixture? {
        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected window content container")
            return nil
        }

        let tabStripHeight: CGFloat = 44
        let tabStrip = FakeTabBarBackgroundNSView(
            frame: NSRect(
                x: 0,
                y: contentView.bounds.maxY - tabStripHeight,
                width: contentView.bounds.width,
                height: tabStripHeight
            )
        )
        tabStrip.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(tabStrip)

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        let child = CapturingView(frame: host.bounds)
        child.autoresizingMask = [.width, .height]
        host.addSubview(child)
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let titlebarBandHeight = max(28, min(72, window.frame.height - window.contentLayoutRect.height))
        let pointInContent = NSPoint(
            x: contentView.bounds.midX,
            y: contentView.bounds.maxY - titlebarBandHeight - 8
        )
        let pointInWindow = contentView.convert(pointInContent, to: nil)
        let pointInHost = host.convert(pointInWindow, from: nil)
        return TabStripPassThroughFixture(host: host, pointInHost: pointInHost)
    }

    func testHostViewPassesThroughUnderlyingTabStripInSecondWindowBelowTitlebarBand() {
        // The reported regression (#3193) was that the original window kept
        // working but later-created windows did not. Set up two windows and
        // assert the pass-through holds in BOTH to lock in per-instance wiring.
        let firstWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 32, y: 32, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            secondWindow.orderOut(nil)
            firstWindow.orderOut(nil)
        }

        guard let firstFixture = installTabStripPassThroughFixture(in: firstWindow),
              let secondFixture = installTabStripPassThroughFixture(in: secondWindow) else {
            return
        }

        XCTAssertNil(
            firstFixture.host.hitTest(firstFixture.pointInHost),
            "Browser portal should defer to the minimal tab strip in the original window just below the titlebar interaction band"
        )
        XCTAssertNil(
            secondFixture.host.hitTest(secondFixture.pointInHost),
            "Browser portal should defer to the minimal tab strip in later-created windows just below the titlebar interaction band"
        )
    }

    func testHostViewPassesThroughDividerWhenAdjacentPaneIsCollapsed() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let splitView = NSSplitView(frame: contentView.bounds)
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let splitDelegate = BonsplitMockSplitDelegate()
        splitView.delegate = splitDelegate
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: contentView.bounds.height))
        let second = NSView(frame: NSRect(x: 121, y: 0, width: 179, height: contentView.bounds.height))
        splitView.addSubview(first)
        splitView.addSubview(second)
        contentView.addSubview(splitView)
        splitView.setPosition(1, ofDividerAt: 0)
        splitView.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        let child = CapturingView(frame: host.bounds)
        child.autoresizingMask = [.width, .height]
        host.addSubview(child)
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let dividerPointInSplit = NSPoint(
            x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5),
            y: splitView.bounds.midY
        )
        let dividerPointInWindow = splitView.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        XCTAssertLessThanOrEqual(splitView.arrangedSubviews[0].frame.width, 1.5)
        XCTAssertNil(
            host.hitTest(dividerPointInHost),
            "Browser host must pass through divider hits even when one pane is nearly collapsed"
        )

        let contentPointInSplit = NSPoint(x: dividerPointInSplit.x + 40, y: splitView.bounds.midY)
        let contentPointInWindow = splitView.convert(contentPointInSplit, to: nil)
        let contentPointInHost = host.convert(contentPointInWindow, from: nil)
        XCTAssertTrue(host.hitTest(contentPointInHost) === child)
    }

    func testWindowBrowserPortalIgnoresHostedInspectorSplitResizeNotifications() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let appSplit = NSSplitView(frame: contentView.bounds)
        appSplit.autoresizingMask = [.width, .height]
        appSplit.isVertical = true
        appSplit.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: contentView.bounds.height)))
        appSplit.addSubview(NSView(frame: NSRect(x: 121, y: 0, width: 299, height: contentView.bounds.height)))
        contentView.addSubview(appSplit)

        let inspectorSplit = NSSplitView(frame: host.bounds)
        inspectorSplit.autoresizingMask = [.width, .height]
        inspectorSplit.isVertical = true
        inspectorSplit.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: host.bounds.height)))
        inspectorSplit.addSubview(NSView(frame: NSRect(x: 121, y: 0, width: 299, height: host.bounds.height)))
        host.addSubview(inspectorSplit)

        XCTAssertTrue(
            WindowBrowserPortal.shouldTreatSplitResizeAsExternalGeometry(
                appSplit,
                window: window,
                hostView: host
            ),
            "App layout splits should still trigger browser portal geometry sync"
        )
        XCTAssertFalse(
            WindowBrowserPortal.shouldTreatSplitResizeAsExternalGeometry(
                inspectorSplit,
                window: window,
                hostView: host
            ),
            "Hosted DevTools/internal splits should not trigger browser portal geometry sync"
        )
    }

    func testDragHoverEventsPassThroughForTabTransferOnBrowserHoverEvents() {
        XCTAssertTrue(
            WindowBrowserHostView.shouldPassThroughToDragTargets(
                pasteboardTypes: [DragOverlayRoutingPolicy.bonsplitTabTransferType],
                eventType: .cursorUpdate
            )
        )
        XCTAssertTrue(
            WindowBrowserHostView.shouldPassThroughToDragTargets(
                pasteboardTypes: [DragOverlayRoutingPolicy.bonsplitTabTransferType],
                eventType: .mouseEntered
            )
        )
    }

    func testDragHoverEventsPassThroughForSidebarReorderWithoutMouseButtonState() {
        XCTAssertTrue(
            WindowBrowserHostView.shouldPassThroughToDragTargets(
                pasteboardTypes: [DragOverlayRoutingPolicy.sidebarTabReorderType],
                eventType: .cursorUpdate
            )
        )
    }

    func testDragHoverEventsDoNotPassThroughForUnrelatedPasteboardTypes() {
        let externalPayloads: [[NSPasteboard.PasteboardType]] = [
            [.fileURL],
            [.URL],
            [.png],
            [.tiff],
            [.html],
            [.string],
            [.fileURL, .png],
        ]

        for pasteboardTypes in externalPayloads {
            XCTAssertFalse(
                WindowBrowserHostView.shouldPassThroughToDragTargets(
                    pasteboardTypes: pasteboardTypes,
                    eventType: .cursorUpdate
                ),
                "Browser host should keep external drag payload in WebKit: \(pasteboardTypes)"
            )
        }
        XCTAssertFalse(
            WindowBrowserHostView.shouldPassThroughToDragTargets(
                pasteboardTypes: [.fileURL],
                eventType: .leftMouseDragged
            )
        )
        XCTAssertFalse(
            DragOverlayRoutingPolicy.shouldPassThroughPortalHitTesting(
                pasteboardTypes: [.fileURL],
                eventType: .leftMouseDragged
            )
        )
        XCTAssertTrue(
            DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
                pasteboardTypes: [.fileURL],
                eventType: .leftMouseDragged
            )
        )
        XCTAssertFalse(
            DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
                pasteboardTypes: [.fileURL],
                eventType: .mouseMoved
            )
        )
    }

    func testHostViewKeepsHostedInspectorDividerInteractive() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        // Underlying app layout split that should still be pass-through.
        let appSplit = NSSplitView(frame: contentView.bounds)
        appSplit.autoresizingMask = [.width, .height]
        appSplit.isVertical = true
        appSplit.dividerStyle = .thin
        let appSplitDelegate = BonsplitMockSplitDelegate()
        appSplit.delegate = appSplitDelegate
        let leading = NSView(frame: NSRect(x: 0, y: 0, width: 210, height: contentView.bounds.height))
        let trailing = NSView(frame: NSRect(x: 211, y: 0, width: 209, height: contentView.bounds.height))
        appSplit.addSubview(leading)
        appSplit.addSubview(trailing)
        contentView.addSubview(appSplit)
        appSplit.adjustSubviews()

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        // WebKit inspector uses an internal split (page + console). Divider drags
        // here must stay in hosted content, not pass through to appSplit behind it.
        let inspectorSplit = NSSplitView(frame: host.bounds)
        inspectorSplit.autoresizingMask = [.width, .height]
        inspectorSplit.isVertical = false
        inspectorSplit.dividerStyle = .thin
        let inspectorDelegate = BonsplitMockSplitDelegate()
        inspectorSplit.delegate = inspectorDelegate
        let pageView = CapturingView(frame: NSRect(x: 0, y: 0, width: host.bounds.width, height: 160))
        let consoleView = CapturingView(frame: NSRect(x: 0, y: 161, width: host.bounds.width, height: 99))
        inspectorSplit.addSubview(pageView)
        inspectorSplit.addSubview(consoleView)
        host.addSubview(inspectorSplit)
        inspectorSplit.setPosition(160, ofDividerAt: 0)
        inspectorSplit.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        let appDividerPointInSplit = NSPoint(
            x: appSplit.arrangedSubviews[0].frame.maxX + (appSplit.dividerThickness * 0.5),
            y: appSplit.bounds.midY
        )
        let appDividerPointInWindow = appSplit.convert(appDividerPointInSplit, to: nil)
        let appDividerPointInHost = host.convert(appDividerPointInWindow, from: nil)
        XCTAssertNil(
            host.hitTest(appDividerPointInHost),
            "Underlying app split divider should still pass through with a hosted inspector split present"
        )

        let dividerPointInInspector = NSPoint(
            x: inspectorSplit.bounds.midX,
            y: inspectorSplit.arrangedSubviews[0].frame.maxY + (inspectorSplit.dividerThickness * 0.5)
        )
        let dividerPointInWindow = inspectorSplit.convert(dividerPointInInspector, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        let hit = host.hitTest(dividerPointInHost)

        XCTAssertNotNil(
            hit,
            "Inspector divider should receive hit-testing in hosted content, not pass through"
        )
        XCTAssertFalse(hit === host)
        if let hit {
            XCTAssertTrue(
                hit === inspectorSplit || hit.isDescendant(of: inspectorSplit),
                "Expected hit to remain inside inspector split subtree"
            )
        }
    }

    func testHostViewKeepsHostedVerticalInspectorDividerInteractiveAtSlotLeadingEdge() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let inspectorSplit = NSSplitView(frame: slot.bounds)
        inspectorSplit.autoresizingMask = [.width, .height]
        inspectorSplit.isVertical = true
        inspectorSplit.dividerStyle = .thin
        let inspectorDelegate = BonsplitMockSplitDelegate()
        inspectorSplit.delegate = inspectorDelegate
        let pageView = CapturingView(frame: NSRect(x: 0, y: 0, width: 1, height: slot.bounds.height))
        let inspectorView = CapturingView(
            frame: NSRect(x: 2, y: 0, width: slot.bounds.width - 2, height: slot.bounds.height)
        )
        inspectorSplit.addSubview(pageView)
        inspectorSplit.addSubview(inspectorView)
        slot.addSubview(inspectorSplit)
        inspectorSplit.setPosition(1, ofDividerAt: 0)
        inspectorSplit.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSplit = NSPoint(
            x: inspectorSplit.arrangedSubviews[0].frame.maxX + (inspectorSplit.dividerThickness * 0.5),
            y: inspectorSplit.bounds.midY
        )
        let dividerPointInWindow = inspectorSplit.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)

        XCTAssertLessThanOrEqual(inspectorSplit.arrangedSubviews[0].frame.width, 1.5)
        XCTAssertTrue(
            abs(dividerPointInHost.x - slot.frame.minX) <= 2,
            "Expected collapsed hosted divider to overlap the browser slot leading-edge resizer zone"
        )

        let hit = host.hitTest(dividerPointInHost)
        XCTAssertNotNil(
            hit,
            "Hosted vertical inspector divider should stay interactive even when collapsed onto the slot edge"
        )
        XCTAssertFalse(hit === host)
        if let hit {
            XCTAssertTrue(
                hit === inspectorSplit || hit.isDescendant(of: inspectorSplit),
                "Expected hit to remain inside hosted inspector split subtree at the slot edge"
            )
        }
    }

    func testHostViewPrefersNativeHostedInspectorSiblingDividerHit() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: slot.bounds.height))
        let inspectorView = WKInspectorProbeView(
            frame: NSRect(x: 92, y: 0, width: slot.bounds.width - 92, height: slot.bounds.height)
        )
        slot.addSubview(pageView)
        slot.addSubview(inspectorView)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorView.frame.minX + 2, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        let bodyPointInSlot = NSPoint(x: inspectorView.frame.minX + 18, y: slot.bounds.midY)
        let bodyPointInWindow = slot.convert(bodyPointInSlot, to: nil)
        let bodyPointInHost = host.convert(bodyPointInWindow, from: nil)

        let dividerHit = host.hitTest(dividerPointInHost)
        XCTAssertTrue(
            isInspectorOwnedHit(dividerHit, inspectorView: inspectorView, pageView: pageView),
            "Hosted right-docked inspector divider should stay on the native WebKit hit path when WebKit exposes a hittable inspector-side view. actual=\(String(describing: dividerHit))"
        )
        let interiorHit = host.hitTest(bodyPointInHost)
        XCTAssertTrue(
            isInspectorOwnedHit(interiorHit, inspectorView: inspectorView, pageView: pageView),
            "Only the divider edge should be claimed; interior inspector hits should still reach WebKit content. actual=\(String(describing: interiorHit))"
        )
    }

    func testHostViewPrefersNativeNestedHostedInspectorSiblingDividerHit() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let wrapper = NSView(frame: slot.bounds)
        wrapper.autoresizingMask = [.width, .height]
        slot.addSubview(wrapper)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: wrapper.bounds.height))
        let inspectorContainer = NSView(
            frame: NSRect(x: 92, y: 0, width: wrapper.bounds.width - 92, height: wrapper.bounds.height)
        )
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        wrapper.addSubview(pageView)
        wrapper.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorContainer.frame.minX + 2, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        let bodyPointInSlot = NSPoint(x: inspectorContainer.frame.minX + 18, y: slot.bounds.midY)
        let bodyPointInWindow = slot.convert(bodyPointInSlot, to: nil)
        let bodyPointInHost = host.convert(bodyPointInWindow, from: nil)

        let dividerHit = host.hitTest(dividerPointInHost)
        XCTAssertTrue(
            isInspectorOwnedHit(dividerHit, inspectorView: inspectorView, pageView: pageView),
            "Portal host should prefer the native nested WebKit hit target on the right-docked divider when available. actual=\(String(describing: dividerHit))"
        )
        let interiorHit = host.hitTest(bodyPointInHost)
        XCTAssertTrue(
            isInspectorOwnedHit(interiorHit, inspectorView: inspectorView, pageView: pageView),
            "Only the divider edge should be claimed; interior nested inspector hits should still reach WebKit content. actual=\(String(describing: interiorHit))"
        )
    }

    func testHostViewReappliesStoredHostedInspectorWidthAfterSlotLayoutReset() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let wrapper = NSView(frame: slot.bounds)
        wrapper.autoresizingMask = [.width, .height]
        slot.addSubview(wrapper)

        let originalPageFrame = NSRect(x: 0, y: 0, width: 92, height: wrapper.bounds.height)
        let originalInspectorFrame = NSRect(
            x: 92,
            y: 0,
            width: wrapper.bounds.width - 92,
            height: wrapper.bounds.height
        )
        let pageView = PrimaryPageProbeView(frame: originalPageFrame)
        let inspectorContainer = NSView(frame: originalInspectorFrame)
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        wrapper.addSubview(pageView)
        wrapper.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorContainer.frame.minX, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 48, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        let draggedPageWidth = pageView.frame.width
        let draggedInspectorMinX = inspectorContainer.frame.minX
        XCTAssertGreaterThan(draggedPageWidth, originalPageFrame.width)
        XCTAssertGreaterThan(draggedInspectorMinX, originalInspectorFrame.minX)

        pageView.frame = originalPageFrame
        inspectorContainer.frame = originalInspectorFrame
        slot.needsLayout = true
        slot.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(pageView.frame.width, draggedPageWidth, accuracy: 0.5)
        XCTAssertEqual(inspectorContainer.frame.minX, draggedInspectorMinX, accuracy: 0.5)
    }

    func testHostViewFallsBackToManualHostedInspectorDragWhenNativeDividerHitIsUnavailable() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: slot.bounds.height))
        let inspectorView = EdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 92, y: 0, width: slot.bounds.width - 92, height: slot.bounds.height)
        )
        slot.addSubview(pageView)
        slot.addSubview(inspectorView)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorView.frame.minX + 2, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)

        let dividerHit = host.hitTest(dividerPointInHost)
        XCTAssertTrue(
            dividerHit === host,
            "Host should only take the manual fallback path when the right-docked divider edge is not natively hittable. actual=\(String(describing: dividerHit))"
        )

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 40, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThan(pageView.frame.width, 92)
        XCTAssertGreaterThan(inspectorView.frame.minX, 92)
    }

    func testHostViewFallsBackToManualHostedInspectorDragForLeftDockedInspector() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let inspectorView = TrailingEdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 0, y: 0, width: 92, height: slot.bounds.height)
        )
        let pageView = PrimaryPageProbeView(
            frame: NSRect(x: 92, y: 0, width: slot.bounds.width - 92, height: slot.bounds.height)
        )
        slot.addSubview(inspectorView)
        slot.addSubview(pageView)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorView.frame.maxX - 2, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)

        XCTAssertTrue(
            host.hitTest(dividerPointInHost) === host,
            "Host should take the manual fallback path for a left-docked divider when the native edge is not hittable"
        )

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 40, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThan(inspectorView.frame.width, 92)
        XCTAssertGreaterThan(pageView.frame.minX, 92)
    }

    func testHostViewClaimsCollapsedHostedInspectorSiblingDividerAtSlotLeadingEdge() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 0, height: slot.bounds.height))
        let inspectorView = WKInspectorProbeView(frame: slot.bounds)
        slot.addSubview(pageView)
        slot.addSubview(inspectorView)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorView.frame.minX + 2, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)

        XCTAssertLessThanOrEqual(dividerPointInHost.x - slot.frame.minX, 2)
        let dividerHit = host.hitTest(dividerPointInHost)
        XCTAssertTrue(
            isInspectorOwnedHit(dividerHit, inspectorView: inspectorView, pageView: pageView),
            "Collapsed right-docked hosted inspector divider should stay on the native WebKit hit path while still beating the sidebar-resizer overlap zone. actual=\(String(describing: dividerHit))"
        )
    }
}


@MainActor
final class BrowserPanelHostContainerViewTests: XCTestCase {
    private final class PrimaryPageProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class TrackingInspectorFrontendWebView: WKWebView {
        private(set) var evaluatedJavaScript: [String] = []

        @MainActor override func evaluateJavaScript(
            _ javaScriptString: String,
            completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil
        ) {
            evaluatedJavaScript.append(javaScriptString)
            completionHandler?(nil, nil)
        }
    }

    private final class WKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class EdgeTransparentWKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = convert(point, from: superview)
            guard bounds.contains(localPoint) else { return nil }
            return localPoint.x <= 12 ? nil : self
        }
    }

    private final class TrailingEdgeTransparentWKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = convert(point, from: superview)
            guard bounds.contains(localPoint) else { return nil }
            return localPoint.x >= bounds.maxX - 12 ? nil : self
        }
    }

    private func makeMouseEvent(type: NSEvent.EventType, location: NSPoint, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) mouse event")
        }
        return event
    }

    func testBrowserPanelHostPrefersNativeHostedInspectorSiblingDividerHit() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: webViewRoot.bounds.height))
        let inspectorContainer = NSView(
            frame: NSRect(x: 92, y: 0, width: webViewRoot.bounds.width - 92, height: webViewRoot.bounds.height)
        )
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.midY)
        let bodyPointInHost = NSPoint(x: inspectorContainer.frame.minX + 18, y: host.bounds.midY)
        let interiorHit = host.hitTest(bodyPointInHost)

        XCTAssertTrue(
            host.hitTest(dividerPointInHost) === host,
            "Browser panel host should claim the right-docked divider edge for the manual resize path"
        )
        XCTAssertTrue(
            interiorHit == nil || interiorHit !== host,
            "Only the divider edge should be claimed; interior inspector hits should not be stolen by the host. actual=\(String(describing: interiorHit))"
        )
    }

    func testBrowserPanelHostClaimsCollapsedHostedInspectorSiblingDividerAtLeadingEdge() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 0, height: webViewRoot.bounds.height))
        let inspectorContainer = NSView(frame: webViewRoot.bounds)
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        XCTAssertTrue(
            host.hitTest(dividerPointInHost) === host,
            "Collapsed right-docked divider should stay on the manual browser-panel resize path while beating the sidebar-resizer overlap"
        )

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 36, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThan(pageView.frame.width, 0)
        XCTAssertGreaterThan(inspectorContainer.frame.minX, 0)
    }

    func testBrowserPanelHostClaimsHostedInspectorDividerAcrossFullHeight() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 20, width: 92, height: webViewRoot.bounds.height - 40))
        let inspectorContainer = EdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 92, y: 20, width: webViewRoot.bounds.width - 92, height: webViewRoot.bounds.height - 40)
        )
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            host.hitTest(NSPoint(x: inspectorContainer.frame.minX + 2, y: 4)) === host,
            "The custom DevTools divider should remain draggable at the top edge of the browser pane"
        )
        XCTAssertTrue(
            host.hitTest(NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.maxY - 4)) === host,
            "The custom DevTools divider should remain draggable at the bottom edge of the browser pane"
        )
    }

    func testBrowserPanelHostFallsBackToManualHostedInspectorDragWhenNativeDividerHitIsUnavailable() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: webViewRoot.bounds.height))
        let inspectorContainer = EdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 92, y: 0, width: webViewRoot.bounds.width - 92, height: webViewRoot.bounds.height)
        )
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        XCTAssertTrue(
            host.hitTest(dividerPointInHost) === host,
            "Browser panel host should only take the manual fallback path when the divider edge is not natively hittable"
        )

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 40, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThan(pageView.frame.width, 92)
        XCTAssertGreaterThan(inspectorContainer.frame.minX, 92)
    }

    func testBrowserPanelHostKeepsInspectorResizableAfterShrinkingToMinimumWidth() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: webViewRoot.bounds.height))
        let inspectorContainer = EdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 92, y: 0, width: webViewRoot.bounds.width - 92, height: webViewRoot.bounds.height)
        )
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        host.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window))
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 220, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThanOrEqual(
            inspectorContainer.frame.width,
            120,
            "Shrinking the DevTools pane should clamp to a recoverable minimum width"
        )
        XCTAssertTrue(
            host.hitTest(NSPoint(x: inspectorContainer.frame.minX + 2, y: 4)) === host,
            "After clamping, the DevTools divider should still be draggable near the top edge"
        )
        XCTAssertTrue(
            host.hitTest(NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.maxY - 4)) === host,
            "After clamping, the DevTools divider should still be draggable near the bottom edge"
        )
    }

    func testBrowserPanelHostPromotesVisibleRightDockedInspectorIntoManagedSideDock() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let slotView = host.ensureLocalInlineSlotView()
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 92, height: host.bounds.height + 180))
        let inspectorView = WKWebView(
            frame: NSRect(x: 92, y: 0, width: slotView.bounds.width - 92, height: host.bounds.height)
        )
        slotView.addSubview(pageView)
        slotView.addSubview(inspectorView)
        host.pinHostedWebView(pageView, in: slotView)
        host.setHostedInspectorFrontendWebView(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded(),
            "A visible right-docked inspector should not wait on async dock-configuration JS before entering the managed side-dock path"
        )
        XCTAssertTrue(
            pageView.superview === inspectorView.superview && pageView.superview !== slotView,
            "Promotion should move both hosted inspector siblings into the managed side-dock container"
        )
        XCTAssertEqual(
            pageView.frame.height,
            host.bounds.height,
            accuracy: 0.5,
            "Promotion should normalize stale page heights to the host height so the page layer stops covering the divider"
        )
        XCTAssertEqual(
            inspectorView.frame.height,
            host.bounds.height,
            accuracy: 0.5,
            "Promotion should normalize the inspector height to the host height"
        )
    }

    func testBrowserPanelHostAllowsRightDockedInspectorToExpandLeftAfterPromotion() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let slotView = host.ensureLocalInlineSlotView()
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 92, height: host.bounds.height))
        let inspectorView = WKWebView(
            frame: NSRect(x: 92, y: 0, width: slotView.bounds.width - 92, height: host.bounds.height)
        )
        slotView.addSubview(pageView)
        slotView.addSubview(inspectorView)
        host.pinHostedWebView(pageView, in: slotView)
        host.setHostedInspectorFrontendWebView(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded(),
            "The managed side-dock path should be active before drag assertions run"
        )

        let initialPageWidth = pageView.frame.width
        let initialInspectorWidth = inspectorView.frame.width
        let dividerPointInHost = NSPoint(x: inspectorView.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        host.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window))
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x - 40, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThan(
            inspectorView.frame.width,
            initialInspectorWidth,
            "Right-docked DevTools should expand when the divider is dragged left"
        )
        XCTAssertLessThan(
            pageView.frame.width,
            initialPageWidth,
            "Expanding right-docked DevTools should shrink the page width"
        )
    }

    func testBrowserPanelHostKeepsAutomaticRightDockedWidthAboveMinimumWhileShrinking() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 140, y: 0, width: 280, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let slotView = host.ensureLocalInlineSlotView()
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 132, height: host.bounds.height))
        let inspectorView = WKWebView(
            frame: NSRect(x: 132, y: 0, width: slotView.bounds.width - 132, height: host.bounds.height)
        )
        slotView.addSubview(pageView)
        slotView.addSubview(inspectorView)
        host.pinHostedWebView(pageView, in: slotView)
        host.setHostedInspectorFrontendWebView(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded())

        host.setPreferredHostedInspectorWidth(width: 80, widthFraction: nil)
        host.setFrameSize(NSSize(width: 210, height: host.frame.height))
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(
            inspectorView.frame.width,
            120,
            "Automatic pane resize should honor the same minimum hosted inspector width as manual dragging"
        )
        XCTAssertEqual(
            inspectorView.frame.height,
            host.bounds.height,
            accuracy: 0.5,
            "Automatic shrink should keep the inspector vertically normalized to the host height"
        )
    }

    func testBrowserPanelHostRequestsBottomDockWhenSideDockLeavesTooLittlePageWidth() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 280, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let slotView = host.ensureLocalInlineSlotView()
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 120, height: host.bounds.height))
        let inspectorView = TrackingInspectorFrontendWebView(
            frame: NSRect(x: 120, y: 0, width: slotView.bounds.width - 120, height: host.bounds.height)
        )
        slotView.addSubview(pageView)
        slotView.addSubview(inspectorView)
        host.pinHostedWebView(pageView, in: slotView)
        host.setHostedInspectorFrontendWebView(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded())

        host.setFrameSize(NSSize(width: 210, height: host.frame.height))
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            inspectorView.evaluatedJavaScript.contains(where: { $0.contains("WI._dockBottom()") }),
            "Narrow pane widths should request bottom-docked DevTools instead of leaving the side-docked inspector in an unstable layout"
        )
        XCTAssertTrue(
            inspectorView.evaluatedJavaScript.contains(where: { $0.contains("const allowSideDock = false;") }),
            "Once a narrow pane proves it cannot safely side-dock DevTools, the inspector frontend should hide and disable left/right dock controls"
        )
    }

    func testBrowserPanelManagedSideDockDoesNotAutoresizeDraggedFrames() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let slotView = host.ensureLocalInlineSlotView()
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 92, height: host.bounds.height))
        let inspectorView = WKWebView(
            frame: NSRect(x: 92, y: 0, width: slotView.bounds.width - 92, height: host.bounds.height)
        )
        slotView.addSubview(pageView)
        slotView.addSubview(inspectorView)
        host.pinHostedWebView(pageView, in: slotView)
        host.setHostedInspectorFrontendWebView(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded())

        let dividerPointInHost = NSPoint(x: inspectorView.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)
        host.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window))
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x - 30, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        guard let managedContainer = pageView.superview else {
            XCTFail("Expected managed side-dock container")
            return
        }
        let draggedPageFrame = pageView.frame
        let draggedInspectorFrame = inspectorView.frame

        managedContainer.setFrameSize(
            NSSize(width: managedContainer.frame.width, height: managedContainer.frame.height + 24)
        )

        XCTAssertEqual(
            pageView.frame.origin.x,
            draggedPageFrame.origin.x,
            accuracy: 0.5,
            "Managed side-dock container should not autoresize the page back to a stale divider position"
        )
        XCTAssertEqual(
            pageView.frame.width,
            draggedPageFrame.width,
            accuracy: 0.5,
            "Managed side-dock container should preserve the dragged page width until the host explicitly reapplies layout"
        )
        XCTAssertEqual(
            inspectorView.frame.origin.x,
            draggedInspectorFrame.origin.x,
            accuracy: 0.5,
            "Managed side-dock container should preserve the dragged inspector origin"
        )
        XCTAssertEqual(
            inspectorView.frame.width,
            draggedInspectorFrame.width,
            accuracy: 0.5,
            "Managed side-dock container should preserve the dragged inspector width"
        )
    }

    func testBrowserPanelHostFallsBackToManualHostedInspectorDragForLeftDockedInspector() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let inspectorContainer = TrailingEdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 0, y: 0, width: 92, height: webViewRoot.bounds.height)
        )
        let pageView = PrimaryPageProbeView(
            frame: NSRect(x: 92, y: 0, width: webViewRoot.bounds.width - 92, height: webViewRoot.bounds.height)
        )
        webViewRoot.addSubview(inspectorContainer)
        webViewRoot.addSubview(pageView)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.maxX - 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        XCTAssertTrue(
            host.hitTest(dividerPointInHost) === host,
            "Browser panel host should take the manual fallback path for a left-docked divider when the native edge is not hittable"
        )

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 40, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThan(inspectorContainer.frame.width, 92)
        XCTAssertGreaterThan(pageView.frame.minX, 92)
    }

    func testBrowserPanelHostReappliesStoredHostedInspectorWidthAfterLayoutReset() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(
            frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height)
        )
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let originalPageFrame = NSRect(x: 0, y: 0, width: 92, height: webViewRoot.bounds.height)
        let originalInspectorFrame = NSRect(
            x: 92,
            y: 0,
            width: webViewRoot.bounds.width - 92,
            height: webViewRoot.bounds.height
        )
        let pageView = PrimaryPageProbeView(frame: originalPageFrame)
        let inspectorContainer = NSView(frame: originalInspectorFrame)
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 48, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        let draggedPageWidth = pageView.frame.width
        let draggedInspectorMinX = inspectorContainer.frame.minX
        XCTAssertGreaterThan(draggedPageWidth, originalPageFrame.width)
        XCTAssertGreaterThan(draggedInspectorMinX, originalInspectorFrame.minX)

        pageView.frame = originalPageFrame
        inspectorContainer.frame = originalInspectorFrame
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(pageView.frame.width, draggedPageWidth, accuracy: 0.5)
        XCTAssertEqual(inspectorContainer.frame.minX, draggedInspectorMinX, accuracy: 0.5)
    }

    func testWindowBrowserSlotPinsHostedWebViewWithAutoresizingForAttachedInspector() {
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        let webView = WKWebView(frame: .zero)
        slot.addSubview(webView)

        slot.pinHostedWebView(webView)
        slot.frame = NSRect(x: 0, y: 0, width: 300, height: 220)
        slot.layoutSubtreeIfNeeded()

        XCTAssertTrue(webView.translatesAutoresizingMaskIntoConstraints)
        XCTAssertEqual(webView.autoresizingMask, [.width, .height])
        XCTAssertEqual(webView.frame, slot.bounds)
    }

    func testWindowBrowserSlotReattachesPlainWebViewAtFullBoundsAfterHiddenHostResize() {
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        let webView = WKWebView(frame: .zero)
        slot.addSubview(webView)
        slot.pinHostedWebView(webView)
        XCTAssertEqual(webView.frame, slot.bounds)

        let externalHost = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        webView.removeFromSuperview()
        externalHost.addSubview(webView)
        webView.frame = externalHost.bounds
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]

        slot.addSubview(webView)
        slot.pinHostedWebView(webView)

        slot.frame = NSRect(x: 0, y: 0, width: 300, height: 180)
        slot.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            webView.frame,
            slot.bounds,
            "Reattaching a plain web view should restore full-bounds hosting instead of preserving a stale inset frame from a hidden host"
        )
    }
}


@MainActor
final class WindowBrowserSlotViewTests: XCTestCase {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private func advanceAnimations() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    func testDropZoneOverlayStaysAboveContentWithoutBlockingHits() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let slot = WindowBrowserSlotView(frame: container.bounds)
        container.addSubview(slot)
        let child = CapturingView(frame: slot.bounds)
        child.autoresizingMask = [.width, .height]
        slot.addSubview(child)

        slot.setDropZoneOverlay(zone: .right)
        container.layoutSubtreeIfNeeded()

        guard let overlay = container.subviews.first(where: {
            $0 !== slot && String(describing: type(of: $0)).contains("BrowserDropZoneOverlayView")
        }) else {
            XCTFail("Expected browser slot drop-zone overlay")
            return
        }

        XCTAssertTrue(container.subviews.last === overlay, "Overlay should stay above the hosted web view")
        XCTAssertFalse(overlay.isHidden)
        XCTAssertEqual(overlay.frame.origin.x, 100, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.origin.y, 4, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.width, 96, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.height, 92, accuracy: 0.5)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 120, y: 50)), "Overlay should never intercept pointer hits")
        XCTAssertTrue(slot.hitTest(NSPoint(x: 120, y: 50)) === child)

        slot.setDropZoneOverlay(zone: nil)
        advanceAnimations()
        XCTAssertTrue(overlay.isHidden, "Clearing the drop zone should hide the overlay")
    }

    func testTopDropZoneOverlayUsesFullBrowserContentHeight() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let slot = WindowBrowserSlotView(frame: container.bounds)
        container.addSubview(slot)

        slot.setPaneTopChromeHeight(20)
        slot.setDropZoneOverlay(zone: .top)
        container.layoutSubtreeIfNeeded()

        guard let overlay = container.subviews.first(where: {
            String(describing: type(of: $0)).contains("BrowserDropZoneOverlayView")
        }) else {
            XCTFail("Expected browser slot drop-zone overlay")
            return
        }

        XCTAssertFalse(overlay.isHidden)
        XCTAssertEqual(overlay.frame.origin.x, 4, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.origin.y, 60, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.width, 192, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.height, 56, accuracy: 0.5)
        XCTAssertGreaterThan(overlay.frame.maxY, slot.frame.maxY)
        XCTAssertEqual(slot.layer?.masksToBounds, true)

        slot.setDropZoneOverlay(zone: nil)
        advanceAnimations()
        XCTAssertEqual(slot.layer?.masksToBounds, true)
    }
}


@MainActor
final class BrowserWindowPortalLifecycleTests: XCTestCase {
    private final class TrackingPortalWebView: WKWebView {
        private(set) var displayIfNeededCount = 0
        private(set) var reattachRenderingStateCount = 0

        override func displayIfNeeded() {
            displayIfNeededCount += 1
            super.displayIfNeeded()
        }

        @objc(_enterInWindow)
        func cmuxUnitTestEnterInWindow() {
            reattachRenderingStateCount += 1
        }

        @objc(_endDeferringViewInWindowChangesSync)
        func cmuxUnitTestEndDeferringViewInWindowChangesSync() {
            reattachRenderingStateCount += 1
        }
    }

    private final class WKInspectorProbeView: NSView {}

    private func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func advanceAnimations() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    private func dropZoneOverlay(in slot: WindowBrowserSlotView, excluding webView: WKWebView) -> NSView? {
        let candidates = slot.subviews + (slot.superview?.subviews ?? [])
        return candidates.first(where: {
            $0 !== slot &&
            $0 !== webView &&
            String(describing: type(of: $0)).contains("BrowserDropZoneOverlayView")
        })
    }

    func testPortalHostInstallsAboveContentViewForVisibility() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let portal = WindowBrowserPortal(window: window)
        _ = portal.webViewAtWindowPoint(NSPoint(x: 1, y: 1))

        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        guard let hostIndex = container.subviews.firstIndex(where: { $0 is WindowBrowserHostView }),
              let contentIndex = container.subviews.firstIndex(where: { $0 === contentView }) else {
            XCTFail("Expected host/content views in same container")
            return
        }

        XCTAssertGreaterThan(
            hostIndex,
            contentIndex,
            "Browser portal host must remain above content view so portal-hosted web views stay visible"
        )
    }

    private func makeBrowserSearchOverlayConfiguration(panelId: UUID) -> BrowserPortalSearchOverlayConfiguration {
        BrowserPortalSearchOverlayConfiguration(
            panelId: panelId,
            searchState: BrowserSearchState(),
            focusRequestGeneration: 0,
            canApplyFocusRequest: { _ in false },
            onNext: {},
            onPrevious: {},
            onClose: {},
            onFieldDidFocus: {}
        )
    }

    // Regression guard for https://github.com/manaflow-ai/cmux/issues/5733.
    // The per-keystroke find-overlay lookup (`searchOverlayPanelId`) used to scan
    // `entriesByWebViewId.values`, copying each `Entry` struct. Every copy
    // performs 3 `objc_copyWeak` ops (weak webView/containerView/anchorView)
    // under the global Obj-C weak-table lock, so the lookup did O(panes)
    // weak-table churn on every key event — the stack-exhaustion fault site in
    // #5733 and a typing-latency contributor (#4405).
    //
    // The fix drives the lookup off the live slot view hierarchy instead. This
    // test pins that structural property: a slot that is present in the portal
    // host's view hierarchy but absent from `entriesByWebViewId` must still be
    // found. The old dictionary scan never visited such a slot (returned nil);
    // the hierarchy scan finds it. Reintroducing the `entriesByWebViewId.values`
    // scan — the weak-copy bug class — would fail this test.
    func testSearchOverlayLookupResolvesOffSlotHierarchyNotEntriesDictionary() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let panelId = UUID()
        slot.setSearchOverlay(makeBrowserSearchOverlayConfiguration(panelId: panelId))
        // Install the slot into the live host hierarchy WITHOUT registering an Entry.
        portal.browserPortalTestInstallSlotWithoutEntry(slot)

        guard let overlayResponder = slot.browserPortalTestSearchOverlayView else {
            XCTFail("Expected the slot to host a search overlay view")
            return
        }

        XCTAssertEqual(
            portal.searchOverlayPanelId(for: overlayResponder),
            panelId,
            "Find-overlay lookup must resolve off the live slot view hierarchy, not the "
                + "entries dictionary, so it materializes zero Entry weak-copies per keystroke (#5733)"
        )
    }

    // Companion to the regression guard above: the normal path where the slot is
    // registered via `bind` must keep resolving its own search overlay after the
    // hierarchy-scan rewrite (#5733).
    func testSearchOverlayLookupResolvesBoundSlotOverlay() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 160, height: 120))
        contentView.addSubview(anchor)
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let panelId = UUID()
        slot.setSearchOverlay(makeBrowserSearchOverlayConfiguration(panelId: panelId))
        guard let overlayResponder = slot.browserPortalTestSearchOverlayView else {
            XCTFail("Expected the slot to host a search overlay view")
            return
        }

        XCTAssertEqual(portal.searchOverlayPanelId(for: overlayResponder), panelId)
        // A responder no slot owns must not match.
        XCTAssertNil(portal.searchOverlayPanelId(for: window))
    }

    // Crash regression for https://github.com/manaflow-ai/cmux/issues/5733.
    //
    // The production crash was a main-thread stack-exhaustion SIGSEGV
    // (KERN_PROTECTION_FAILURE, "Could not determine thread index for stack guard
    // region") whose fault site was the find-overlay lookup copying `Entry`
    // structs out of `entriesByWebViewId.values`. Each Entry copy performs 3
    // `objc_copyWeak` ops, so at the crash-time load of 166 browser panes the
    // lookup did ~498 weak-table-locked operations on EVERY key event and EVERY
    // first-responder change (the reproduced stack showed the scan reached from
    // both `cmux_performKeyEquivalent` and `cmux_makeFirstResponder` ->
    // `BrowserPanel.ownedFocusIntent`). That per-call O(panes) weak-copy churn,
    // stacked on top of the WebKit `doneWithKeyEvent` re-dispatch nesting, is the
    // bug class that exhausted the 8 MB main-thread stack.
    //
    // True 8 MB exhaustion is not cleanly unit-testable (it needs the WebKit IPC
    // re-dispatch chain under load), so this pins the underlying invariant at the
    // crash-time pane count: the lookup must resolve off the live slot view
    // hierarchy, never by enumerating/copying the entries dictionary. The find
    // overlay is opened on the LAST of 166 host slots (worst case for any scan),
    // none of which are registered in `entriesByWebViewId`. The fixed
    // hierarchy-scan finds it (0 Entry copies); the old `entriesByWebViewId.values`
    // scan would enumerate an empty dictionary and return nil.
    func testSearchOverlayLookupRemainsHierarchyDrivenAtCrashPaneCount() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        // 166 = the browser-pane count at the time of the production crash (#5731).
        let paneCount = 166
        var slots: [WindowBrowserSlotView] = []
        for index in 0..<paneCount {
            let slot = WindowBrowserSlotView(
                frame: NSRect(x: 0, y: CGFloat(index), width: 120, height: 1)
            )
            portal.browserPortalTestInstallSlotWithoutEntry(slot)
            slots.append(slot)
        }

        let panelId = UUID()
        guard let targetSlot = slots.last else {
            XCTFail("Expected slots")
            return
        }
        targetSlot.setSearchOverlay(makeBrowserSearchOverlayConfiguration(panelId: panelId))
        guard let overlayResponder = targetSlot.browserPortalTestSearchOverlayView else {
            XCTFail("Expected the slot to host a search overlay view")
            return
        }

        XCTAssertEqual(
            portal.searchOverlayPanelId(for: overlayResponder),
            panelId,
            "At the 166-pane crash profile the find-overlay lookup must resolve off the "
                + "live slot hierarchy with zero Entry weak-copies (#5733)"
        )
        // A responder no slot owns must still return nil after scanning all 166 slots.
        XCTAssertNil(portal.searchOverlayPanelId(for: window))
    }

    func testBrowserPortalHostStaysAboveTerminalPortalHostDuringPortalChurn() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)

        let browserPortal = WindowBrowserPortal(window: window)
        let terminalPortal = WindowTerminalPortal(window: window)
        _ = browserPortal.webViewAtWindowPoint(NSPoint(x: 1, y: 1))
        _ = terminalPortal.viewAtWindowPoint(NSPoint(x: 1, y: 1))

        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        func assertHostOrder(_ message: String) {
            guard let browserHostIndex = container.subviews.firstIndex(where: { $0 is WindowBrowserHostView }),
                  let terminalHostIndex = container.subviews.firstIndex(where: { $0 is WindowTerminalHostView }) else {
                XCTFail("Expected both portal hosts in same container")
                return
            }

            XCTAssertGreaterThan(
                browserHostIndex,
                terminalHostIndex,
                message
            )
        }

        assertHostOrder("Browser portal host should start above terminal portal host")

        let terminalAnchor = NSView(frame: NSRect(x: 20, y: 20, width: 200, height: 140))
        contentView.addSubview(terminalAnchor)
        let terminalHostedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        terminalPortal.bind(hostedView: terminalHostedView, to: terminalAnchor, visibleInUI: true)
        terminalPortal.synchronizeHostedViewForAnchor(terminalAnchor)
        assertHostOrder("Terminal portal sync should not rise above the browser portal host")

        let browserAnchor = NSView(frame: NSRect(x: 240, y: 20, width: 220, height: 140))
        contentView.addSubview(browserAnchor)
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        browserPortal.bind(webView: webView, to: browserAnchor, visibleInUI: true)
        browserPortal.synchronizeWebViewForAnchor(browserAnchor)
        assertHostOrder("Browser portal sync should keep browser panes above portal-hosted terminals")
    }

    func testAnchorRebindKeepsWebViewInStablePortalSuperview() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor1 = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        let anchor2 = NSView(frame: NSRect(x: 240, y: 40, width: 180, height: 120))
        contentView.addSubview(anchor1)
        contentView.addSubview(anchor2)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor1, visibleInUI: true)
        let firstSuperview = webView.superview

        XCTAssertNotNil(firstSuperview)
        XCTAssertTrue(firstSuperview is WindowBrowserSlotView)

        portal.bind(webView: webView, to: anchor2, visibleInUI: true)
        XCTAssertTrue(webView.superview === firstSuperview, "Anchor moves should not reparent the web view")

        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor2)
        guard let slot = webView.superview as? WindowBrowserSlotView,
              let host = slot.superview as? WindowBrowserHostView else {
            XCTFail("Expected browser slot + host views")
            return
        }
        let expectedFrame = host.convert(anchor2.bounds, from: anchor2)
        XCTAssertEqual(slot.frame.origin.x, expectedFrame.origin.x, accuracy: 0.5)
        XCTAssertEqual(slot.frame.origin.y, expectedFrame.origin.y, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.width, expectedFrame.size.width, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.height, expectedFrame.size.height, accuracy: 0.5)
    }

    func testPortalClampsWebViewFrameToHostBoundsWhenAnchorOverflowsSidebar() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        // Simulate a transient oversized anchor rect during split churn.
        let anchor = NSView(frame: NSRect(x: 120, y: 20, width: 260, height: 150))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected web view slot")
            return
        }

        XCTAssertFalse(slot.isHidden, "Partially visible browser anchor should stay visible")
        XCTAssertEqual(slot.frame.origin.x, 120, accuracy: 0.5)
        XCTAssertEqual(slot.frame.origin.y, 20, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.width, 200, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.height, 150, accuracy: 0.5)
    }

    func testPortalClipsAnchorFrameThroughAncestorBounds() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let clipView = NSView(frame: NSRect(x: 60, y: 40, width: 150, height: 120))
        contentView.addSubview(clipView)

        // Simulate SwiftUI/AppKit reporting an anchor wider than the actual visible pane.
        let anchor = NSView(frame: NSRect(x: -30, y: 0, width: 220, height: 120))
        clipView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        clipView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        XCTAssertFalse(slot.isHidden, "Ancestor clipping should keep the browser visible in the real pane")
        XCTAssertEqual(slot.frame.origin.x, 60, accuracy: 0.5)
        XCTAssertEqual(slot.frame.origin.y, 40, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.width, 150, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.height, 120, accuracy: 0.5)
    }

    func testPortalSyncNormalizesOutOfBoundsWebFrame() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 20, width: 220, height: 160))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        // Reproduce observed drift from logs where WebKit shifts/expands frame beyond slot bounds.
        webView.frame = NSRect(x: 0, y: 250, width: slot.bounds.width, height: slot.bounds.height)
        XCTAssertGreaterThan(webView.frame.maxY, slot.bounds.maxY)

        portal.synchronizeWebViewForAnchor(anchor)
        XCTAssertEqual(webView.frame.origin.x, slot.bounds.origin.x, accuracy: 0.5)
        XCTAssertEqual(webView.frame.origin.y, slot.bounds.origin.y, accuracy: 0.5)
        XCTAssertEqual(webView.frame.size.width, slot.bounds.size.width, accuracy: 0.5)
        XCTAssertEqual(webView.frame.size.height, slot.bounds.size.height, accuracy: 0.5)
    }

    func testPortalSlotPinPreservesSideDockedInspectorManagedWebViewFrameOnRehost() {
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        let webView = CmuxWebView(frame: NSRect(x: 0, y: 0, width: 132, height: 160), configuration: WKWebViewConfiguration())
        let inspectorContainer = NSView(frame: NSRect(x: 132, y: 0, width: 108, height: 160))
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        slot.addSubview(webView)
        slot.addSubview(inspectorContainer)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.autoresizingMask = []
        slot.pinHostedWebView(webView)

        XCTAssertEqual(
            webView.frame.maxX,
            inspectorContainer.frame.minX,
            accuracy: 0.5,
            "Rehosting a portal-managed browser should preserve the WebKit-owned side inspector split"
        )
        XCTAssertLessThan(
            webView.frame.width,
            slot.bounds.width,
            "The page frame should stay narrower than the full slot while a side-docked inspector is present"
        )
    }

    func testPortalResizePreservesSideDockedInspectorManagedWebViewFrame() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 260, height: 180))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let initialInspectorWidth: CGFloat = 110
        let inspectorContainer = NSView(
            frame: NSRect(
                x: slot.bounds.width - initialInspectorWidth,
                y: 0,
                width: initialInspectorWidth,
                height: slot.bounds.height
            )
        )
        inspectorContainer.autoresizingMask = [.minXMargin, .height]
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        slot.addSubview(inspectorContainer)

        webView.frame = NSRect(
            x: 0,
            y: 0,
            width: slot.bounds.width - initialInspectorWidth,
            height: slot.bounds.height
        )
        webView.autoresizingMask = [.width, .height]
        slot.layoutSubtreeIfNeeded()

        anchor.frame = NSRect(x: 40, y: 24, width: 220, height: 180)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        XCTAssertFalse(slot.isHidden, "Resizing the browser pane should keep the hosted browser visible")
        XCTAssertEqual(
            webView.frame.maxX,
            inspectorContainer.frame.minX,
            accuracy: 0.5,
            "Portal sync should preserve the side-docked inspector split instead of stretching the page back over the inspector"
        )
        XCTAssertLessThan(
            webView.frame.width,
            slot.bounds.width,
            "Side-docked inspector should still own part of the slot after pane resize"
        )
    }

    func testPortalAnchorResizeDoesNotForceHostedWebViewPresentationRefresh() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 220, height: 160))
        contentView.addSubview(anchor)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let initialDisplayCount = webView.displayIfNeededCount
        let initialReattachCount = webView.reattachRenderingStateCount
        anchor.frame = NSRect(x: 52, y: 30, width: 248, height: 178)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        XCTAssertFalse(slot.isHidden, "Anchor resize should keep the portal-hosted browser visible")
        XCTAssertEqual(slot.frame.origin.x, 52, accuracy: 0.5)
        XCTAssertEqual(slot.frame.origin.y, 30, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.width, 248, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.height, 178, accuracy: 0.5)
        XCTAssertGreaterThan(
            webView.displayIfNeededCount,
            initialDisplayCount,
            "Pure anchor geometry updates should still repaint the hosted browser"
        )
        XCTAssertEqual(
            webView.reattachRenderingStateCount,
            initialReattachCount,
            "Pure anchor geometry updates should not trigger the WebKit reattach path"
        )
    }

    func testExternalSplitResizeDoesNotForceHostedWebViewPresentationRefresh() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let splitView = NSSplitView(frame: contentView.bounds)
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true

        let leadingPane = NSView(
            frame: NSRect(x: 0, y: 0, width: 220, height: contentView.bounds.height)
        )
        leadingPane.autoresizingMask = [.height]
        let trailingPane = NSView(
            frame: NSRect(
                x: 221,
                y: 0,
                width: contentView.bounds.width - 221,
                height: contentView.bounds.height
            )
        )
        trailingPane.autoresizingMask = [.width, .height]
        splitView.addSubview(leadingPane)
        splitView.addSubview(trailingPane)
        contentView.addSubview(splitView)
        splitView.adjustSubviews()

        let anchor = NSView(frame: trailingPane.bounds.insetBy(dx: 12, dy: 12))
        anchor.autoresizingMask = [.width, .height]
        trailingPane.addSubview(anchor)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let initialDisplayCount = webView.displayIfNeededCount
        let initialReattachCount = webView.reattachRenderingStateCount
        let initialWidth = slot.frame.width

        splitView.setPosition(280, ofDividerAt: 0)
        contentView.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: NSSplitView.didResizeSubviewsNotification, object: splitView)
        advanceAnimations()

        XCTAssertFalse(slot.isHidden, "App split resize should keep the browser slot visible")
        XCTAssertLessThan(
            slot.frame.width,
            initialWidth,
            "Moving the app split divider should shrink the hosted browser slot"
        )
        XCTAssertGreaterThan(
            webView.displayIfNeededCount,
            initialDisplayCount,
            "External split resize should still repaint the hosted browser"
        )
        XCTAssertEqual(
            webView.reattachRenderingStateCount,
            initialReattachCount,
            "External split resize should not trigger the WebKit reattach path"
        )
    }

    func testPortalSyncRepairsBottomDockedInspectorOverflowedPageFrame() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 260, height: 180))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let inspectorHeight: CGFloat = 84
        let inspectorContainer = NSView(
            frame: NSRect(x: 0, y: 0, width: slot.bounds.width, height: inspectorHeight)
        )
        inspectorContainer.autoresizingMask = [.width]
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        slot.addSubview(inspectorContainer)

        webView.frame = NSRect(
            x: 0,
            y: inspectorHeight,
            width: slot.bounds.width,
            height: slot.bounds.height
        )
        webView.autoresizingMask = [.width, .height]
        slot.layoutSubtreeIfNeeded()

        portal.synchronizeWebViewForAnchor(anchor)

        XCTAssertFalse(slot.isHidden, "Portal sync should keep the hosted browser visible")
        XCTAssertEqual(
            webView.frame.minY,
            inspectorHeight,
            accuracy: 0.5,
            "Portal sync should keep the page viewport below a bottom-docked inspector instead of shifting the page upward"
        )
        XCTAssertEqual(
            webView.frame.height,
            slot.bounds.height - inspectorHeight,
            accuracy: 0.5,
            "Portal sync should shrink the page viewport to the space above a bottom-docked inspector"
        )
        XCTAssertEqual(
            webView.frame.maxY,
            slot.bounds.maxY,
            accuracy: 0.5,
            "The repaired page viewport should stay flush with the top edge of the slot"
        )
    }

    func testHidingBrowserSlotYieldsOwnedInspectorFirstResponder() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let slot = WindowBrowserSlotView(frame: NSRect(x: 40, y: 24, width: 260, height: 180))
        contentView.addSubview(slot)

        let inspectorContainer = NSView(frame: slot.bounds)
        inspectorContainer.autoresizingMask = [.width, .height]
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        slot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            window.makeFirstResponder(inspectorView),
            "Precondition failed: inspector probe should become first responder"
        )
        XCTAssertTrue(window.firstResponder === inspectorView)

        slot.isHidden = true

        XCTAssertFalse(
            window.firstResponder === inspectorView,
            "Hiding a browser slot should yield any owned inspector responder before it goes off-screen"
        )
        if let firstResponderView = window.firstResponder as? NSView {
            XCTAssertFalse(
                firstResponderView === slot || firstResponderView.isDescendant(of: slot),
                "Hiding a browser slot should not leave first responder inside the hidden slot"
            )
        }
    }

    func testHiddenPortalSyncDoesNotStealLocallyHostedDevToolsWebViewDuringResize() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 260, height: 180))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        guard let hiddenPortalSlot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: false, zPriority: 0)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()
        XCTAssertTrue(hiddenPortalSlot.isHidden, "Hidden portal entry should keep its slot hidden")

        let localInlineSlot = WindowBrowserSlotView(frame: anchor.frame)
        contentView.addSubview(localInlineSlot)

        let inspectorView = WKInspectorProbeView(
            frame: NSRect(x: 0, y: 0, width: localInlineSlot.bounds.width, height: 72)
        )
        inspectorView.autoresizingMask = [.width]
        localInlineSlot.addSubview(inspectorView)

        localInlineSlot.addSubview(webView)
        webView.frame = NSRect(
            x: 0,
            y: inspectorView.frame.maxY,
            width: localInlineSlot.bounds.width,
            height: localInlineSlot.bounds.height - inspectorView.frame.height
        )
        localInlineSlot.layoutSubtreeIfNeeded()

        anchor.frame = NSRect(x: 40, y: 24, width: 220, height: 180)
        localInlineSlot.frame = anchor.frame
        contentView.layoutSubtreeIfNeeded()
        localInlineSlot.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        XCTAssertTrue(
            webView.superview === localInlineSlot,
            "Hidden portal sync should not steal a DevTools-hosted web view back out of local inline hosting during pane resize"
        )
        XCTAssertTrue(
            inspectorView.superview === localInlineSlot,
            "Hidden portal sync should leave local DevTools companion views in the local inline host"
        )
        XCTAssertTrue(hiddenPortalSlot.isHidden, "The retiring hidden portal slot should stay hidden during local inline hosting")
    }

    func testPortalHostBoundsBecomeReadyAfterBindingInFrameDrivenHierarchy() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 220, height: 160))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView,
              let host = slot.superview as? WindowBrowserHostView else {
            XCTFail("Expected portal slot + host views")
            return
        }
        XCTAssertGreaterThan(host.bounds.width, 1, "Portal host width should be ready for clipping/sync")
        XCTAssertGreaterThan(host.bounds.height, 1, "Portal host height should be ready for clipping/sync")
    }

    func testPortalDropZoneOverlayPersistsAcrossVisibilityChanges() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 220, height: 160))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView,
              let overlay = dropZoneOverlay(in: slot, excluding: webView) else {
            XCTFail("Expected browser slot overlay")
            return
        }

        XCTAssertTrue(overlay.isHidden, "Overlay should start hidden without an active drop zone")

        portal.updateDropZoneOverlay(forWebViewId: ObjectIdentifier(webView), zone: .right)
        slot.layoutSubtreeIfNeeded()
        XCTAssertFalse(overlay.isHidden)
        XCTAssertTrue(slot.superview?.subviews.last === overlay, "Overlay should remain above the hosted web view")
        XCTAssertEqual(overlay.frame.origin.x, slot.frame.origin.x + 110, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.origin.y, slot.frame.origin.y + 4, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.width, 106, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.height, 152, accuracy: 0.5)

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: false, zPriority: 0)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()
        XCTAssertTrue(overlay.isHidden, "Invisible browser entries should hide the overlay")

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: true, zPriority: 0)
        portal.synchronizeWebViewForAnchor(anchor)
        XCTAssertFalse(overlay.isHidden, "Restoring visibility should restore the active drop-zone overlay")
    }

    func testPortalRevealRefreshesHostedWebViewWithoutFrameDelta() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 220, height: 160))
        contentView.addSubview(anchor)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()
        let initialDisplayCount = webView.displayIfNeededCount
        let initialReattachCount = webView.reattachRenderingStateCount

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: false, zPriority: 0)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()
        let hiddenDisplayCount = webView.displayIfNeededCount
        let hiddenReattachCount = webView.reattachRenderingStateCount

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: true, zPriority: 0)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        XCTAssertGreaterThanOrEqual(hiddenDisplayCount, initialDisplayCount)
        XCTAssertEqual(
            hiddenReattachCount,
            initialReattachCount,
            "Hiding a portal-hosted browser should not itself trigger the WebKit reattach path"
        )
        XCTAssertGreaterThan(
            webView.displayIfNeededCount,
            hiddenDisplayCount,
            "Revealing an existing portal-hosted browser should refresh WebKit presentation immediately"
        )
        XCTAssertGreaterThan(
            webView.reattachRenderingStateCount,
            hiddenReattachCount,
            "Revealing an existing portal-hosted browser should trigger the WebKit reattach path"
        )
    }

    func testVisiblePortalEntryHidesWithoutDetachingDuringTransientAnchorRemovalUntilRebind() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchorFrame = NSRect(x: 40, y: 24, width: 220, height: 160)
        let anchor1 = NSView(frame: anchorFrame)
        contentView.addSubview(anchor1)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor1, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor1)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        anchor1.removeFromSuperview()
        portal.synchronizeWebViewForAnchor(anchor1)
        advanceAnimations()

        XCTAssertTrue(webView.superview === slot, "Visible browser entries should not detach during transient anchor removal")
        XCTAssertTrue(
            slot.isHidden,
            "Transient anchor churn should hide the stale browser slot instead of rendering in the wrong pane"
        )
        XCTAssertEqual(portal.debugEntryCount(), 1)

        let displayCountBeforeRebind = webView.displayIfNeededCount
        let anchor2 = NSView(frame: anchorFrame)
        contentView.addSubview(anchor2)
        portal.bind(webView: webView, to: anchor2, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor2)
        advanceAnimations()

        XCTAssertTrue(webView.superview === slot, "Rebinding after transient anchor removal should reuse the existing portal slot")
        XCTAssertFalse(slot.isHidden)
        XCTAssertEqual(portal.debugEntryCount(), 1)
        XCTAssertGreaterThan(
            webView.displayIfNeededCount,
            displayCountBeforeRebind,
            "Anchor rebinds should refresh hosted browser presentation even when geometry is unchanged"
        )
    }

    func testVisiblePortalEntryStaysVisibleDuringOffWindowAnchorReparentUntilRebind() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchorFrame = NSRect(x: 40, y: 24, width: 220, height: 160)
        let anchor = NSView(frame: anchorFrame)
        contentView.addSubview(anchor)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let offWindowContainer = NSView(frame: anchorFrame)
        anchor.removeFromSuperview()
        offWindowContainer.addSubview(anchor)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        XCTAssertTrue(
            webView.superview === slot,
            "Off-window anchor reparent should preserve the hosted browser slot during drag churn"
        )
        XCTAssertFalse(
            slot.isHidden,
            "Off-window anchor reparent should keep the visible browser portal alive until the anchor returns"
        )
        XCTAssertEqual(portal.debugEntryCount(), 1)

        contentView.addSubview(anchor)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        XCTAssertTrue(webView.superview === slot, "Rebinding after off-window reparent should reuse the existing portal slot")
        XCTAssertFalse(slot.isHidden)
        XCTAssertEqual(portal.debugEntryCount(), 1)
    }

    func testRegistryDetachRemovesPortalHostedWebView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        contentView.addSubview(anchor)
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())

        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        XCTAssertNotNil(webView.superview)

        BrowserWindowPortalRegistry.detach(webView: webView)
        XCTAssertNil(webView.superview)
    }

    func testRegistryHideKeepsPortalHostedWebViewAttachedButHidden() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        contentView.addSubview(anchor)
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())

        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }
        XCTAssertFalse(slot.isHidden)

        BrowserWindowPortalRegistry.hide(webView: webView, source: "unitTest")
        advanceAnimations()

        XCTAssertTrue(webView.superview === slot, "Hiding should preserve the hosted WKWebView attachment")
        XCTAssertTrue(slot.isHidden, "Hiding should immediately hide the existing portal slot")
    }

    func testHiddenPortalEntrySurvivesAnchorRemovalUntilWorkspaceRebind() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchorFrame = NSRect(x: 40, y: 24, width: 220, height: 160)
        let oldAnchor = NSView(frame: anchorFrame)
        contentView.addSubview(oldAnchor)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: oldAnchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(oldAnchor)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: false, zPriority: 0)
        portal.synchronizeWebViewForAnchor(oldAnchor)
        advanceAnimations()
        XCTAssertTrue(slot.isHidden, "Workspace handoff should hide the retiring browser before unmount")

        oldAnchor.removeFromSuperview()
        portal.synchronizeWebViewForAnchor(oldAnchor)
        advanceAnimations()

        XCTAssertTrue(
            webView.superview === slot,
            "Hidden workspace browsers should stay attached while their SwiftUI anchor is temporarily unmounted"
        )
        XCTAssertTrue(slot.isHidden, "Unmounted hidden workspace browser should remain hidden until rebound")
        XCTAssertEqual(portal.debugEntryCount(), 1, "Workspace handoff should keep the hidden browser portal entry alive")

        let displayCountBeforeRebind = webView.displayIfNeededCount
        let newAnchor = NSView(frame: anchorFrame)
        contentView.addSubview(newAnchor)
        portal.bind(webView: webView, to: newAnchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(newAnchor)
        advanceAnimations()

        XCTAssertTrue(
            webView.superview === slot,
            "Selecting the workspace again should reuse the existing hidden browser portal slot"
        )
        XCTAssertFalse(slot.isHidden, "Rebinding the workspace browser should reveal the existing portal slot")
        XCTAssertEqual(portal.debugEntryCount(), 1)
        XCTAssertGreaterThan(
            webView.displayIfNeededCount,
            displayCountBeforeRebind,
            "Workspace rebind should refresh the preserved browser without recreating its portal slot"
        )
    }
}

@MainActor
final class OmnibarNativeTextFieldCaretTests: XCTestCase {
    /// A window that hands the omnibar field a real, controllable field editor so
    /// the click path can be exercised headlessly in CI (mirrors the probe pattern
    /// used by the omnibar key-routing tests in `BrowserConfigTests`).
    private final class CaretProbeWindow: NSWindow {
        let probeFieldEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 24))

        override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
            probeFieldEditor
        }
    }

    private func makeMouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        window: NSWindow,
        clickCount: Int = 1,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) mouse event")
        }
        return event
    }

    private func makeCoordinator(
        panelId: UUID = UUID(),
        isFocused: Bool = true
    ) -> OmnibarTextFieldRepresentable.Coordinator {
        var text = ""
        var focused = isFocused
        return OmnibarTextFieldRepresentable.Coordinator(
            parent: OmnibarTextFieldRepresentable(
                panelId: panelId,
                fontSize: 12,
                text: Binding(
                    get: { text },
                    set: { text = $0 }
                ),
                isFocused: Binding(
                    get: { focused },
                    set: { focused = $0 }
                ),
                selectAllRequestId: 0,
                inlineCompletion: nil,
                placeholder: "",
                onTap: {},
                onSubmit: { _ in },
                onEscape: {},
                onFieldLostFocus: {},
                onMoveSelection: { _ in },
                onDeleteSelectedSuggestion: {},
                onAcceptInlineCompletion: {},
                onDeleteBackwardWithInlineSelection: {},
                onClearTypedPrefixWithInlineSelection: {},
                onDeleteWordBackwardWithInlineSelection: {},
                onSelectionChanged: { _, _ in },
                shouldSuppressWebViewFocus: { false }
            )
        )
    }

    private func makeCaretProbeWindow() -> CaretProbeWindow {
        let window = CaretProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        return window
    }

    private func installOmnibarField(
        in window: NSWindow,
        stringValue: String = "https://github.com/manaflow-ai/cmux"
    ) -> OmnibarNativeTextField {
        let field = OmnibarNativeTextField(frame: NSRect(x: 12, y: 80, width: 360, height: 24))
        field.font = .systemFont(ofSize: 12)
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.stringValue = stringValue
        window.contentView?.addSubview(field)
        return field
    }

    private func cleanup(window: NSWindow, field: OmnibarNativeTextField) {
        field.removeFromSuperview()
        window.contentView = nil
        window.orderOut(nil)
    }

    private func singleClick(field: OmnibarNativeTextField, in window: NSWindow) {
        let clickPoint = NSPoint(x: field.frame.midX, y: field.frame.midY)
        let pointInWindow = window.contentView?.convert(clickPoint, to: nil) ?? clickPoint
        field.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: pointInWindow, window: window))
        field.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: pointInWindow, window: window))
    }

    /// Regression for https://github.com/manaflow-ai/cmux/issues/5268: a single,
    /// unmodified click that focuses the omnibar must leave a caret (zero-length
    /// selection) at the click position, not select the entire URL.
    func testSingleClickFocusPlacesCaretInsteadOfSelectingAll() {
        let window = makeCaretProbeWindow()
        let field = installOmnibarField(in: window)
        window.makeKeyAndOrderFront(nil)
        defer {
            cleanup(window: window, field: field)
        }

        // Do NOT pre-focus: the bug only manifests on the click that first acquires
        // focus, where the old code forced a select-all on mouseUp.
        singleClick(field: field, in: window)

        guard let editor = field.currentEditor() as? NSTextView else {
            XCTFail("Expected a field editor after the click acquired focus")
            return
        }
        let textLength = (editor.string as NSString).length
        XCTAssertGreaterThan(textLength, 0, "Test precondition: the omnibar should contain a URL")
        XCTAssertEqual(
            editor.selectedRange().length,
            0,
            "A single click must place a caret, not select the whole URL"
        )
    }

    /// The native single-click path can place a caret correctly and still be
    /// clobbered later by the SwiftUI focus-gained effect. This exercises that
    /// full behavior path instead of only checking the field's mouse handlers.
    func testSwiftUIFocusGainedEffectDoesNotClobberSingleClickCaret() {
        let window = makeCaretProbeWindow()
        let field = installOmnibarField(in: window)
        window.makeKeyAndOrderFront(nil)
        defer {
            cleanup(window: window, field: field)
        }

        singleClick(field: field, in: window)

        guard let editor = field.currentEditor() as? NSTextView else {
            XCTFail("Expected a field editor after the click acquired focus")
            return
        }
        XCTAssertEqual(editor.selectedRange().length, 0, "Test precondition: native click should place a caret")

        var state = OmnibarState()
        let effects = omnibarReduce(
            state: &state,
            event: .focusGained(currentURLString: field.stringValue)
        )
        let coordinator = makeCoordinator()
        coordinator.parentField = field
        if effects.shouldSelectAll {
            coordinator.queueSelectAllRequest(1)
            _ = coordinator.applyPendingSelectAllIfPossible(field: field)
        }

        XCTAssertEqual(
            editor.selectedRange().length,
            0,
            "Focus-gained handling must preserve the caret placed by the focusing click"
        )
    }

    /// Pane focus reconciliation can reassert omnibar focus after the click has
    /// already placed the caret. That restore path must not treat the click as
    /// Cmd+L and select the full URL.
    func testFocusRestoreReassertionDoesNotClobberSingleClickCaret() {
        let window = makeCaretProbeWindow()
        let field = installOmnibarField(in: window)
        window.makeKeyAndOrderFront(nil)
        defer {
            cleanup(window: window, field: field)
        }

        singleClick(field: field, in: window)

        guard let editor = field.currentEditor() as? NSTextView else {
            XCTFail("Expected a field editor after the click acquired focus")
            return
        }
        XCTAssertEqual(editor.selectedRange().length, 0, "Test precondition: native click should place a caret")

        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: field.stringValue))
        let effects = omnibarReduce(
            state: &state,
            event: .focusReasserted(
                shouldSelectAll: browserOmnibarShouldSelectAllOnFocusReassertion(
                    selectionIntent: .preserveFieldEditorSelection
                )
            )
        )

        let coordinator = makeCoordinator()
        coordinator.parentField = field
        if effects.shouldSelectAll {
            coordinator.queueSelectAllRequest(1)
            _ = coordinator.applyPendingSelectAllIfPossible(field: field)
        }

        XCTAssertEqual(
            editor.selectedRange().length,
            0,
            "Focus-restore reassertion must preserve the caret placed by the focusing click"
        )
    }

    func testExplicitSelectAllRequestStillSelectsWholeURL() {
        let window = makeCaretProbeWindow()
        let field = installOmnibarField(in: window)
        window.makeKeyAndOrderFront(nil)
        defer {
            cleanup(window: window, field: field)
        }

        XCTAssertTrue(window.makeFirstResponder(field))
        guard let editor = field.currentEditor() as? NSTextView else {
            XCTFail("Expected a field editor after focusing text field")
            return
        }
        let textLength = (editor.string as NSString).length
        editor.setSelectedRange(NSRange(location: textLength, length: 0))

        let coordinator = makeCoordinator()
        coordinator.parentField = field
        coordinator.queueSelectAllRequest(1)

        XCTAssertTrue(coordinator.applyPendingSelectAllIfPossible(field: field))
        XCTAssertEqual(
            editor.selectedRange(),
            NSRange(location: 0, length: textLength),
            "Explicit omnibar focus requests such as Cmd+L must still select the whole URL"
        )
    }
}
