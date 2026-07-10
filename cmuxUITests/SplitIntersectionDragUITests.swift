import XCTest

/// Dragging the corner where a vertical and a horizontal split divider meet
/// must resize both split views at once (PR: intersection two-axis resize).
final class SplitIntersectionDragUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testIntersectionDragResizesBothAxes() {
        let app = XCUIApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10.0))

        XCTAssertTrue(waitForTerminalPaneCount(app, 1, timeout: 15.0), "Expected the initial terminal pane")

        app.typeKey("d", modifierFlags: [.command])
        XCTAssertTrue(waitForTerminalPaneCount(app, 2, timeout: 10.0), "Expected split-right to add a second pane")

        app.typeKey("d", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitForTerminalPaneCount(app, 3, timeout: 10.0), "Expected split-down to add a third pane")

        guard let before = paneGeometry(app) else {
            XCTFail("Could not derive divider geometry from pane frames")
            return
        }

        // Start just inside the stacked column so the point sits in both the
        // vertical and the horizontal divider's hit band (bands are Â±8pt).
        let startX = before.verticalDividerX + (before.stackedColumnIsTrailing ? 4 : -4)
        let startY = before.horizontalDividerY
        let start = window.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: startX - window.frame.minX, dy: startY - window.frame.minY)
        )
        let end = start.withOffset(CGVector(dx: -60, dy: -60))
        start.press(forDuration: 0.15, thenDragTo: end)

        guard let after = paneGeometry(app) else {
            XCTFail("Could not derive divider geometry after the drag")
            return
        }

        let horizontalDelta = after.verticalDividerX - before.verticalDividerX
        let verticalDelta = after.horizontalDividerY - before.horizontalDividerY

        XCTAssertLessThanOrEqual(horizontalDelta, -30, "Expected the vertical divider to move left with the drag. delta=\(horizontalDelta)")
        XCTAssertGreaterThanOrEqual(horizontalDelta, -80, "Vertical divider moved farther than the drag. delta=\(horizontalDelta)")
        XCTAssertLessThanOrEqual(verticalDelta, -30, "Expected the horizontal divider to move up with the drag. delta=\(verticalDelta)")
        XCTAssertGreaterThanOrEqual(verticalDelta, -80, "Horizontal divider moved farther than the drag. delta=\(verticalDelta)")
    }

    private struct PaneGeometry {
        let verticalDividerX: CGFloat
        let horizontalDividerY: CGFloat
        let stackedColumnIsTrailing: Bool
    }

    /// Terminal surfaces are AX text areas ("Terminal content area"). With a
    /// left/right split whose one column is split again top/bottom, derive the
    /// vertical divider x (gap between the columns) and the horizontal divider
    /// y (gap between the stacked panes).
    private func paneGeometry(_ app: XCUIApplication) -> PaneGeometry? {
        let frames = terminalPaneFrames(app)
        guard frames.count == 3 else { return nil }

        let sortedByX = frames.sorted { $0.minX < $1.minX }
        let leadingColumnX = sortedByX[0].minX
        let columns = Dictionary(grouping: frames) { abs($0.minX - leadingColumnX) < 2 }
        guard let leadingColumn = columns[true], let trailingColumn = columns[false],
              !leadingColumn.isEmpty, !trailingColumn.isEmpty else { return nil }

        let stacked = leadingColumn.count == 2 ? leadingColumn : trailingColumn
        guard stacked.count == 2 else { return nil }
        let stackedColumnIsTrailing = stacked[0].minX > leadingColumnX + 1

        let leadingMaxX = leadingColumn.map(\.maxX).max() ?? 0
        let trailingMinX = trailingColumn.map(\.minX).min() ?? 0
        let verticalDividerX = (leadingMaxX + trailingMinX) / 2

        let stackedSorted = stacked.sorted { $0.minY < $1.minY }
        let horizontalDividerY = (stackedSorted[0].maxY + stackedSorted[1].minY) / 2

        return PaneGeometry(
            verticalDividerX: verticalDividerX,
            horizontalDividerY: horizontalDividerY,
            stackedColumnIsTrailing: stackedColumnIsTrailing
        )
    }

    private func terminalPaneFrames(_ app: XCUIApplication) -> [CGRect] {
        app.windows.firstMatch.descendants(matching: .textView).allElementsBoundByIndex
            .map { $0.frame }
            .filter { $0.width >= 100 && $0.height >= 100 }
    }

    private func waitForTerminalPaneCount(_ app: XCUIApplication, _ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if terminalPaneFrames(app).count == count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return terminalPaneFrames(app).count == count
    }
}
