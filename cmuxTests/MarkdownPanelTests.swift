import AppKit
import Combine
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class MarkdownPanelTests: XCTestCase {
    func testMarkdownThemeUsesTransparentPageAndOverlayTintsForTranslucentBackgrounds() throws {
        let theme = MarkdownWebTheme.resolve(
            backgroundColor: NSColor(
                srgbRed: 0.10,
                green: 0.12,
                blue: 0.14,
                alpha: 0.42
            )
        )

        XCTAssertTrue(theme.isDark)
        XCTAssertEqual(theme.background, "transparent")
        XCTAssertEqual(Self.cssRGBAComponents(theme.mutedBackground)?.red, 255)
        XCTAssertEqual(Self.cssRGBAComponents(theme.mutedBackground)?.green, 255)
        XCTAssertEqual(Self.cssRGBAComponents(theme.mutedBackground)?.blue, 255)
        XCTAssertEqual(Self.cssRGBAComponents(theme.neutralMutedBackground)?.red, 255)
        XCTAssertGreaterThan(
            try XCTUnwrap(Self.cssRGBAComponents(theme.neutralMutedBackground)?.alpha),
            try XCTUnwrap(Self.cssRGBAComponents(theme.mutedBackground)?.alpha)
        )
        XCTAssertFalse(theme.mutedBackground.contains("0.420"))
        XCTAssertFalse(theme.neutralMutedBackground.contains("0.420"))
    }

    func testMarkdownThemeOverlayFallsBackToFullOverlayWhenContrastIsUnreachable() {
        let base = NSColor(srgbRed: 0.2, green: 0.24, blue: 0.28, alpha: 0.4)
        let overlay = base.markdownThemeOverlay(targetContrast: 21, of: base)

        XCTAssertEqual(overlay.alphaComponent, 1, accuracy: 0.0001)
    }

    func testFileOpenRoutesMarkdownFilesToPreviewMarkdownPanel() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-markdown-file-open-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            try? fileManager.removeItem(at: directoryURL)
        }

        let fileURL = directoryURL.appendingPathComponent("README.md")
        try "# Title\n\nBody.\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        TerminalController.shared.setActiveTabManager(manager)

        let result = TerminalController.shared.v2FileOpen(params: [
            "paths": [fileURL.path],
            "workspace_id": workspace.id.uuidString,
            "pane_id": pane.id.uuidString,
            "focus": false
        ])

        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any],
              let openedPanelIdString = payload["surface_id"] as? String,
              let openedPanelId = UUID(uuidString: openedPanelIdString) else {
            XCTFail("Expected file.open to succeed for markdown, got \(result)")
            return
        }

        let panel = try XCTUnwrap(workspace.markdownPanel(for: openedPanelId))
        XCTAssertEqual(panel.filePath, fileURL.path)
        XCTAssertEqual(panel.displayMode, .preview)
        XCTAssertNil(workspace.filePreviewPanel(for: openedPanelId))
        XCTAssertEqual(payload["panel_type"] as? String, PanelType.markdown.rawValue)
        XCTAssertEqual(payload["display_mode"] as? String, MarkdownPanelDisplayMode.preview.rawValue)
    }

    func testOpenMarkdownPanelReloadsWhenFileChangesOnDisk() async throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-markdown-panel-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let fileURL = directoryURL.appendingPathComponent("live.md")
        let originalContent = "# Original\n\nBody before save.\n"
        let updatedContent = "# Updated\n\nBody after external save.\n"
        try originalContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: fileURL.path)
        defer { panel.close() }

        XCTAssertEqual(panel.content, originalContent)
        XCTAssertFalse(panel.isFileUnavailable)

        let reloaded = expectation(description: "markdown file change reloaded")
        let cancellable = panel.$content.dropFirst().sink { content in
            if content == updatedContent {
                reloaded.fulfill()
            }
        }
        defer { cancellable.cancel() }

        try updatedContent.write(to: fileURL, atomically: true, encoding: .utf8)

        await fulfillment(of: [reloaded], timeout: 3)
        XCTAssertEqual(panel.content, updatedContent)
        XCTAssertEqual(panel.textContent, updatedContent)
        XCTAssertFalse(panel.isDirty)
    }

    func testMarkdownRenderKeepsVisibleHeadingPositionAfterContentUpdate() async throws {
        let frame = NSRect(x: 0, y: 0, width: 720, height: 360)
        let webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            window.close()
        }

        let loaded = expectation(description: "markdown shell loaded")
        let loadDelegate = MarkdownShellLoadDelegate(expectation: loaded)
        webView.navigationDelegate = loadDelegate
        webView.loadHTMLString(
            MarkdownViewerAssets.shared.shellHTML(isDark: true),
            baseURL: FileManager.default.temporaryDirectory.appendingPathComponent("scroll.md")
        )
        await fulfillment(of: [loaded], timeout: 5)
        if let error = loadDelegate.error {
            throw error
        }

        try await renderMarkdown(scrollSmokeMarkdown(extraBeforeSection20: false), in: webView)
        let before = try await evaluateScrollSnapshot(
            """
            (function() {
              var scroller = document.scrollingElement || document.documentElement;
              var heading = document.getElementById('section-20');
              document.documentElement.style.scrollBehavior = 'auto';
              window.scrollTo(0, heading.offsetTop - 48);
              return {
                top: heading.getBoundingClientRect().top,
                y: window.scrollY || scroller.scrollTop,
                max: scroller.scrollHeight - scroller.clientHeight
              };
            })();
            """,
            in: webView
        )

        XCTAssertGreaterThan(before["max"] ?? 0, 1_000)

        try await renderMarkdown(scrollSmokeMarkdown(extraBeforeSection20: true), in: webView)
        let after = try await evaluateScrollSnapshot(
            """
            (function() {
              var scroller = document.scrollingElement || document.documentElement;
              var heading = document.getElementById('section-20');
              return {
                top: heading.getBoundingClientRect().top,
                y: window.scrollY || scroller.scrollTop,
                max: scroller.scrollHeight - scroller.clientHeight
              };
            })();
            """,
            in: webView
        )

        XCTAssertGreaterThan(after["max"] ?? 0, before["max"] ?? 0)
        XCTAssertEqual(after["top"] ?? .greatestFiniteMagnitude, before["top"] ?? 0, accuracy: 6)
    }

    private func renderMarkdown(_ markdown: String, in webView: WKWebView) async throws {
        let data = try JSONSerialization.data(withJSONObject: [markdown])
        let literal = try XCTUnwrap(String(data: data, encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.__cmuxRenderMarkdown(\(literal)[0]);")
    }

    private func evaluateScrollSnapshot(_ script: String, in webView: WKWebView) async throws -> [String: Double] {
        let result = try await webView.evaluateJavaScript(script)
        let raw = try XCTUnwrap(result as? [String: Any])
        var snapshot: [String: Double] = [:]
        for (key, value) in raw {
            if let number = value as? NSNumber {
                snapshot[key] = number.doubleValue
            }
        }
        return snapshot
    }

    private func scrollSmokeMarkdown(extraBeforeSection20: Bool) -> String {
        var lines: [String] = ["# Scroll Smoke", ""]
        for section in 1...36 {
            if section == 20, extraBeforeSection20 {
                for line in 1...12 {
                    lines.append("Inserted external edit line \(line), above the visible heading.")
                }
                lines.append("")
            }

            lines.append("## Section \(section)")
            lines.append("")
            for paragraph in 1...5 {
                lines.append(
                    "Paragraph \(paragraph) for section \(section). This gives the renderer enough height to exercise scroll restoration after an external file edit."
                )
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func cssRGBAComponents(_ css: String) -> (red: Int, green: Int, blue: Int, alpha: Double)? {
        let pattern = #"rgba\((\d+), (\d+), (\d+), ([0-9.]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: css, range: NSRange(css.startIndex..., in: css)),
              match.numberOfRanges == 5 else {
            return nil
        }
        func string(at index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: css) else { return nil }
            return String(css[range])
        }
        guard let red = string(at: 1).flatMap(Int.init),
              let green = string(at: 2).flatMap(Int.init),
              let blue = string(at: 3).flatMap(Int.init),
              let alpha = string(at: 4).flatMap(Double.init) else {
            return nil
        }
        return (red, green, blue, alpha)
    }
}

private final class MarkdownShellLoadDelegate: NSObject, WKNavigationDelegate {
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
