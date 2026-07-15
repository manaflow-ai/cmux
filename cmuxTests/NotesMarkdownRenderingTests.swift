import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// End-to-end render checks for the markdown pipeline the Notes tab uses: the
/// real bundled shell (marked.js + highlight.js + GitHub CSS) loaded into a
/// real `WKWebView`, fed markdown exactly the way `MarkdownWebRenderer`
/// feeds it. Notes share this pipeline with the Files-tab viewer, so this is
/// the behavioral guarantee that notes render markdown — headings, fenced
/// code with syntax highlighting, tables, task lists — rather than raw text.
@MainActor
@Suite struct NotesMarkdownRenderingTests {
    @Test func rendersHeadingsCodeTablesAndTaskLists() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        webView.loadHTMLString(MarkdownViewerAssets.shared.shellHTML(isDark: false), baseURL: nil)
        try await waitUntil("markdown shell ready") {
            await evaluate(webView, "String(typeof window.__cmuxRenderMarkdown === 'function')") == "true"
        }

        let markdown = """
        # Heading

        ```swift
        let answer = 42
        ```

        | Left | Right |
        | ---- | ----- |
        | a    | b     |

        - [x] shipped
        - [ ] pending
        """
        // Same JSON-literal hand-off `renderMarkdownScript` uses, so escaping
        // behavior matches the production path.
        let payload = try #require(
            String(data: JSONSerialization.data(withJSONObject: [markdown]), encoding: .utf8)
        )
        _ = try await webView.evaluateJavaScript(
            "(function(md){ window.__cmuxRenderMarkdown(md); return 'ok'; })(\(payload)[0])"
        )

        var rendered = ""
        try await waitUntil("rendered HTML to contain the table") {
            rendered = await evaluate(
                webView, "window.__cmuxRenderedHTML ? window.__cmuxRenderedHTML() : ''"
            ) ?? ""
            return rendered.contains("<table")
        }
        #expect(rendered.contains("<h1"))
        // The fenced block must carry code formatting: either highlight.js
        // already decorated it or the language class survived for it to pick
        // up — both prove the code path, plain-text fallback provides neither.
        #expect(rendered.contains("language-swift") || rendered.contains("hljs"))
        #expect(rendered.contains("type=\"checkbox\""))
        #expect(rendered.contains("shipped"))
    }

    private func evaluate(_ webView: WKWebView, _ script: String) async -> String? {
        (try? await webView.evaluateJavaScript(script)) as? String
    }

    private func waitUntil(
        _ what: String,
        timeoutSeconds: Double = 20,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        Issue.record("Timed out waiting for \(what)")
    }
}
