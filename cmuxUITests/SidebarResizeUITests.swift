import XCTest

final class SidebarResizeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testSidebarResizerTracksCursor() {
        let app = XCUIApplication.cmuxTestApplication()
        app.launch()

        let elements = app.descendants(matching: .any)
        let resizer = elements["SidebarResizer"]
        let columnResizer = elements["SidebarColumnResizer"]
        XCTAssertTrue(resizer.waitForExistence(timeout: 5.0))
        XCTAssertTrue(columnResizer.waitForExistence(timeout: 5.0))
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
        let app = XCUIApplication.cmuxTestApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5.0))

        let elements = app.descendants(matching: .any)
        let resizer = elements["SidebarResizer"]
        let columnResizer = elements["SidebarColumnResizer"]
        XCTAssertTrue(resizer.waitForExistence(timeout: 5.0))
        XCTAssertTrue(columnResizer.waitForExistence(timeout: 5.0))
        XCTAssertTrue(waitForElementHittable(resizer, timeout: 5.0), "Expected sidebar resizer to become hittable")

        let start = resizer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let farLeft = start.withOffset(CGVector(dx: -max(200, window.frame.width), dy: 0))
        start.press(forDuration: 0.1, thenDragTo: farLeft)

        let sidebarWidth = max(0, resizer.frame.midX - columnResizer.frame.midX)
        XCTAssertLessThanOrEqual(
            sidebarWidth,
            185,
            "Expected the workspace column minimum to allow a narrower width than the previous 186 px floor. width=\(sidebarWidth)"
        )
    }

    func testSidebarColumnsResizeIndependentlyAndToggleTogether() {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_UI_TEST_SIDEBAR_MACHINE_SCOPES"] = "1"
        launchAllowingBackgroundActivation(app)

        let elements = app.descendants(matching: .any)
        let outerResizer = elements["SidebarResizer"]
        let columnResizer = elements["SidebarColumnResizer"]
        let contextColumn = elements["SidebarContextColumn"]
        let automaticContext = elements["SidebarContextRow.automatic"]
        let localContext = elements["SidebarContextRow.local"]
        let automaticChildColumn = elements["SidebarChildColumn.automatic.children"]
        let workspaceColumn = elements["Sidebar"]
        let remoteContext = app.buttons["fixture@example.test"]
        let localWorkspace = app.cells.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Local Fixture, workspace")
        ).firstMatch
        let remoteWorkspace = app.cells.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Remote Fixture, workspace")
        ).firstMatch
        let footer = elements["SidebarHelpMenuButton"]
        XCTAssertTrue(waitForElementHittable(outerResizer, timeout: 5.0))
        XCTAssertTrue(waitForElementHittable(columnResizer, timeout: 5.0))
        XCTAssertTrue(contextColumn.waitForExistence(timeout: 5.0))
        XCTAssertTrue(automaticContext.waitForExistence(timeout: 5.0))
        XCTAssertTrue(localContext.waitForExistence(timeout: 5.0))
        XCTAssertTrue(automaticChildColumn.waitForExistence(timeout: 5.0))
        XCTAssertTrue(workspaceColumn.waitForExistence(timeout: 5.0))
        XCTAssertTrue(remoteContext.waitForExistence(timeout: 5.0))
        XCTAssertTrue(localWorkspace.waitForExistence(timeout: 5.0))
        XCTAssertTrue(remoteWorkspace.waitForExistence(timeout: 5.0))
        XCTAssertTrue(footer.waitForExistence(timeout: 5.0))
        XCTAssertLessThan(
            automaticContext.frame.minY - contextColumn.frame.minY,
            48,
            "Creation contexts should start in the standard sidebar row band without a machine-only header"
        )
        XCTAssertFalse(app.staticTexts["Machines"].exists)
        XCTAssertFalse(app.staticTexts["Sets defaults for ⌘N and ⌘T"].exists)
        XCTAssertGreaterThanOrEqual(
            columnResizer.frame.midX - contextColumn.frame.minX,
            166,
            "The leading column should keep enough width for shared footer chrome"
        )
        XCTAssertGreaterThanOrEqual(footer.frame.minX, contextColumn.frame.minX - 2)
        XCTAssertLessThanOrEqual(
            footer.frame.maxX,
            contextColumn.frame.maxX + 2,
            "The shared footer should stay inside the left-most column"
        )

        localContext.click()
        XCTAssertTrue(
            elements["SidebarChildColumn.local.children"].waitForExistence(timeout: 5.0),
            "Each machine should activate its own child-column route"
        )
        XCTAssertTrue(
            localWorkspace.waitForExistence(timeout: 5.0),
            "This Mac should render its local workspace child"
        )
        XCTAssertTrue(
            waitForElementUnavailable(remoteWorkspace, timeout: 5.0),
            "This Mac must not render the remote machine's workspace child"
        )

        remoteContext.click()
        XCTAssertTrue(
            remoteWorkspace.waitForExistence(timeout: 5.0),
            "The remote should render its own workspace child"
        )
        XCTAssertTrue(
            waitForElementUnavailable(localWorkspace, timeout: 5.0),
            "The remote must not render This Mac's workspace child"
        )
        automaticContext.click()
        XCTAssertTrue(automaticChildColumn.waitForExistence(timeout: 5.0))
        XCTAssertTrue(localWorkspace.waitForExistence(timeout: 5.0))
        XCTAssertTrue(remoteWorkspace.waitForExistence(timeout: 5.0))

        let initialInnerX = columnResizer.frame.midX
        let initialOuterX = outerResizer.frame.midX
        let initialWorkspaceWidth = initialOuterX - initialInnerX

        let innerStart = columnResizer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        innerStart.press(
            forDuration: 0.1,
            thenDragTo: innerStart.withOffset(CGVector(dx: 48, dy: 0))
        )

        let afterInnerX = columnResizer.frame.midX
        let outerAfterInnerX = outerResizer.frame.midX
        XCTAssertGreaterThan(afterInnerX - initialInnerX, 24)
        XCTAssertEqual(
            outerAfterInnerX - afterInnerX,
            initialWorkspaceWidth,
            accuracy: 12,
            "Resizing the machine column should preserve the workspace column width"
        )

        let outerStart = outerResizer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        outerStart.press(
            forDuration: 0.1,
            thenDragTo: outerStart.withOffset(CGVector(dx: 56, dy: 0))
        )

        XCTAssertEqual(
            columnResizer.frame.midX,
            afterInnerX,
            accuracy: 12,
            "Resizing the workspace column should preserve the machine column width"
        )
        XCTAssertGreaterThan(
            outerResizer.frame.midX - outerAfterInnerX,
            28,
            "Expected the workspace column's outer edge to move independently"
        )

        app.typeKey("b", modifierFlags: .command)
        XCTAssertTrue(waitForElementUnavailable(columnResizer, timeout: 5.0))
        XCTAssertTrue(waitForElementUnavailable(outerResizer, timeout: 5.0))
        XCTAssertTrue(waitForElementUnavailable(contextColumn, timeout: 5.0))
        XCTAssertTrue(waitForElementUnavailable(workspaceColumn, timeout: 5.0))
        XCTAssertTrue(waitForElementUnavailable(footer, timeout: 5.0))

        app.typeKey("b", modifierFlags: .command)
        XCTAssertTrue(waitForElementHittable(columnResizer, timeout: 5.0))
        XCTAssertTrue(waitForElementHittable(outerResizer, timeout: 5.0))
        XCTAssertTrue(contextColumn.waitForExistence(timeout: 5.0))
        XCTAssertTrue(workspaceColumn.waitForExistence(timeout: 5.0))
        XCTAssertTrue(footer.waitForExistence(timeout: 5.0))
    }

    func testSidebarMachineContextMenuAddsSSHMachineAndOffersRemoteAttach() {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_UI_TEST_SIDEBAR_MACHINE_SCOPES"] = "1"
        launchAllowingBackgroundActivation(app)

        let localContext = app.descendants(matching: .any)["SidebarContextRow.local"]
        XCTAssertTrue(localContext.waitForExistence(timeout: 5.0))

        localContext.rightClick()
        let addSSHMachine = app.menuItems["Add Machine via SSH…"]
        XCTAssertTrue(addSSHMachine.waitForExistence(timeout: 5.0))
        addSSHMachine.click()

        let alert = app.alerts["Add Machine via SSH"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5.0))
        let destination = alert.textFields["SidebarAddSSHMachineDestination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5.0))
        destination.typeText("builder@example.test")
        alert.buttons["Add Machine"].click()

        let addedMachine = app.buttons["builder@example.test"]
        XCTAssertTrue(
            addedMachine.waitForExistence(timeout: 5.0),
            "A durable machine should render before it owns any workspace children"
        )

        addedMachine.rightClick()
        XCTAssertTrue(
            app.menuItems["Attach cmux TUI"].waitForExistence(timeout: 5.0),
            "SSH machines should advertise their remote-session capability on the shared row UI"
        )
    }

    func testSidebarResizerHasMaximumWidthCap() {
        let app = XCUIApplication.cmuxTestApplication()
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

    private func launchAllowingBackgroundActivation(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }
        XCTAssertTrue(
            app.state == .runningForeground || app.state == .runningBackground,
            "Expected cmux to be running after launch. state=\(app.state.rawValue)"
        )
    }

    private func waitForElementUnavailable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !element.exists || !element.isHittable },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
