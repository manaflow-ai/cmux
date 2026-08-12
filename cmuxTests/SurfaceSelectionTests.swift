import AppKit
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Surface selection", .serialized)
struct SurfaceSelectionTests {
    @Test func nativeSelectionMapsUTF16RangesToOneBasedSourceLines() throws {
        let cases: [(source: String, selected: String, start: Int, end: Int)] = [
            ("alpha\nbeta\ngamma", "beta", 2, 2),
            ("alpha\r\nbeta\r\ngamma", "beta\r\ngamma", 2, 3),
            ("zero\n😀 emoji\nlast\n", "😀 emoji\nlast\n", 2, 3),
        ]

        for testCase in cases {
            let textView = NSTextView(frame: .zero)
            textView.string = testCase.source
            let selectedRange = (testCase.source as NSString).range(of: testCase.selected)
            textView.setSelectedRange(selectedRange)

            let snapshot = NativeTextSurfaceSelectionReader().read(
                textView: textView,
                kind: .filePreview,
                filePath: "/tmp/../tmp/example.swift"
            )

            #expect(snapshot.hasSelection)
            #expect(snapshot.text == testCase.selected)
            #expect(snapshot.filePath == "/tmp/example.swift")
            #expect(snapshot.lineRange?.start == testCase.start)
            #expect(snapshot.lineRange?.end == testCase.end)
        }
    }

    @Test func nativePanelsExposeTheSameSelectionShape() async throws {
        let source = "first\nselected 😀 text\nlast"
        let selectedRange = (source as NSString).range(of: "selected 😀 text")

        let fileTextView = NSTextView(frame: .zero)
        fileTextView.string = source
        fileTextView.setSelectedRange(selectedRange)
        let filePanel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: "/tmp/example.swift",
            startFileWatcher: false
        )
        filePanel.textView = fileTextView
        defer { filePanel.close() }

        let fileSnapshot = try snapshot(from: await filePanel.readSurfaceSelection())
        #expect(fileSnapshot.kind == .filePreview)
        #expect(fileSnapshot.text == "selected 😀 text")
        #expect(fileSnapshot.filePath == "/tmp/example.swift")
        #expect(fileSnapshot.lineRange == SurfaceSelectionLineRange(start: 2, end: 2))

        let markdownTextView = NSTextView(frame: .zero)
        markdownTextView.string = source
        markdownTextView.setSelectedRange(selectedRange)
        let markdownPanel = MarkdownPanel(
            workspaceId: UUID(),
            filePath: "/tmp/example.md"
        )
        markdownPanel.setDisplayMode(.text)
        markdownPanel.attachTextView(markdownTextView)
        defer { markdownPanel.close() }

        let markdownSnapshot = try snapshot(from: await markdownPanel.readSurfaceSelection())
        #expect(markdownSnapshot.kind == .markdown)
        #expect(markdownSnapshot.text == "selected 😀 text")
        #expect(markdownSnapshot.filePath == "/tmp/example.md")
        #expect(markdownSnapshot.lineRange == SurfaceSelectionLineRange(start: 2, end: 2))
    }

    @Test(.timeLimit(.minutes(1)))
    func browserAndMarkdownPreviewReadLiveDOMSelection() async throws {
        let unloadedPanel = BrowserPanel(workspaceId: UUID())
        defer { unloadedPanel.close() }
        let unloadedSnapshot = try snapshot(from: await unloadedPanel.readSurfaceSelection())
        #expect(!unloadedSnapshot.hasSelection)
        #expect(unloadedSnapshot.kind == .browser)
        #expect(unloadedSnapshot.url == nil)

        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        let baseURL = try #require(URL(string: "https://selection.test/document"))
        let loader = SurfaceSelectionNavigationLoader()
        try await loader.load(
            """
            <!doctype html>
            <html><body>
              <p id="passage">before selected browser words after</p>
              <iframe id="same-origin-frame" srcdoc="<p id='frame-passage'>before selected frame words after</p>"></iframe>
              <input id="password" type="password" value="top-secret">
            </body></html>
            """,
            baseURL: baseURL,
            in: panel.webView
        )

        _ = try await panel.evaluateJavaScript(
            """
            (() => {
              const node = document.getElementById('passage').firstChild;
              const start = node.textContent.indexOf('selected browser words');
              const range = document.createRange();
              range.setStart(node, start);
              range.setEnd(node, start + 'selected browser words'.length);
              const selection = window.getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
              return true;
            })()
            """
        )

        let browserSnapshot = try snapshot(from: await panel.readSurfaceSelection())
        #expect(browserSnapshot.kind == .browser)
        #expect(browserSnapshot.text == "selected browser words")
        #expect(browserSnapshot.url == baseURL.absoluteString)
        #expect(browserSnapshot.filePath == nil)
        #expect(browserSnapshot.lineRange == nil)

        let markdownSnapshot = try snapshot(from: await WebSurfaceSelectionReader().read(
            webView: panel.webView,
            kind: .markdown,
            filePath: "/tmp/guide.md"
        ))
        #expect(markdownSnapshot.kind == .markdown)
        #expect(markdownSnapshot.text == "selected browser words")
        #expect(markdownSnapshot.filePath == "/tmp/guide.md")

        _ = try await panel.evaluateJavaScript(
            """
            (() => {
              window.getSelection().removeAllRanges();
              const frame = document.getElementById('same-origin-frame');
              const childWindow = frame.contentWindow;
              const node = childWindow.document.getElementById('frame-passage').firstChild;
              const start = node.textContent.indexOf('selected frame words');
              const range = childWindow.document.createRange();
              range.setStart(node, start);
              range.setEnd(node, start + 'selected frame words'.length);
              const selection = childWindow.getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
              childWindow.focus();
              return true;
            })()
            """
        )
        let frameSnapshot = try snapshot(from: await panel.readSurfaceSelection())
        #expect(frameSnapshot.text == "selected frame words")

        _ = try await panel.evaluateJavaScript(
            """
            (() => {
              window.getSelection().removeAllRanges();
              const password = document.getElementById('password');
              password.focus();
              password.setSelectionRange(0, password.value.length);
              return true;
            })()
            """
        )
        let passwordSnapshot = try snapshot(from: await panel.readSurfaceSelection())
        #expect(!passwordSnapshot.hasSelection)
        #expect(passwordSnapshot.text.isEmpty)
        #expect(passwordSnapshot.url == baseURL.absoluteString)
    }

    private func snapshot(
        from result: SurfaceSelectionReadResult
    ) throws -> SurfaceSelectionSnapshot {
        guard case .snapshot(let snapshot) = result else {
            throw SurfaceSelectionTestError.expectedSnapshot
        }
        return snapshot
    }
}

private enum SurfaceSelectionTestError: Error {
    case expectedSnapshot
}

@MainActor
private final class SurfaceSelectionNavigationLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private weak var previousNavigationDelegate: (any WKNavigationDelegate)?

    func load(
        _ html: String,
        baseURL: URL,
        in webView: WKWebView
    ) async throws {
        previousNavigationDelegate = webView.navigationDelegate
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(with: .success(()), webView: webView)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(with: .failure(error), webView: webView)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(with: .failure(error), webView: webView)
    }

    private func finish(
        with result: Result<Void, any Error>,
        webView: WKWebView
    ) {
        guard let continuation else { return }
        self.continuation = nil
        webView.navigationDelegate = previousNavigationDelegate
        previousNavigationDelegate = nil
        continuation.resume(with: result)
    }
}
