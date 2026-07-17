import AppKit
import CmuxSettings
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct ViewerNavigationTests {
    @Test
    func nativeViewerRouterAppliesClausesAndPreservesChords() {
        let router = ViewerNavigationKeyRouter(actions: [
            .diffViewerScrollDown,
            .diffViewerScrollToTop,
        ])
        var performed: [KeyboardShortcutSettings.Action] = []
        let denied = router.handle(Self.keyEvent("j"), isAllowed: { _, _ in false }, perform: { performed.append($0) })
        #expect(!denied)
        #expect(performed.isEmpty)

        #expect(router.handle(Self.keyEvent("g", timestamp: 10), isAllowed: { _, _ in true }, perform: { performed.append($0) }))
        #expect(router.handle(Self.keyEvent("g", timestamp: 10.1), isAllowed: { _, _ in true }, perform: { performed.append($0) }))
        #expect(performed == [.diffViewerScrollToTop])
    }

    @Test
    func diffViewerNavigationStateRestoresOnlyAfterCancelledNavigation() {
        let state = DiffViewerNavigationDocumentState()
        let firstNavigationObject = NSObject()
        let secondNavigationObject = NSObject()
        let firstNavigation = ObjectIdentifier(firstNavigationObject)
        let secondNavigation = ObjectIdentifier(secondNavigationObject)
        state.update(viewer: true, editable: false, rendererReady: true)
        #expect(state.canHandleNavigation)

        state.navigationDidStart(id: firstNavigation)
        #expect(!state.canHandleNavigation)
        state.navigationDidCancel(id: firstNavigation)
        #expect(state.canHandleNavigation)

        state.navigationDidStart(id: firstNavigation)
        state.navigationDidStart(id: secondNavigation)
        state.navigationDidCancel(id: firstNavigation)
        #expect(!state.canHandleNavigation)
        state.navigationDidCancel(id: secondNavigation)
        #expect(state.canHandleNavigation)

        state.navigationDidStart(id: firstNavigation)
        state.navigationDidCommit(id: firstNavigation)
        state.navigationDidCancel(id: firstNavigation)
        #expect(!state.canHandleNavigation)
    }

    @Test
    func tokenShapedURLWithoutActiveSessionIsNotTrusted() throws {
        let inactiveToken = UUID().uuidString.lowercased()
        let url = try #require(URL(
            string: "http://127.0.0.1:5050/\(inactiveToken)/diff.html#cmux-diff-viewer"
        ))

        #expect(DiffCommentsBridge.diffViewerToken(from: url) != nil)
        #expect(!DiffCommentsBridge.isTrustedDiffViewerURL(url))
    }

    @Test
    func registeredLiveHTTPViewerIsTrustedOnlyOnItsOrigin() throws {
        let liveToken = UUID().uuidString.lowercased()
        let original = try #require(URL(
            string: "http://127.0.0.1:5050/\(liveToken)/diff.html#cmux-diff-viewer"
        ))
        let rewritten = try #require(URL(
            string: "http://127.0.0.1:5050/\(liveToken)/diff.html#/cmux-diff-viewer"
        ))
        let wrongPort = try #require(URL(
            string: "http://127.0.0.1:5051/\(liveToken)/diff.html#/cmux-diff-viewer"
        ))

        #expect(DiffViewerSessionTrustRegistry.shared.registerLiveHTTPURL(original, token: liveToken))
        #expect(DiffCommentsBridge.isTrustedDiffViewerURL(rewritten))
        #expect(!DiffCommentsBridge.isTrustedDiffViewerURL(wrongPort))
    }

    @Test
    func sidecarBridgeRequiresRegisteredCustomSchemeViewerURL() throws {
        let token = UUID().uuidString.lowercased()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidecar-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let html = root.appendingPathComponent("index.html", isDirectory: false)
        try "<html></html>".write(to: html, atomically: true, encoding: .utf8)
        try CmuxDiffViewerURLSchemeHandler.shared.register(
            token: token,
            files: [.init(requestPath: "/index.html", fileURL: html, mimeType: "text/html")]
        )

        let customSchemeURL = try #require(URL(string: "cmux-diff-viewer://\(token)/index.html"))
        let loopbackLookalikeURL = try #require(URL(string: "http://127.0.0.1:5050/\(token)/index.html"))
        #expect(DiffSidecarBridge.isTrustedSidecarURL(customSchemeURL))
        #expect(!DiffSidecarBridge.isTrustedSidecarURL(loopbackLookalikeURL))
    }

    @Test
    func sidecarProcessPoolCancelsQueuedWorkWithoutLeakingPermit() async throws {
        let pool = DiffSidecarProcessPool(limit: 1)
        let counter = SidecarPoolTestCounter()
        let firstStarted = AsyncStream<Void>.makeStream()
        let releaseFirst = AsyncStream<Void>.makeStream()
        var firstStartedIterator = firstStarted.stream.makeAsyncIterator()

        let first = Task {
            try await pool.withPermit {
                await counter.increment()
                firstStarted.continuation.yield()
                for await _ in releaseFirst.stream {
                    return
                }
            }
        }
        _ = await firstStartedIterator.next()

        let cancelled = Task {
            try await pool.withPermit {
                await counter.increment()
            }
        }
        cancelled.cancel()
        releaseFirst.continuation.yield()
        releaseFirst.continuation.finish()
        try await first.value
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        #expect(await counter.value == 1)

        try await pool.withPermit {
            await counter.increment()
        }
        #expect(await counter.value == 2)
    }

    @Test
    func registeredLiveHTTPViewerTrustRenewsWhileSessionRemainsActive() throws {
        let liveToken = UUID().uuidString.lowercased()
        let url = try #require(URL(
            string: "http://127.0.0.1:5050/\(liveToken)/diff.html#cmux-diff-viewer"
        ))
        let registeredAt = Date(timeIntervalSince1970: 1_000)

        #expect(DiffViewerSessionTrustRegistry.shared.registerLiveHTTPURL(
            url,
            token: liveToken,
            now: registeredAt
        ))
        #expect(DiffViewerSessionTrustRegistry.shared.isTrustedDiffViewerURL(
            url,
            now: registeredAt.addingTimeInterval(23 * 60 * 60)
        ))
        #expect(DiffViewerSessionTrustRegistry.shared.isTrustedDiffViewerURL(
            url,
            now: registeredAt.addingTimeInterval(46 * 60 * 60)
        ))
    }

    @Test
    func viewerEmacsBindingsDoNotConflictWithCommandPaletteNavigation() {
        let next = KeyboardShortcutSettings.Action.commandPaletteNext.defaultShortcut
        let previous = KeyboardShortcutSettings.Action.commandPalettePrevious.defaultShortcut

        #expect(KeyboardShortcutSettings.Action.commandPaletteNext.shortcutContext == .commandPaletteVisible)
        #expect(KeyboardShortcutSettings.Action.commandPalettePrevious.shortcutContext == .commandPaletteVisible)
        #expect(!KeyboardShortcutSettings.Action.diffViewerScrollDownEmacs.conflicts(
            with: next,
            proposedAction: .commandPaletteNext,
            configuredShortcut: KeyboardShortcutSettings.Action.diffViewerScrollDownEmacs.defaultShortcut
        ))
        #expect(!KeyboardShortcutSettings.Action.diffViewerScrollUpEmacs.conflicts(
            with: previous,
            proposedAction: .commandPalettePrevious,
            configuredShortcut: KeyboardShortcutSettings.Action.diffViewerScrollUpEmacs.defaultShortcut
        ))
    }

    @Test
    func commandPaletteNavigationHonorsConfiguredWhenClause() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let originalStore = KeyboardShortcutSettings.settingsFileStore
        let originalCache = appDelegate.shortcutEventFocusContextCache
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-palette-navigation-\(UUID().uuidString).json")
        try """
        {
          "shortcuts": {
            "when": {
              "commandPaletteNext": "commandPaletteVisible && paneCount > 1"
            }
          }
        }
        """.write(to: settingsURL, atomically: true, encoding: .utf8)
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        defer {
            appDelegate.shortcutEventFocusContextCache = originalCache
            KeyboardShortcutSettings.settingsFileStore = originalStore
            try? FileManager.default.removeItem(at: settingsURL)
        }

        let event = Self.keyEvent("n", modifiers: .control)
        var shortcutContext = ShortcutContext()
        shortcutContext.setBool("commandPaletteVisible", true)
        shortcutContext.setInt("paneCount", 1)
        appDelegate.shortcutEventFocusContextCache = ShortcutEventFocusContextCache(
            event: event,
            context: ShortcutEventFocusContext(
                browserPanel: nil,
                markdownPanel: nil,
                filePreviewTextEditorFocused: false,
                rightSidebarFocused: false,
                shortcutContext: shortcutContext
            )
        )

        #expect(contextAwareCommandPaletteSelectionDelta(for: event) == nil)
    }

    @Test
    func markdownViewerUsesSmoothVimAndEmacsNavigation() async throws {
        let appDelegate = try #require(AppDelegate.shared)
        let frame = NSRect(x: 0, y: 0, width: 720, height: 360)
        let webView = MarkdownWebView(frame: frame, configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            window.close()
        }

        let loadDelegate = ViewerNavigationShellLoadDelegate()
        webView.navigationDelegate = loadDelegate
        try await loadDelegate.load(
            MarkdownViewerAssets.shared.shellHTML(isDark: true),
            in: webView,
            baseURL: FileManager.default.temporaryDirectory.appendingPathComponent("navigation.md")
        )
        try await renderMarkdown(scrollSmokeMarkdown(), in: webView)

        try await webView.evaluateJavaScript(
            """
            (function() {
              var scroller = document.scrollingElement || document.documentElement;
              window.__cmuxNativeNavigationCalls = [];
              scroller.scrollTo = function(options) { window.__cmuxNativeNavigationCalls.push(options); };
            })();
            """
        )
        let domKeyCallCount = try #require(
            try await webView.evaluateJavaScript(
                "document.dispatchEvent(new KeyboardEvent('keydown', { key: 'j', bubbles: true })); window.__cmuxNativeNavigationCalls.length"
            ) as? NSNumber
        )
        #expect(domKeyCallCount.intValue == 0)
        #expect(handleViewerNavigationKey(Self.keyEvent("j"), in: webView, appDelegate: appDelegate))
        #expect(handleViewerNavigationKey(Self.keyEvent("d", modifiers: .control), in: webView, appDelegate: appDelegate))
        #expect(handleViewerNavigationKey(Self.keyEvent("p", modifiers: .control), in: webView, appDelegate: appDelegate))
        #expect(handleViewerNavigationKey(Self.keyEvent("g"), in: webView, appDelegate: appDelegate))
        #expect(handleViewerNavigationKey(Self.keyEvent("g"), in: webView, appDelegate: appDelegate))
        #expect(!handleViewerNavigationKey(Self.keyEvent("x"), in: webView, appDelegate: appDelegate))
        let nativeCalls = try #require(
            try await webView.evaluateJavaScript("window.__cmuxNativeNavigationCalls") as? [[String: Any]]
        )
        #expect(nativeCalls.count == 4)
        #expect(nativeCalls.map { $0["behavior"] as? String } == ["smooth", "smooth", "smooth", "smooth"])
        #expect((nativeCalls[0]["top"] as? NSNumber)?.doubleValue == 72)
        #expect(
            (nativeCalls[1]["top"] as? NSNumber)?.doubleValue ?? 0
                > ((nativeCalls[0]["top"] as? NSNumber)?.doubleValue ?? .greatestFiniteMagnitude)
        )
        #expect(
            (nativeCalls[2]["top"] as? NSNumber)?.doubleValue ?? .greatestFiniteMagnitude
                < ((nativeCalls[1]["top"] as? NSNumber)?.doubleValue ?? 0)
        )
        #expect((nativeCalls[3]["top"] as? NSNumber)?.doubleValue == 0)

        _ = try await webView.evaluateJavaScript("window.__cmuxNativeNavigationCalls = []")
        #expect(handleViewerNavigationKey(Self.keyEvent("g", timestamp: 10), in: webView, appDelegate: appDelegate))
        #expect(handleViewerNavigationKey(Self.keyEvent("g", timestamp: 11), in: webView, appDelegate: appDelegate))
        let staleChordCalls = try #require(
            try await webView.evaluateJavaScript("window.__cmuxNativeNavigationCalls") as? [[String: Any]]
        )
        #expect(staleChordCalls.isEmpty, "an expired chord must not navigate")
        #expect(handleViewerNavigationKey(Self.keyEvent("g", timestamp: 11.1), in: webView, appDelegate: appDelegate))
        let expiredChordCalls = try #require(
            try await webView.evaluateJavaScript("window.__cmuxNativeNavigationCalls") as? [[String: Any]]
        )
        #expect(expiredChordCalls.count == 1)
        #expect((expiredChordCalls[0]["top"] as? NSNumber)?.doubleValue == 0)

        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              const editor = document.createElement('div');
              editor.contentEditable = 'true';
              document.body.appendChild(editor);
              editor.focus();
            })();
            """
        )
        for _ in 0..<20 where !webView.isViewerNavigationEditableElementFocused {
            await Task.yield()
        }
        #expect(webView.isViewerNavigationEditableElementFocused)
        #expect(!webView.handleViewerNavigationKey(Self.keyEvent("j")))
    }

    @Test
    func markdownViewerHonorsConfiguredWhenClause() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let originalStore = KeyboardShortcutSettings.settingsFileStore
        let originalCache = appDelegate.shortcutEventFocusContextCache
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-navigation-\(UUID().uuidString).json")
        try """
        {
          "shortcuts": {
            "when": {
              "diffViewerScrollDown": "terminalFocus"
            }
          }
        }
        """.write(to: settingsURL, atomically: true, encoding: .utf8)
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        defer {
            appDelegate.shortcutEventFocusContextCache = originalCache
            KeyboardShortcutSettings.settingsFileStore = originalStore
            try? FileManager.default.removeItem(at: settingsURL)
        }

        let event = Self.keyEvent("j")
        installMarkdownFocusContext(for: event, appDelegate: appDelegate)
        let webView = MarkdownWebView(frame: .zero, configuration: WKWebViewConfiguration())

        #expect(!webView.handleViewerNavigationKey(event))
    }

    private func handleViewerNavigationKey(
        _ event: NSEvent,
        in webView: MarkdownWebView,
        appDelegate: AppDelegate
    ) -> Bool {
        installMarkdownFocusContext(for: event, appDelegate: appDelegate)
        return webView.handleViewerNavigationKey(event)
    }

    private func installMarkdownFocusContext(for event: NSEvent, appDelegate: AppDelegate) {
        var shortcutContext = ShortcutContext()
        shortcutContext.setBool("markdownFocus", true)
        appDelegate.shortcutEventFocusContextCache = ShortcutEventFocusContextCache(
            event: event,
            context: ShortcutEventFocusContext(
                browserPanel: nil,
                markdownPanel: nil,
                filePreviewTextEditorFocused: false,
                rightSidebarFocused: false,
                shortcutContext: shortcutContext
            )
        )
    }

    private func renderMarkdown(_ markdown: String, in webView: WKWebView) async throws {
        let data = try JSONSerialization.data(withJSONObject: [markdown])
        let literal = try #require(String(data: data, encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.__cmuxRenderMarkdown(\(literal)[0]);")
    }

    private func scrollSmokeMarkdown() -> String {
        (1...36).map { section in
            "## Section \(section)\n\n" + (1...5).map { paragraph in
                "Paragraph \(paragraph) for section \(section). This gives the renderer enough height to exercise viewer navigation."
            }.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
    }

    private static func keyEvent(
        _ characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        timestamp: TimeInterval = 0
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: timestamp,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        )!
    }
}

private actor SidecarPoolTestCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private final class ViewerNavigationShellLoadDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView, baseURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
