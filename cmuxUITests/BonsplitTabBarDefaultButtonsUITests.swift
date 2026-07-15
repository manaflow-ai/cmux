import XCTest

extension BonsplitTabDragUITests {
    func testDefaultPaneTabBarShowsMoreButtonAfterSplitButtons() {
        let (app, dataPath) = launchConfiguredApp(
            startWithHiddenSidebar: true,
            windowSize: "760x420"
        )

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: launchTimeout),
            "Expected app to launch for default action-lane UI test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(waitForAnyJSON(atPath: dataPath, timeout: setupTimeout), "Expected tab-drag setup data at \(dataPath)")
        guard let ready = waitForJSONKey("ready", equals: "1", atPath: dataPath, timeout: setupTimeout) else {
            XCTFail("Timed out waiting for ready=1. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }

        if let setupError = ready["setupError"], !setupError.isEmpty {
            XCTFail("Setup failed: \(setupError)")
            return
        }

        let window = app.windows.element(boundBy: 0)
        XCTAssertTrue(window.waitForExistence(timeout: 5.0), "Expected main window to exist")

        let alphaTitle = ready["alphaTitle"] ?? "UITest Alpha"
        let betaTitle = ready["betaTitle"] ?? "UITest Beta"
        let alphaTab = app.buttons[alphaTitle]
        let betaTab = app.buttons[betaTitle]
        XCTAssertTrue(alphaTab.waitForExistence(timeout: 5.0), "Expected alpha tab to exist")
        XCTAssertTrue(betaTab.waitForExistence(timeout: 5.0), "Expected beta tab to exist")

        let newTerminalButton = app.descendants(matching: .any)
            .matching(identifier: "paneTabBarControl.newTerminal")
            .firstMatch
        let newBrowserButton = app.descendants(matching: .any)
            .matching(identifier: "paneTabBarControl.newBrowser")
            .firstMatch
        let splitRightButton = app.descendants(matching: .any)
            .matching(identifier: "paneTabBarControl.splitRight")
            .firstMatch
        let splitDownButton = app.descendants(matching: .any)
            .matching(identifier: "paneTabBarControl.splitDown")
            .firstMatch
        let moreButton = app.descendants(matching: .any)
            .matching(identifier: "paneTabBarControl.custom.cmux.more")
            .firstMatch

        hover(
            in: window,
            at: CGPoint(
                x: min(window.frame.maxX - 140, betaTab.frame.maxX + 80),
                y: alphaTab.frame.midY
            )
        )

        XCTAssertTrue(
            waitForCondition(timeout: 2.0) {
                newTerminalButton.exists && newTerminalButton.isHittable &&
                    newBrowserButton.exists && newBrowserButton.isHittable &&
                    splitRightButton.exists && splitRightButton.isHittable &&
                    splitDownButton.exists && splitDownButton.isHittable &&
                    moreButton.exists && moreButton.isHittable
            },
            "Expected the default pane tab bar controls, including More, to be hittable. terminal=\(newTerminalButton.debugDescription) browser=\(newBrowserButton.debugDescription) splitRight=\(splitRightButton.debugDescription) splitDown=\(splitDownButton.debugDescription) more=\(moreButton.debugDescription)"
        )
        XCTAssertGreaterThanOrEqual(
            moreButton.frame.width,
            8,
            "Expected More button to render with visible width while preserving compact tab-bar button spacing. more=\(moreButton.debugDescription)"
        )
        XCTAssertLessThan(splitDownButton.frame.minX, moreButton.frame.minX, "Expected More to appear after the split buttons")
        XCTAssertLessThanOrEqual(
            moreButton.frame.maxX,
            window.frame.maxX + 1,
            "Expected More to stay inside the window. window=\(window.frame) more=\(moreButton.frame)"
        )
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        // On busy UI runners the app can launch backgrounded; activate once before failing.
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }
}
