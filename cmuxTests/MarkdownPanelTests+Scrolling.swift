import AppKit
import Combine
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Scroll Position
extension MarkdownPanelTests {
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

}
