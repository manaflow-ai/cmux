import XCTest
import Foundation
import CoreGraphics


// MARK: - Sidebar Workspace Controls Tests
extension BonsplitTabDragUITests {
    func testSidebarWorkspaceRowsKeepStableTopInsetAcrossPresentationModes() {
        let expectedTopInset: CGFloat = 32

        for presentationMode in [WorkspacePresentationMode.minimal, .standard] {
            let (app, dataPath) = launchConfiguredApp(presentationMode: presentationMode)
            defer { app.terminate() }

            XCTAssertTrue(
                ensureAppRunningAfterLaunch(app, timeout: launchTimeout),
                "Expected app to launch for \(presentationMode.rawValue)-mode sidebar inset UI test. state=\(app.state.rawValue)"
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

            let workspaceId = ready["workspaceId"] ?? ""
            let workspaceRowIdentifier = "sidebarWorkspace.\(workspaceId)"
            let workspaceRow = app.descendants(matching: .any).matching(identifier: workspaceRowIdentifier).firstMatch
            XCTAssertTrue(workspaceRow.waitForExistence(timeout: 5.0), "Expected workspace row to exist")

            let topInset = distanceToTopEdge(of: workspaceRow, in: window)
            XCTAssertEqual(
                topInset,
                expectedTopInset,
                accuracy: 4,
                "Expected \(presentationMode.rawValue) mode sidebar workspace rows to stay at the same fixed top inset. window=\(window.frame) workspaceRow=\(workspaceRow.frame) topInset=\(topInset)"
            )
        }
    }

    func testStandardModeKeepsWorkspaceControlsOutOfSidebar() {
        let (app, dataPath) = launchConfiguredApp(presentationMode: .standard)

        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: launchTimeout),
            "Expected app to launch for standard-mode sidebar control placement UI test. state=\(app.state.rawValue)"
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

        let sidebar = app.descendants(matching: .any).matching(identifier: "Sidebar").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5.0), "Expected sidebar to exist")

        let toggleSidebarButton = app.descendants(matching: .any).matching(identifier: "titlebarControl.toggleSidebar").firstMatch
        let notificationsButton = app.descendants(matching: .any).matching(identifier: "titlebarControl.showNotifications").firstMatch
        let newWorkspaceButton = app.descendants(matching: .any).matching(identifier: "titlebarControl.newTab").firstMatch

        XCTAssertTrue(
            waitForCondition(timeout: 2.0) {
                toggleSidebarButton.exists && toggleSidebarButton.isHittable &&
                    notificationsButton.exists && notificationsButton.isHittable &&
                    newWorkspaceButton.exists && newWorkspaceButton.isHittable
            },
            "Expected standard mode to keep workspace controls visible in the titlebar."
        )

        let lowestControlY = max(
            toggleSidebarButton.frame.maxY,
            notificationsButton.frame.maxY,
            newWorkspaceButton.frame.maxY
        )
        XCTAssertLessThanOrEqual(
            lowestControlY,
            sidebar.frame.minY + 4,
            "Expected standard mode workspace controls to stay in the titlebar above the sidebar list. sidebar=\(sidebar.frame) toggle=\(toggleSidebarButton.frame) notifications=\(notificationsButton.frame) new=\(newWorkspaceButton.frame)"
        )
    }

    func testMinimalModeSidebarControlsRevealOnlyFromSidebarHover() {
        let (app, dataPath) = launchConfiguredApp()

        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: launchTimeout),
            "Expected app to launch for minimal-mode sidebar hover UI test. state=\(app.state.rawValue)"
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

        let sidebar = app.descendants(matching: .any).matching(identifier: "Sidebar").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5.0), "Expected sidebar to exist")

        let toggleSidebarButton = app.descendants(matching: .any).matching(identifier: "titlebarControl.toggleSidebar").firstMatch
        let notificationsButton = app.descendants(matching: .any).matching(identifier: "titlebarControl.showNotifications").firstMatch
        let newWorkspaceButton = app.descendants(matching: .any).matching(identifier: "titlebarControl.newTab").firstMatch

        let alphaTitle = ready["alphaTitle"] ?? "UITest Alpha"
        let alphaTab = app.buttons[alphaTitle]
        XCTAssertTrue(alphaTab.waitForExistence(timeout: 5.0), "Expected alpha tab to exist")

        let paneLeadingGap = alphaTab.frame.minX - sidebar.frame.maxX
        XCTAssertLessThan(
            paneLeadingGap,
            28,
            "Expected visible-sidebar minimal mode to keep pane tabs tight to the sidebar edge while the traffic lights sit over the sidebar. window=\(window.frame) sidebar=\(sidebar.frame) alphaTab=\(alphaTab.frame) paneLeadingGap=\(paneLeadingGap)"
        )

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).hover()
        XCTAssertTrue(
            waitForCondition(timeout: 2.0) {
                !toggleSidebarButton.isHittable && !notificationsButton.isHittable && !newWorkspaceButton.isHittable
            },
            "Expected minimal-mode sidebar controls to stay hidden away from the sidebar hover zone."
        )

        hover(in: window, at: CGPoint(x: window.frame.maxX - 48, y: window.frame.minY + 18))
        XCTAssertTrue(
            waitForCondition(timeout: 2.0) {
                !toggleSidebarButton.isHittable && !notificationsButton.isHittable && !newWorkspaceButton.isHittable
            },
            "Expected the removed titlebar area to stop revealing minimal-mode controls."
        )

        hover(
            in: window,
            at: CGPoint(
                x: min(sidebar.frame.maxX - 36, sidebar.frame.minX + 116),
                y: window.frame.minY + 18
            )
        )
        XCTAssertTrue(
            waitForCondition(timeout: 2.0) {
                toggleSidebarButton.exists && toggleSidebarButton.isHittable &&
                    notificationsButton.exists && notificationsButton.isHittable &&
                    newWorkspaceButton.exists && newWorkspaceButton.isHittable
            },
            "Expected minimal-mode sidebar controls to become hittable after hovering the sidebar chrome."
        )
        notificationsButton.click()
        XCTAssertTrue(
            app.buttons["notificationsPopover.jumpToLatest"].waitForExistence(timeout: 6.0)
                || app.staticTexts["No notifications yet"].waitForExistence(timeout: 6.0),
            "Expected clicking the revealed sidebar notifications control to open the notifications popover. data=\(loadJSON(atPath: dataPath) ?? [:]) toggle=\(toggleSidebarButton.debugDescription) notifications=\(notificationsButton.debugDescription) new=\(newWorkspaceButton.debugDescription)"
        )
    }

    func testMinimalModeCollapsedSidebarKeepsWorkspaceControlsSuppressed() {
        let (app, dataPath) = launchConfiguredApp(startWithHiddenSidebar: true)

        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: launchTimeout),
            "Expected app to launch for collapsed-sidebar minimal-mode controls UI test. state=\(app.state.rawValue)"
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

        XCTAssertEqual(ready["sidebarVisible"], "0", "Expected hidden-sidebar UI test setup to collapse the sidebar. data=\(ready)")

        let window = app.windows.element(boundBy: 0)
        XCTAssertTrue(window.waitForExistence(timeout: 5.0), "Expected main window to exist")

        let alphaTitle = ready["alphaTitle"] ?? "UITest Alpha"
        let alphaTab = app.buttons[alphaTitle]
        XCTAssertTrue(alphaTab.waitForExistence(timeout: 5.0), "Expected alpha tab to exist")

        let toggleSidebarButton = app.descendants(matching: .any).matching(identifier: "titlebarControl.toggleSidebar").firstMatch
        let notificationsButton = app.descendants(matching: .any).matching(identifier: "titlebarControl.showNotifications").firstMatch
        let newWorkspaceButton = app.descendants(matching: .any).matching(identifier: "titlebarControl.newTab").firstMatch

        hover(in: window, at: CGPoint(x: window.frame.maxX - 48, y: window.frame.minY + 18))
        XCTAssertTrue(
            waitForCondition(timeout: 2.0) {
                (!toggleSidebarButton.exists || !toggleSidebarButton.isHittable) &&
                    (!notificationsButton.exists || !notificationsButton.isHittable) &&
                    (!newWorkspaceButton.exists || !newWorkspaceButton.isHittable)
            },
            "Expected collapsed-sidebar minimal mode to keep workspace controls suppressed. toggle=\(toggleSidebarButton.debugDescription) notifications=\(notificationsButton.debugDescription) new=\(newWorkspaceButton.debugDescription)"
        )

        let leadingInset = alphaTab.frame.minX - window.frame.minX
        XCTAssertLessThan(
            leadingInset,
            96,
            "Expected pane tabs to stay near the leading edge when collapsed-sidebar minimal mode removes the titlebar accessory lane. window=\(window.frame) alphaTab=\(alphaTab.frame) leadingInset=\(leadingInset)"
        )
    }

    func testMinimalModeSidebarControlsRemainVisibleWhileNotificationsPopoverIsShown() {
        let (app, dataPath) = launchConfiguredApp()

        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: launchTimeout),
            "Expected app to launch for minimal-mode notifications-popover pinning UI test. state=\(app.state.rawValue)"
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

        let toggleSidebarButton = app.descendants(matching: .any).matching(identifier: "titlebarControl.toggleSidebar").firstMatch
        let notificationsButton = app.descendants(matching: .any).matching(identifier: "titlebarControl.showNotifications").firstMatch
        let newWorkspaceButton = app.descendants(matching: .any).matching(identifier: "titlebarControl.newTab").firstMatch

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).hover()
        XCTAssertTrue(
            waitForCondition(timeout: 2.0) {
                !toggleSidebarButton.isHittable && !notificationsButton.isHittable && !newWorkspaceButton.isHittable
            },
            "Expected minimal-mode sidebar controls to start hidden away from hover."
        )

        XCTAssertTrue(
            ensureAppForegroundForKeyboardInteraction(app, timeout: 6.0),
            "Expected cmux to be foreground before opening notifications shortcut. state=\(app.state.rawValue)"
        )
        app.typeKey("i", modifierFlags: [.command])
        XCTAssertTrue(
            app.buttons["notificationsPopover.jumpToLatest"].waitForExistence(timeout: 6.0)
                || app.staticTexts["No notifications yet"].waitForExistence(timeout: 6.0),
            "Expected notifications popover to open."
        )

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).hover()
        XCTAssertTrue(
            waitForCondition(timeout: 2.0) {
                toggleSidebarButton.exists && toggleSidebarButton.isHittable &&
                    notificationsButton.exists && notificationsButton.isHittable &&
                    newWorkspaceButton.exists && newWorkspaceButton.isHittable
            },
            "Expected minimal-mode sidebar controls to remain visible while the notifications popover is open."
        )
    }

}
