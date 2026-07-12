import AppKit
import Testing
import WebKit
@testable import cmux

@MainActor
@Suite(.serialized)
struct ViewerNavigationTests {
    @Test
    func cliDiffViewerShortcutsIncludeVimAndEmacsNavigation() {
        let expected: [CMUXCLI.DiffViewerShortcutAction: CMUXCLI.DiffViewerShortcut] = [
            .scrollHalfPageDown: .init(first: .init(key: "d", control: true)),
            .scrollHalfPageUp: .init(first: .init(key: "u", control: true)),
            .scrollDownEmacs: .init(first: .init(key: "n", control: true)),
            .scrollUpEmacs: .init(first: .init(key: "p", control: true)),
            .nextFile: .init(first: .init(key: "]"), second: .init(key: "f")),
            .previousFile: .init(first: .init(key: "["), second: .init(key: "f")),
        ]

        for (action, shortcut) in expected {
            #expect(action.defaultShortcut == shortcut)
            #expect(shortcut.jsonObject["unbound"] == nil)
        }
    }

    @Test
    func markdownViewerUsesSmoothVimAndEmacsNavigation() async throws {
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
        #expect(webView.handleViewerNavigationKey(Self.keyEvent("j")))
        #expect(webView.handleViewerNavigationKey(Self.keyEvent("d", modifiers: .control)))
        #expect(webView.handleViewerNavigationKey(Self.keyEvent("p", modifiers: .control)))
        #expect(webView.handleViewerNavigationKey(Self.keyEvent("g")))
        #expect(webView.handleViewerNavigationKey(Self.keyEvent("g")))
        #expect(!webView.handleViewerNavigationKey(Self.keyEvent("x")))
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
        #expect(webView.handleViewerNavigationKey(Self.keyEvent("g", timestamp: 10)))
        #expect(webView.handleViewerNavigationKey(Self.keyEvent("g", timestamp: 11)))
        #expect(webView.handleViewerNavigationKey(Self.keyEvent("g", timestamp: 11.1)))
        let expiredChordCalls = try #require(
            try await webView.evaluateJavaScript("window.__cmuxNativeNavigationCalls") as? [[String: Any]]
        )
        #expect(expiredChordCalls.count == 1)
        #expect((expiredChordCalls[0]["top"] as? NSNumber)?.doubleValue == 0)
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
