import XCTest

final class SidebarResizeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testSidebarResizerTracksCursor() {
        let app = XCUIApplication()
        app.launch()

        let elements = app.descendants(matching: .any)
        let resizer = elements["SidebarResizer"]
        XCTAssertTrue(resizer.waitForExistence(timeout: 5.0))

        let initialX = resizer.frame.minX

        let start = resizer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 80, dy: 0))
        start.press(forDuration: 0.1, thenDragTo: end)

        let afterX = resizer.frame.minX
        let rightDelta = afterX - initialX
        XCTAssertGreaterThanOrEqual(rightDelta, 40, "Expected drag-right to move resizer meaningfully")
        XCTAssertLessThanOrEqual(rightDelta, 82, "Resizer moved farther than requested drag-right offset")

        let startBack = resizer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let endBack = startBack.withOffset(CGVector(dx: -120, dy: 0))
        startBack.press(forDuration: 0.1, thenDragTo: endBack)

        let afterBackX = resizer.frame.minX
        let leftDelta = afterBackX - afterX
        // Sidebar width is clamped in-product; a large left drag may hit the minimum width.
        XCTAssertLessThanOrEqual(leftDelta, -40, "Expected drag-left to move resizer left")
        XCTAssertGreaterThanOrEqual(leftDelta, -122, "Resizer moved farther than requested drag-left offset")
    }

    func testSidebarResizerHasMaximumWidthCap() {
        let app = XCUIApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5.0))

        let elements = app.descendants(matching: .any)
        let resizer = elements["SidebarResizer"]
        XCTAssertTrue(resizer.waitForExistence(timeout: 5.0))

        let start = resizer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let farRight = start.withOffset(CGVector(dx: 5000, dy: 0))
        start.press(forDuration: 0.1, thenDragTo: farRight)

        let windowFrame = window.frame
        let remainingWidth = max(0, windowFrame.maxX - resizer.frame.maxX)
        let minimumExpectedRemaining = windowFrame.width * 0.45

        XCTAssertGreaterThanOrEqual(
            remainingWidth,
            minimumExpectedRemaining,
            "Expected sidebar max-width clamp to leave substantial terminal width. " +
            "remaining=\(remainingWidth), window=\(windowFrame.width)"
        )
    }
}
