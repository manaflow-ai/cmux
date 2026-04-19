import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class RunestoneVendoringTests: XCTestCase {
    func testVendoredRunestoneSmokeSnapshot() {
        let snapshot = VendoredRunestoneSupport.makeSmokeSnapshot()

        XCTAssertEqual(snapshot.text, "# cmux\nVendored Runestone\n")
        XCTAssertTrue(snapshot.isEditable)
        XCTAssertTrue(snapshot.isSelectable)
        XCTAssertEqual(snapshot.themeTypeName, "DefaultTheme")
    }

    func testMarkdownRendererAppliesHeadingAndLinkAttributes() {
        let storage = NSTextStorage(string: "# Title\n\nA [link](https://example.com)\n")
        let theme = MarkdownPanelTheme(config: GhosttyConfig())

        MarkdownPanelAttributedRenderer.render(
            markdown: storage.string,
            in: storage,
            theme: theme
        )

        let titleRange = (storage.string as NSString).range(of: "Title")
        let headingFont = storage.attribute(.font, at: titleRange.location, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(headingFont)
        XCTAssertGreaterThan(headingFont?.pointSize ?? 0, theme.font.pointSize)

        let linkRange = (storage.string as NSString).range(of: "[link](https://example.com)")
        let linkValue = storage.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL
        XCTAssertEqual(linkValue?.absoluteString, "https://example.com")
    }

    func testMarkdownThemeUsesGhosttyFontAndPalette() {
        var config = GhosttyConfig()
        config.fontFamily = "Menlo"
        config.fontSize = 17
        config.backgroundColor = NSColor(hex: "#101214")!
        config.foregroundColor = NSColor(hex: "#f5f6f7")!
        config.selectionBackground = NSColor(hex: "#303846")!
        config.selectionForeground = NSColor(hex: "#ffffff")!
        config.cursorColor = NSColor(hex: "#87d7ff")!
        config.palette[2] = NSColor(hex: "#7ec16e")!
        config.palette[4] = NSColor(hex: "#6aa9ff")!
        config.palette[5] = NSColor(hex: "#c792ea")!

        let theme = MarkdownPanelTheme(config: config)

        XCTAssertEqual(theme.font.pointSize, 17)
        XCTAssertEqual(theme.font.familyName, "Menlo")
        XCTAssertEqual(theme.editorBackgroundColor.hexString(), "#101214")
        XCTAssertEqual(theme.textColor.hexString(), "#F5F6F7")
        XCTAssertEqual(theme.headingColor.hexString(), "#C792EA")
        XCTAssertEqual(theme.linkColor.hexString(), "#6AA9FF")
        XCTAssertEqual(theme.codeColor.hexString(), "#7EC16E")
    }
}
