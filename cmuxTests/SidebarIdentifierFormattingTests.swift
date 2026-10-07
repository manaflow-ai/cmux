import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SidebarIdentifierFormattingTests: XCTestCase {
    func testSidebarPortLabelFormatsCatalogPlaceholder() {
        let label = SidebarPortDisplayText.label(for: 2014)

        XCTAssertEqual(label, ":2014")
        XCTAssertFalse(label.contains("%lld"))
        XCTAssertFalse(label.contains(":2,014"))
    }

    func testSidebarPortTooltipFormatsCatalogPlaceholder() {
        let tooltip = SidebarPortDisplayText.openTooltip(for: 2014)

        XCTAssertTrue(tooltip.contains("2014"))
        XCTAssertFalse(tooltip.contains("%lld"))
        XCTAssertFalse(tooltip.contains("2,014"))
    }
}
