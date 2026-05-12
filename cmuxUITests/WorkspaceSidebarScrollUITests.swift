import XCTest

final class WorkspaceSidebarScrollUITests: XCTestCase {
    private let topTitlebarWorkspaceClearance: CGFloat = 32
    private let maxSidebarOverflowWorkspaceCount = 80

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testWorkspaceSelectionKeepsSidebarRowVisible() {
        let app = XCUIApplication()
        configureLaunch(app)
        launchAndEnsureRunning(app)
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 8.0), "Expected a main window")
        XCTAssertTrue(
            waitForWorkspaceRowHittable(index: 1, count: 1, app: app, timeout: 8.0),
            "Expected the initial workspace row to be visible"
        )

        let workspaceCount = 20
        for expectedCount in 2...workspaceCount {
            app.typeKey("n", modifierFlags: [.command])
            XCTAssertTrue(
                waitForWorkspaceRowHittable(index: expectedCount, count: expectedCount, app: app, timeout: 6.0),
                "Expected the newly selected workspace \(expectedCount) to be visible"
            )
        }

        XCTAssertTrue(
            waitForWorkspaceRowHittable(index: workspaceCount, count: workspaceCount, app: app, timeout: 6.0),
            "Expected the newly selected bottom workspace to be visible"
        )

        app.typeKey("1", modifierFlags: [.command])
        XCTAssertTrue(
            waitForWorkspaceRowHittable(index: 1, count: workspaceCount, app: app, timeout: 6.0),
            "Expected Cmd+1 to scroll the first workspace back into view"
        )
        XCTAssertTrue(
            waitForWorkspaceRowClearsTitlebar(index: 1, count: workspaceCount, app: app, timeout: 6.0),
            "Expected Cmd+1 to keep the first workspace below the titlebar controls"
        )
    }

    func testSidebarScrollerVisibilityFollowsWorkspaceOverflow() {
        let app = XCUIApplication()
        configureLaunch(app)
        launchAndEnsureRunning(app)
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 8.0), "Expected a main window")
        XCTAssertTrue(
            waitForWorkspaceRowHittable(index: 1, count: 1, app: app, timeout: 8.0),
            "Expected the initial workspace row to be visible"
        )

        let sidebar = app.descendants(matching: .any)["Sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5.0), "Expected the workspace sidebar to exist")
        XCTAssertTrue(
            waitForSidebarVerticalScrollerHidden(app: app, sidebar: sidebar, timeout: 4.0),
            "Expected the sidebar scroller to hide when the workspace content fits"
        )

        let overflowProbeStartCount = sidebarOverflowProbeStartCount(app: app, sidebar: sidebar)
        var overflowReached = false
        for expectedCount in 2...maxSidebarOverflowWorkspaceCount {
            app.typeKey("n", modifierFlags: [.command])
            XCTAssertTrue(
                waitForWorkspaceRowHittable(index: expectedCount, count: expectedCount, app: app, timeout: 6.0),
                "Expected the newly selected workspace \(expectedCount) to be visible"
            )

            guard expectedCount >= overflowProbeStartCount else { continue }
            if revealSidebarVerticalScroller(app: app, sidebar: sidebar, timeout: 1.0) {
                overflowReached = true
                break
            }
        }

        XCTAssertTrue(
            overflowReached,
            "Expected the sidebar scroller to appear before creating \(maxSidebarOverflowWorkspaceCount) workspaces"
        )
    }

    private func configureLaunch(_ app: XCUIApplication) {
        app.launchArguments += ["-newWorkspacePlacement", "end"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-sidebar-scroll"
    }

    private func waitForWorkspaceRowHittable(
        index: Int,
        count: Int,
        app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        return pollUntil(timeout: timeout) {
            let row = workspaceRow(index: index, count: count, app: app)
            return row.exists && row.isHittable
        }
    }

    private func waitForWorkspaceRowClearsTitlebar(
        index: Int,
        count: Int,
        app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        pollUntil(timeout: timeout) {
            let row = workspaceRow(index: index, count: count, app: app)
            let window = app.windows.firstMatch
            guard row.exists, row.isHittable, window.exists else { return false }
            return row.frame.minY >= window.frame.minY + topTitlebarWorkspaceClearance
        }
    }

    private func workspaceRow(index: Int, count: Int, app: XCUIApplication) -> XCUIElement {
        let position = "workspace \(index) of \(count)"
        return app.descendants(matching: .other)
            .matching(NSPredicate(format: "label ENDSWITH %@", position))
            .firstMatch
    }

    private func sidebarOverflowProbeStartCount(app: XCUIApplication, sidebar: XCUIElement) -> Int {
        let firstRow = workspaceRow(index: 1, count: 1, app: app)
        guard sidebar.exists, firstRow.exists else { return 8 }

        let rowHeight = max(firstRow.frame.height, 1)
        let visibleRows = Int(ceil(sidebar.frame.height / rowHeight))
        return min(maxSidebarOverflowWorkspaceCount, max(3, visibleRows + 1))
    }

    private func waitForWindowCount(atLeast count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            app.windows.count >= count
        }
    }

    private func waitForSidebarVerticalScrollerHidden(
        app: XCUIApplication,
        sidebar: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        pollUntil(timeout: timeout) {
            visibleSidebarVerticalScrollers(app: app, sidebar: sidebar).isEmpty
        }
    }

    private func waitForSidebarVerticalScrollerVisible(
        app: XCUIApplication,
        sidebar: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        pollUntil(timeout: timeout) {
            !visibleSidebarVerticalScrollers(app: app, sidebar: sidebar).isEmpty
        }
    }

    private func revealSidebarVerticalScroller(
        app: XCUIApplication,
        sidebar: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        sidebar.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).hover()
        if waitForSidebarVerticalScrollerVisible(app: app, sidebar: sidebar, timeout: min(0.25, timeout)) {
            return true
        }
        sidebar.swipeUp()
        return waitForSidebarVerticalScrollerVisible(app: app, sidebar: sidebar, timeout: timeout)
    }

    private func visibleSidebarVerticalScrollers(
        app: XCUIApplication,
        sidebar: XCUIElement
    ) -> [XCUIElement] {
        guard sidebar.exists else { return [] }
        let sidebarFrame = sidebar.frame
        return app.descendants(matching: .scrollBar).allElementsBoundByIndex.filter { scroller in
            guard scroller.exists, scroller.isHittable else { return false }
            let frame = scroller.frame
            guard frame.width > 0, frame.height > frame.width else { return false }
            return frame.midX >= sidebarFrame.minX
                && frame.midX <= sidebarFrame.maxX
                && frame.maxY > sidebarFrame.minY
                && frame.minY < sidebarFrame.maxY
        }
    }

    private func launchAndEnsureRunning(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("Headless CI may launch the app without foreground activation", options: options) {
            app.launch()
        }
        XCTAssertTrue(
            pollUntil(timeout: 10.0) {
                app.state == .runningForeground || app.state == .runningBackground
            },
            "App failed to launch. state=\(app.state.rawValue)"
        )
    }

    private func pollUntil(
        timeout: TimeInterval,
        interval: TimeInterval = 0.05,
        condition: () -> Bool
    ) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        while true {
            if condition() {
                return true
            }
            if ProcessInfo.processInfo.systemUptime - start >= timeout {
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        }
    }
}
