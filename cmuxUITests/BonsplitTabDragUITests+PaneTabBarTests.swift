import XCTest
import Foundation
import CoreGraphics


// MARK: - Pane Tab Bar Tests
extension BonsplitTabDragUITests {
    func testMinimalModeKeepsTabReorderWorking() {
        let (app, dataPath) = launchConfiguredApp()

        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: launchTimeout),
            "Expected app to launch for minimal-mode Bonsplit tab drag UI test. state=\(app.state.rawValue)"
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

        let alphaTitle = ready["alphaTitle"] ?? "UITest Alpha"
        let betaTitle = ready["betaTitle"] ?? "UITest Beta"
        let window = app.windows.element(boundBy: 0)
        let alphaTab = app.buttons[alphaTitle]
        let betaTab = app.buttons[betaTitle]
        let initialOrder = "\(alphaTitle)|\(betaTitle)"
        let reorderedOrder = "\(betaTitle)|\(alphaTitle)"

        XCTAssertTrue(window.waitForExistence(timeout: 5.0), "Expected main window to exist")
        XCTAssertTrue(alphaTab.waitForExistence(timeout: 5.0), "Expected alpha tab to exist")
        XCTAssertTrue(betaTab.waitForExistence(timeout: 5.0), "Expected beta tab to exist")
        XCTAssertTrue(
            waitForJSONKey("trackedPaneTabTitles", equals: initialOrder, atPath: dataPath, timeout: 5.0) != nil,
            "Expected initial tracked tab order to be \(initialOrder). data=\(loadJSON(atPath: dataPath) ?? [:])"
        )
        XCTAssertLessThan(alphaTab.frame.minX, betaTab.frame.minX, "Expected beta tab to start to the right of alpha")
        let windowFrameBeforeDrag = window.frame

        dragTab(betaTab, before: alphaTab)

        XCTAssertTrue(
            waitForJSONKey("trackedPaneTabTitles", equals: reorderedOrder, atPath: dataPath, timeout: 5.0) != nil,
            "Expected tracked tab order to become \(reorderedOrder). data=\(loadJSON(atPath: dataPath) ?? [:])"
        )
        XCTAssertTrue(
            waitForCondition(timeout: 5.0) { betaTab.frame.minX < alphaTab.frame.minX },
            "Expected dragging beta onto alpha to reorder tab frames. alpha=\(alphaTab.frame) beta=\(betaTab.frame)"
        )
        XCTAssertEqual(window.frame.origin.x, windowFrameBeforeDrag.origin.x, accuracy: 2.0, "Expected tab drag not to move the window horizontally")
        XCTAssertEqual(window.frame.origin.y, windowFrameBeforeDrag.origin.y, accuracy: 2.0, "Expected tab drag not to move the window vertically")
    }

    func testMinimalModePlacesPaneTabBarAtTopEdge() {
        let (app, dataPath) = launchConfiguredApp()

        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: launchTimeout),
            "Expected app to launch for minimal-mode top-gap UI test. state=\(app.state.rawValue)"
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
        let alphaTab = app.buttons[alphaTitle]
        XCTAssertTrue(alphaTab.waitForExistence(timeout: 5.0), "Expected alpha tab to exist")

        let gapIfOriginIsBottomLeft = abs(window.frame.maxY - alphaTab.frame.maxY)
        let gapIfOriginIsTopLeft = abs(alphaTab.frame.minY - window.frame.minY)
        let topGap = min(gapIfOriginIsBottomLeft, gapIfOriginIsTopLeft)
        XCTAssertLessThanOrEqual(
            topGap,
            8,
            "Expected the selected pane tab to reach the top edge in minimal mode. window=\(window.frame) alphaTab=\(alphaTab.frame) gap.bottomLeft=\(gapIfOriginIsBottomLeft) gap.topLeft=\(gapIfOriginIsTopLeft)"
        )
    }

    func testMinimalModeCollapsedSidebarStillRevealsPaneTabBarControlsOnHover() {
        let (app, dataPath) = launchConfiguredApp(startWithHiddenSidebar: true)

        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: launchTimeout),
            "Expected app to launch for collapsed-sidebar minimal-mode Bonsplit controls hover UI test. state=\(app.state.rawValue)"
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
        XCTAssertTrue(alphaTab.waitForExistence(timeout: 5.0), "Expected alpha tab to exist")
        let betaTab = app.buttons[betaTitle]
        XCTAssertTrue(betaTab.waitForExistence(timeout: 5.0), "Expected beta tab to exist")

        let newTerminalButton = app.descendants(matching: .any).matching(identifier: "paneTabBarControl.newTerminal").firstMatch

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).hover()
        XCTAssertTrue(
            waitForCondition(timeout: 2.0) { !newTerminalButton.exists || !newTerminalButton.isHittable },
            "Expected pane tab bar controls to hide away from the pane tab bar in minimal mode. button=\(newTerminalButton.debugDescription)"
        )

        hover(
            in: window,
            at: CGPoint(
                x: min(window.frame.maxX - 140, betaTab.frame.maxX + 80),
                y: alphaTab.frame.midY
            )
        )
        XCTAssertTrue(
            waitForCondition(timeout: 2.0) { newTerminalButton.exists && newTerminalButton.isHittable },
            "Expected pane tab bar controls to reveal when hovering inside empty pane-tab-bar space in collapsed-sidebar minimal mode. window=\(window.frame) alphaTab=\(alphaTab.frame) betaTab=\(betaTab.frame) button=\(newTerminalButton.debugDescription)"
        )

        newTerminalButton.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(
            waitForJSONNumber("trackedPaneTabCount", greaterThan: 2, atPath: dataPath, timeout: 5.0) != nil,
            "Expected the revealed pane tab bar new-terminal button to remain clickable in collapsed-sidebar minimal mode. data=\(loadJSON(atPath: dataPath) ?? [:]) button=\(newTerminalButton.debugDescription)"
        )

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).hover()
        XCTAssertTrue(
            waitForCondition(timeout: 2.0) { !newTerminalButton.exists || !newTerminalButton.isHittable },
            "Expected pane tab bar controls to hide again after leaving the pane tab bar in minimal mode. button=\(newTerminalButton.debugDescription)"
        )
    }

    func testManyPaneTabBarActionsUseTrailingWhitespaceBeforeClipping() {
        let actionButtonCount = 10
        let (app, dataPath) = launchConfiguredApp(
            startWithHiddenSidebar: true,
            windowSize: "760x420",
            actionButtonCount: actionButtonCount
        )

        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: launchTimeout),
            "Expected app to launch for narrow action-lane UI test. state=\(app.state.rawValue)"
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

        let firstActionButton = app.descendants(matching: .any)
            .matching(identifier: "paneTabBarControl.custom.cmux-ui-test-action-1")
            .firstMatch
        let lastActionButton = app.descendants(matching: .any)
            .matching(identifier: "paneTabBarControl.custom.cmux-ui-test-action-\(actionButtonCount)")
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
                firstActionButton.exists && firstActionButton.isHittable &&
                    lastActionButton.exists && lastActionButton.isHittable
            },
            "Expected all custom pane tab bar action buttons to be hittable in trailing whitespace. window=\(window.frame) alphaTab=\(alphaTab.frame) betaTab=\(betaTab.frame) first=\(firstActionButton.debugDescription) last=\(lastActionButton.debugDescription)"
        )
        XCTAssertLessThan(
            firstActionButton.frame.minX,
            lastActionButton.frame.minX,
            "Expected custom action buttons to lay out in configured order. first=\(firstActionButton.frame) last=\(lastActionButton.frame)"
        )
        XCTAssertLessThanOrEqual(
            lastActionButton.frame.maxX,
            window.frame.maxX + 1,
            "Expected the rightmost custom action button to stay inside the window. window=\(window.frame) last=\(lastActionButton.frame)"
        )
    }

}
