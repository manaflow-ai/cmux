import AppKit
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct MarkdownEditorPageTests {
    private static func testAppearance() -> PanelAppearance {
        PanelAppearance(
            backgroundColor: .black,
            foregroundColor: .white,
            dividerColor: Color(nsColor: .gray),
            unfocusedOverlayNSColor: .black,
            unfocusedOverlayOpacity: 0.2,
            usesClearContentBackground: false
        )
    }

    @Test @MainActor func configSurvivesScriptBreakingContent() throws {
        let hostileContent = "# Title\n</script><script>alert(1)</script>\nplain `</` text"
        let html = try MarkdownEditorPage.html(
            filePath: "/tmp/notes.md",
            content: hostileContent,
            readOnly: false,
            contentSha256: "abc123",
            initialDirty: true,
            wordWrap: true,
            appearance: Self.testAppearance()
        )

        let marker = "<script id=\"cmux-editor-config\" type=\"application/json\">"
        let afterMarker = try #require(html.range(of: marker)).upperBound
        let configRegion = html[afterMarker...]
        // Every `</` inside the config JSON is escaped, so the first raw
        // `</script>` after the marker is the data block's own closing tag.
        let closing = try #require(configRegion.range(of: "</script>"))
        let configJSON = String(configRegion[..<closing.lowerBound])
        #expect(!configJSON.contains("</script"))

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(configJSON.utf8)) as? [String: Any]
        )
        let payload = try #require(object["payload"] as? [String: Any])
        #expect(payload["content"] as? String == hostileContent)
        #expect(payload["filePath"] as? String == "/tmp/notes.md")
        #expect(payload["readOnly"] as? Bool == false)
        #expect(payload["contentSha256"] as? String == "abc123")
        #expect(payload["initialDirty"] as? Bool == true)
        #expect(payload["wordWrap"] as? Bool == true)
        #expect(payload["mirrorContent"] as? Bool == true)
        let appearance = try #require(payload["appearance"] as? [String: Any])
        let themes = try #require(appearance["themes"] as? [String: Any])
        let dark = try #require(themes["dark"] as? [String: Any])
        #expect(dark["background"] as? String == "#000000")
        #expect(dark["type"] as? String == "dark")
    }

    @Test func sha256HexMatchesKnownVector() {
        #expect(
            MarkdownEditorPage.sha256Hex(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test func htmlEscapingNeutralizesMarkup() {
        #expect(MarkdownEditorPage.htmlEscaped("<b>\"&'") == "&lt;b&gt;&quot;&amp;'")
    }
}

@Suite struct MarkdownEditorSchemeHandlerTests {
    private func components(_ path: String) -> [String]? {
        MarkdownEditorSchemeHandler.requestPathComponents(
            for: URL(string: "\(MarkdownEditorSchemeHandler.scheme)://token0123456789abcdef\(path)")!
        )
    }

    @Test func acceptsBundleAssetPaths() {
        #expect(components("/index.html") == ["index.html"])
        #expect(components("/main.mjs") == ["main.mjs"])
        #expect(components("/chunks/markdown.mjs") == ["chunks", "markdown.mjs"])
        #expect(components("/assets/monaco-vendor.css") == ["assets", "monaco-vendor.css"])
    }

    @Test func rejectsTraversalAndMalformedPaths() {
        #expect(components("/../Info.plist") == nil)
        #expect(components("/chunks/../../secrets.mjs") == nil)
        #expect(components("/chunks//markdown.mjs") == nil)
        #expect(components("/chunks/") == nil)
        #expect(components("/./main.mjs") == nil)
        #expect(components("") == nil)
    }

    @Test func onlyModuleAndStylesheetAssetsAreServable() {
        #expect(MarkdownEditorSchemeHandler.assetMimeType(for: ["chunks", "markdown.mjs"]) == "text/javascript")
        #expect(MarkdownEditorSchemeHandler.assetMimeType(for: ["assets", "editor.worker.js"]) == "text/javascript")
        #expect(MarkdownEditorSchemeHandler.assetMimeType(for: ["assets", "monaco-vendor.css"]) == "text/css")
        #expect(MarkdownEditorSchemeHandler.assetMimeType(for: ["agent-session.html"]) == nil)
        #expect(MarkdownEditorSchemeHandler.assetMimeType(for: ["chunks", "monaco-vendor.mjs.deflate"]) == nil)
        #expect(MarkdownEditorSchemeHandler.assetMimeType(for: ["assets", "codicon.ttf"]) == nil)
    }

    @Test func htmlResponsesCarryThePageCSP() {
        let headers = MarkdownEditorSchemeHandler.responseHeaders(mimeType: "text/html")
        #expect(headers["Content-Security-Policy"]?.contains("script-src 'self'") == true)
        #expect(headers["X-Content-Type-Options"] == "nosniff")
        let assetHeaders = MarkdownEditorSchemeHandler.responseHeaders(mimeType: "text/javascript")
        #expect(assetHeaders["Content-Security-Policy"] == nil)
    }
}
