import XCTest

final class SidebarResizeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testSidebarResizerTracksCursor() {
        let app = XCUIApplication()
        XCTAssertTrue(
            launchAndAllowBackground(app),
            "Expected app to launch and reach foreground before resizing sidebar"
        )

        let elements = app.descendants(matching: .any)
        let resizer = elements["SidebarResizer"]
        XCTAssertTrue(resizer.waitForExistence(timeout: 5.0))
        XCTAssertTrue(waitForElementHittable(resizer, timeout: 5.0), "Expected sidebar resizer to become hittable")

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

    func testSidebarResizerAllowsSmallerMinimumWidth() {
        let app = XCUIApplication()
        XCTAssertTrue(
            launchAndAllowBackground(app),
            "Expected app to launch and reach foreground before resizing sidebar"
        )

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5.0))

        let elements = app.descendants(matching: .any)
        let resizer = elements["SidebarResizer"]
        XCTAssertTrue(resizer.waitForExistence(timeout: 5.0))
        XCTAssertTrue(waitForElementHittable(resizer, timeout: 5.0), "Expected sidebar resizer to become hittable")

        let start = resizer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let farLeft = start.withOffset(CGVector(dx: -max(200, window.frame.width), dy: 0))
        start.press(forDuration: 0.1, thenDragTo: farLeft)

        let sidebarWidth = max(0, resizer.frame.midX - window.frame.minX)
        XCTAssertLessThanOrEqual(
            sidebarWidth,
            185,
            "Expected sidebar minimum width to allow a narrower sidebar than the previous 186 px floor. width=\(sidebarWidth)"
        )
    }

    func testSidebarResizerHasMaximumWidthCap() {
        let app = XCUIApplication()
        XCTAssertTrue(
            launchAndAllowBackground(app),
            "Expected app to launch and reach foreground before resizing sidebar"
        )

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5.0))

        let elements = app.descendants(matching: .any)
        let resizer = elements["SidebarResizer"]
        XCTAssertTrue(resizer.waitForExistence(timeout: 5.0))
        XCTAssertTrue(waitForElementHittable(resizer, timeout: 5.0), "Expected sidebar resizer to become hittable")

        let start = resizer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let farRight = start.withOffset(CGVector(dx: max(1200, window.frame.width * 2.0), dy: 0))
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

    private func waitForElementHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard element.exists, element.isHittable else { return false }
                let frame = element.frame
                return frame.width > 1 && frame.height > 1
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func launchAndAllowBackground(_ app: XCUIApplication) -> Bool {
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"

        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }

        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 5.0)
        }
        return app.state == .runningForeground || app.wait(for: .runningForeground, timeout: 5.0)
    }
}
