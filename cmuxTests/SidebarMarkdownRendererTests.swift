import CmuxFoundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SidebarMarkdownRendererTests: XCTestCase {
    func testRenderWorkspaceDescriptionPreservesLineBreaks() throws {
        let rendered = try XCTUnwrap(
            SidebarMarkdownRenderer(markdown: "First line\nSecond line").workspaceDescription
        )

        XCTAssertEqual(String(rendered.characters), "First line\nSecond line")
    }

    func testRenderWorkspaceDescriptionPreservesInlineMarkdownAttributes() throws {
        let rendered = try XCTUnwrap(
            SidebarMarkdownRenderer(markdown: "**Bold**\n[Link](https://example.com)").workspaceDescription
        )

        XCTAssertEqual(String(rendered.characters), "Bold\nLink")
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent != nil })
        XCTAssertTrue(
            rendered.runs.contains { $0.link == URL(string: "https://example.com") }
        )
    }
}
