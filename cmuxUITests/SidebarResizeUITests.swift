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
        app.launch()

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
        app.launch()

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

    func testBothSidebarResizersStayInsideNarrowWindow() {
        let app = XCUIApplication()
        let dataPath = "/tmp/cmux-ui-test-sidebar-resize-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)

        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_WINDOW_SIZE"] = "320x420"
        app.launchArguments += ["-workspacePresentationMode", "minimal"]
        addTeardownBlock {
            app.terminate()
            try? FileManager.default.removeItem(atPath: dataPath)
        }

        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }

        XCTAssertTrue(ensureForegroundAfterLaunch(app, timeout: 8.0))
        XCTAssertNotNil(waitForJSONKey("ready", equals: "1", atPath: dataPath, timeout: 8.0))

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5.0))

        let elements = app.descendants(matching: .any)
        let leftSidebar = elements.matching(identifier: "Sidebar").firstMatch
        let rightSidebar = elements.matching(identifier: "RightSidebar").firstMatch
        let leftResizer = elements.matching(identifier: "SidebarResizer").firstMatch
        let rightResizer = elements.matching(identifier: "RightSidebarResizer").firstMatch

        XCTAssertTrue(leftSidebar.waitForExistence(timeout: 5.0))
        XCTAssertTrue(rightSidebar.waitForExistence(timeout: 5.0))
        XCTAssertTrue(leftResizer.waitForExistence(timeout: 5.0))
        XCTAssertTrue(rightResizer.waitForExistence(timeout: 5.0))
        XCTAssertTrue(waitForElementHittable(leftResizer, timeout: 5.0))
        XCTAssertTrue(waitForElementHittable(rightResizer, timeout: 5.0))

        XCTAssertGreaterThan(leftSidebar.frame.width, 1)
        XCTAssertGreaterThan(rightSidebar.frame.width, 1)
        assertElementDoesNotLeaveLeadingScreenEdge(leftSidebar, name: "left sidebar")
        assertElementFrame(rightSidebar, isInside: window, name: "right sidebar")
        assertElementDoesNotLeaveLeadingScreenEdge(leftResizer, name: "left resizer")
        assertElementFrame(rightResizer, isInside: window, name: "right resizer")
        XCTAssertLessThan(
            leftResizer.frame.maxX,
            rightResizer.frame.minX,
            "Expected narrow-window resizers to remain separately hittable. " +
            "left=\(leftResizer.frame), right=\(rightResizer.frame)"
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

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        if app.state == .runningBackground {
            app.activate()
            if app.wait(for: .runningForeground, timeout: 6.0) {
                return true
            }
            return app.windows.firstMatch.waitForExistence(timeout: 6.0)
        }
        return app.windows.firstMatch.exists
    }

    private func waitForJSONKey(
        _ key: String,
        equals expected: String,
        atPath path: String,
        timeout: TimeInterval
    ) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadJSON(atPath: path), data[key] == expected {
                return data
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadJSON(atPath: path), data[key] == expected {
            return data
        }
        return nil
    }

    private func loadJSON(atPath path: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }

    private func assertElementFrame(
        _ element: XCUIElement,
        isInside window: XCUIElement,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tolerance: CGFloat = 1
        let frame = element.frame
        let windowFrame = window.frame
        XCTAssertGreaterThanOrEqual(
            frame.minX,
            windowFrame.minX - tolerance,
            "Expected \(name) to stay inside the window. element=\(frame), window=\(windowFrame)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            frame.maxX,
            windowFrame.maxX + tolerance,
            "Expected \(name) to stay inside the window. element=\(frame), window=\(windowFrame)",
            file: file,
            line: line
        )
    }

    private func assertElementDoesNotLeaveLeadingScreenEdge(
        _ element: XCUIElement,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frame = element.frame
        XCTAssertGreaterThanOrEqual(
            frame.minX,
            -1,
            "Expected \(name) to stay on screen. element=\(frame)",
            file: file,
            line: line
        )
    }
}
