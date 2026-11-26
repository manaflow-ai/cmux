import AppKit
import Testing
@testable import cmux_DEV

/// The AppKit workspace list scrolls the selected row fully between its
/// content insets: the top titlebar scrim and the bottom footer overlay.
/// A row behind the footer used to count as visible.
@Suite
struct SidebarSelectedRowScrollTests {
    private let insets = NSEdgeInsets(top: 30, left: 0, bottom: 58, right: 0)
    private let documentHeight: CGFloat = 1000

    private func origin(row minY: CGFloat, height: CGFloat = 50, clipOriginY: CGFloat) -> CGFloat? {
        SidebarWorkspaceTableController.selectedRowScrollOrigin(
            rowRect: NSRect(x: 0, y: minY, width: 240, height: height),
            clipBounds: NSRect(x: 0, y: clipOriginY, width: 240, height: 600),
            insets: insets,
            documentHeight: documentHeight
        )
    }

    @Test
    func aRowBetweenTheInsetsDoesNotScroll() {
        #expect(origin(row: 100, clipOriginY: 0) == nil)
    }

    @Test
    func aRowBehindTheFooterScrollsUpUntilItClearsIt() {
        // Visible by the clip bounds (ends at 570 < 600), hidden by the
        // footer (unobscured area ends at 600 - 58 = 542).
        #expect(origin(row: 520, clipOriginY: 0) == 28)
    }

    @Test
    func aRowUnderTheTitlebarScrimScrollsDown() {
        #expect(origin(row: 210, clipOriginY: 200) == 180)
    }

    @Test
    func aRowTallerThanTheClearAreaAlignsItsTop() {
        // Clear area is 512 tall; this row starts in view and runs past the footer.
        #expect(origin(row: 100, height: 600, clipOriginY: 0) == 70)
    }

    @Test
    func scrollingStopsAtTheEndsOfTheList() {
        // The last row can go no further than the bottom inset allows.
        #expect(origin(row: 960, height: 40, clipOriginY: 0) == documentHeight + insets.bottom - 600)
        // The first row can go no higher than the top inset allows.
        #expect(origin(row: 0, clipOriginY: 100) == -insets.top)
    }
}
