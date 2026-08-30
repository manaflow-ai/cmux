import CmuxFoundation
import CmuxSettings
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
@MainActor
struct SidebarMarkdownRendererTests {
    private static let chromePalette = ChromePalette.builtIn(theme: .default, colorScheme: .light)
    @Test
    func renderWorkspaceDescriptionPreservesLineBreaks() throws {
        let rendered = try #require(
            SidebarMarkdownRenderer(markdown: "First line\nSecond line").workspaceDescription
        )

        #expect(String(rendered.characters) == "First line\nSecond line")
    }

    @Test
    func renderWorkspaceDescriptionPreservesInlineMarkdownAttributes() throws {
        let rendered = try #require(
            SidebarMarkdownRenderer(markdown: "**Bold**\n[Link](https://example.com)").workspaceDescription
        )

        #expect(String(rendered.characters) == "Bold\nLink")
        #expect(rendered.runs.contains { $0.inlinePresentationIntent != nil })
        #expect(
            rendered.runs.contains { $0.link == URL(string: "https://example.com") }
        )
    }

    @Test
    func selectedDescriptionStylesSafeLinkWithoutRemovingActivation() throws {
        let url = try #require(URL(string: "https://cmux.com"))
        let content = SidebarWorkspaceDescriptionText(
            markdown: "Read [cmux](\(url.absoluteString))",
            isActive: true,
            activeForegroundColor: .white,
            fontScale: 1,
            chromePalette: Self.chromePalette
        ).renderedContent
        let rendered = try #require(content.renderedMarkdown)
        let linkRun = try #require(rendered.runs.first { $0.link == url })

        #expect(linkRun.foregroundColor == .white)
        #expect(linkRun.link == url)
    }

    @Test
    func inactiveDescriptionRetainsSystemStylingForSafeLink() throws {
        let url = try #require(URL(string: "https://cmux.com"))
        let content = SidebarWorkspaceDescriptionText(
            markdown: "Read [cmux](\(url.absoluteString))",
            isActive: false,
            activeForegroundColor: .white,
            fontScale: 1,
            chromePalette: Self.chromePalette
        ).renderedContent
        let rendered = try #require(content.renderedMarkdown)
        let linkRun = try #require(rendered.runs.first { $0.link == url })

        #expect(linkRun.foregroundColor == nil)
        #expect(linkRun.link == url)
    }

    @Test
    func descriptionDropsNonWebLinkActivation() throws {
        let content = SidebarWorkspaceDescriptionText(
            markdown: "Open [local](file:///tmp/private.txt)",
            isActive: true,
            activeForegroundColor: .white,
            fontScale: 1,
            chromePalette: Self.chromePalette
        ).renderedContent
        let rendered = try #require(content.renderedMarkdown)

        #expect(!rendered.runs.contains { $0.link != nil })
        #expect(String(rendered.characters) == "Open local")
    }

    @Test
    func descriptionTransformsEveryLinkFromOneImmutableSource() throws {
        let secureURL = try #require(URL(string: "https://secure.example"))
        let plainURL = try #require(URL(string: "http://plain.example"))
        let content = SidebarWorkspaceDescriptionText(
            markdown: "[secure](\(secureURL.absoluteString)) " +
                "[local](file:///tmp/private.txt) [plain](\(plainURL.absoluteString))",
            isActive: true,
            activeForegroundColor: .white,
            fontScale: 1,
            chromePalette: Self.chromePalette
        ).renderedContent
        let rendered = try #require(content.renderedMarkdown)
        let linkRuns = rendered.runs.filter { $0.link != nil }

        #expect(linkRuns.compactMap { $0.link } == [secureURL, plainURL])
        #expect(linkRuns.allSatisfy { $0.foregroundColor == .white })
        #expect(String(rendered.characters) == "secure local plain")
    }

    @Test
    func legacyMetadataBlockUsesSharedSelectedRowLinkPolicy() throws {
        let safeURL = try #require(URL(string: "https://cmux.com"))
        let rendered = try #require(
            SidebarMetadataMarkdownRenderer.rendered(
                "[safe](\(safeURL.absoluteString)) [local](file:///tmp/private.txt)"
            )
        )
        let styled = rendered.applyingSidebarRowLinkPolicy(activeForegroundColor: .white)
        let linkRuns = styled.runs.filter { $0.link != nil }

        #expect(linkRuns.compactMap { $0.link } == [safeURL])
        #expect(linkRuns.allSatisfy { $0.foregroundColor == .white })
        #expect(String(styled.characters) == "safe local")
    }

    @Test
    func legacyMetadataEntryUsesSharedSelectedRowLinkPolicy() throws {
        let safeURL = try #require(URL(string: "http://cmux.com"))
        let rendered = try #require(
            try? AttributedString(
                markdown: "[safe](\(safeURL.absoluteString)) [local](file:///tmp/private.txt)",
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        )
        let styled = rendered.applyingSidebarRowLinkPolicy(activeForegroundColor: .white)
        let linkRuns = styled.runs.filter { $0.link != nil }

        #expect(linkRuns.compactMap { $0.link } == [safeURL])
        #expect(linkRuns.allSatisfy { $0.foregroundColor == .white })
        #expect(String(styled.characters) == "safe local")
    }
}
