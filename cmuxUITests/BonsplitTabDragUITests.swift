import XCTest
import Foundation
import AppKit
import CoreGraphics

final class BonsplitTabDragUITests: XCTestCase {
    private let launchTimeout: TimeInterval = 20.0
    private let setupTimeout: TimeInterval = 25.0

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        let cleanup = XCUIApplication()
        cleanup.terminate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    func testMinimalModeKeepsTabReorderWorking() {
        let (app, dataPath) = launchConfiguredApp()

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: launchTimeout),
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
        let dropIndicator = app.descendants(matching: .any).matching(identifier: "paneTabBar.dropIndicator").firstMatch
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

        let start = CGPoint(x: betaTab.frame.midX, y: betaTab.frame.midY)
        let destination = CGPoint(x: alphaTab.frame.midX - 14, y: alphaTab.frame.midY)
        guard let dragSession = beginMouseDrag(
            fromAccessibilityPoint: start,
            holdDuration: 0.20
        ) else {
            XCTFail("Expected raw mouse drag session to start")
            return
        }
        continueMouseDrag(
            dragSession,
            toAccessibilityPoint: destination,
            steps: 28,
            dragDuration: 0.45
        )
        XCTAssertTrue(
            waitForCondition(timeout: 2.0) { dropIndicator.exists },
            "Expected dragging beta onto alpha to reveal the Bonsplit drop indicator."
        )
        endMouseDrag(dragSession, atAccessibilityPoint: destination)

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

    func testDraggingPaneTabIntoSidebarCreatesNewWorkspace() {
        let (app, dataPath) = launchConfiguredApp()

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: launchTimeout),
            "Expected app to launch for pane-tab to sidebar workspace conversion UI test. state=\(app.state.rawValue)"
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

        guard let sourceWorkspaceId = ready["workspaceId"], !sourceWorkspaceId.isEmpty else {
            XCTFail("Expected setup to provide a source workspace id. data=\(ready)")
            return
        }
        let alphaTitle = ready["alphaTitle"] ?? "UITest Alpha"
        let betaTitle = ready["betaTitle"] ?? "UITest Beta"
        let betaTab = app.buttons[betaTitle]
        let sidebar = app.descendants(matching: .any).matching(identifier: "Sidebar").firstMatch
        let workspaceRowIdentifier = "sidebarWorkspace.\(sourceWorkspaceId)"
        let workspaceRow = app.descendants(matching: .any).matching(identifier: workspaceRowIdentifier).firstMatch

        XCTAssertTrue(betaTab.waitForExistence(timeout: 5.0), "Expected beta tab to exist")
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5.0), "Expected sidebar to exist")
        XCTAssertTrue(workspaceRow.waitForExistence(timeout: 5.0), "Expected source workspace row to exist")

        let start = CGPoint(x: betaTab.frame.midX, y: betaTab.frame.midY)
        let destination = CGPoint(
            x: min(sidebar.frame.maxX - 24.0, workspaceRow.frame.midX),
            y: workspaceRow.frame.maxY - max(6.0, min(14.0, workspaceRow.frame.height * 0.25))
        )
        guard let dragSession = beginMouseDrag(
            fromAccessibilityPoint: start,
            holdDuration: 0.20
        ) else {
            XCTFail("Expected raw mouse drag session to start")
            return
        }
        continueMouseDrag(
            dragSession,
            toAccessibilityPoint: destination,
            steps: 28,
            dragDuration: 0.45
        )
        endMouseDrag(dragSession, atAccessibilityPoint: destination)

        guard let updated = waitForJSONKey("workspaceCount", equals: "2", atPath: dataPath, timeout: 5.0) else {
            XCTFail("Expected workspace count to become 2 after dragging a pane tab into the sidebar. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }

        XCTAssertEqual(updated["hasSelectedWorkspace"], "1", "Expected a selected workspace after extraction. data=\(updated)")
        XCTAssertEqual(updated["trackedPaneTabCount"], "1", "Expected the source pane to keep only one tab after extraction. data=\(updated)")
        XCTAssertEqual(updated["trackedPaneTabTitles"], alphaTitle, "Expected the source pane to retain only the alpha tab after extraction. data=\(updated)")
        XCTAssertNotEqual(updated["selectedWorkspaceId"], sourceWorkspaceId, "Expected the extracted pane tab to land in a newly selected workspace. data=\(updated)")
    }

    func testMinimalModePlacesPaneTabBarAtTopEdge() {
        let (app, dataPath) = launchConfiguredApp()

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: launchTimeout),
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

    func testMinimalModeKeepsSidebarRowsBelowTrafficLights() {
        let (app, dataPath) = launchConfiguredApp()

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: launchTimeout),
            "Expected app to launch for minimal-mode sidebar inset UI test. state=\(app.state.rawValue)"
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
            36,
            accuracy: 4,
            "Expected minimal mode to keep the sidebar workspace row offset unchanged while reserving the existing traffic-light strip. window=\(window.frame) workspaceRow=\(workspaceRow.frame) topInset=\(topInset)"
        )
    }

    func testStandardModeKeepsWorkspaceControlsOutOfSidebar() {
        let (app, dataPath) = launchConfiguredApp(presentationMode: .standard)

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: launchTimeout),
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

        let leadingControlX = min(
            toggleSidebarButton.frame.minX,
            notificationsButton.frame.minX,
            newWorkspaceButton.frame.minX
        )
        XCTAssertGreaterThanOrEqual(
            leadingControlX,
            sidebar.frame.maxX - 4,
            "Expected standard mode workspace controls to stay outside the sidebar header. sidebar=\(sidebar.frame) toggle=\(toggleSidebarButton.frame) notifications=\(notificationsButton.frame) new=\(newWorkspaceButton.frame)"
        )
    }

    func testMinimalModeSidebarControlsRevealOnlyFromSidebarHover() {
        let (app, dataPath) = launchConfiguredApp()

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: launchTimeout),
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
            "Expected minimal-mode sidebar controls to reveal when hovering the sidebar chrome area."
        )
    }

    func testMinimalModeCollapsedSidebarKeepsWorkspaceControlsSuppressed() {
        let (app, dataPath) = launchConfiguredApp(startWithHiddenSidebar: true)

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: launchTimeout),
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
            ensureForegroundAfterLaunch(app, timeout: launchTimeout),
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

    func testMinimalModeCollapsedSidebarStillRevealsPaneTabBarControlsOnHover() {
        let (app, dataPath) = launchConfiguredApp(startWithHiddenSidebar: true)

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: launchTimeout),
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

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).hover()
        XCTAssertTrue(
            waitForCondition(timeout: 2.0) { !newTerminalButton.exists || !newTerminalButton.isHittable },
            "Expected pane tab bar controls to hide again after leaving the pane tab bar in minimal mode. button=\(newTerminalButton.debugDescription)"
        )
    }

    private enum WorkspacePresentationMode: String {
        case standard
        case minimal
    }

    private func launchConfiguredApp(
        startWithHiddenSidebar: Bool = false,
        presentationMode: WorkspacePresentationMode = .minimal
    ) -> (XCUIApplication, String) {
        let app = XCUIApplication()
        let dataPath = "/tmp/cmux-ui-test-bonsplit-tab-drag-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)

        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"] = dataPath
        if startWithHiddenSidebar {
            app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_START_WITH_HIDDEN_SIDEBAR"] = "1"
        }
        app.launchArguments += ["-workspacePresentationMode", presentationMode.rawValue]
        app.launch()
        app.activate()
        return (app, dataPath)
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }

    private func waitForAnyJSON(atPath path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if loadJSON(atPath: path) != nil { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return loadJSON(atPath: path) != nil
    }

    private func waitForJSONKey(_ key: String, equals expected: String, atPath path: String, timeout: TimeInterval) -> [String: String]? {
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

    private func waitForCondition(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func hover(in window: XCUIElement, at point: CGPoint) {
        let origin = window.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(
            CGVector(
                dx: point.x - window.frame.minX,
                dy: point.y - window.frame.minY
            )
        ).hover()
    }

    private func distanceToTopEdge(of element: XCUIElement, in window: XCUIElement) -> CGFloat {
        let gapIfOriginIsBottomLeft = abs(window.frame.maxY - element.frame.maxY)
        let gapIfOriginIsTopLeft = abs(element.frame.minY - window.frame.minY)
        return min(gapIfOriginIsBottomLeft, gapIfOriginIsTopLeft)
    }

    private struct RawMouseDragSession {
        let source: CGEventSource
    }

    private func beginMouseDrag(
        fromAccessibilityPoint start: CGPoint,
        holdDuration: TimeInterval = 0.15
    ) -> RawMouseDragSession? {
        let source = CGEventSource(stateID: .hidSystemState)
        XCTAssertNotNil(source, "Expected CGEventSource for raw mouse drag")
        guard let source else { return nil }

        let quartzStart = quartzPoint(fromAccessibilityPoint: start)

        postMouseEvent(type: .mouseMoved, at: quartzStart, source: source)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        postMouseEvent(type: .leftMouseDown, at: quartzStart, source: source)
        RunLoop.current.run(until: Date().addingTimeInterval(holdDuration))
        return RawMouseDragSession(source: source)
    }

    private func continueMouseDrag(
        _ session: RawMouseDragSession,
        toAccessibilityPoint end: CGPoint,
        steps: Int = 20,
        dragDuration: TimeInterval = 0.30
    ) {
        let currentLocation = NSEvent.mouseLocation
        let quartzEnd = quartzPoint(fromAccessibilityPoint: end)
        let clampedSteps = max(2, steps)
        for step in 1...clampedSteps {
            let progress = CGFloat(step) / CGFloat(clampedSteps)
            let point = CGPoint(
                x: currentLocation.x + ((quartzEnd.x - currentLocation.x) * progress),
                y: currentLocation.y + ((quartzEnd.y - currentLocation.y) * progress)
            )
            postMouseEvent(type: .leftMouseDragged, at: point, source: session.source)
            RunLoop.current.run(until: Date().addingTimeInterval(dragDuration / Double(clampedSteps)))
        }
    }

    private func endMouseDrag(
        _ session: RawMouseDragSession,
        atAccessibilityPoint end: CGPoint
    ) {
        let quartzEnd = quartzPoint(fromAccessibilityPoint: end)
        postMouseEvent(type: .leftMouseUp, at: quartzEnd, source: session.source)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func postMouseEvent(
        type: CGEventType,
        at point: CGPoint,
        source: CGEventSource
    ) {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            XCTFail("Expected CGEvent for mouse type \(type.rawValue) at \(point)")
            return
        }

        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
    }

    private func quartzPoint(fromAccessibilityPoint point: CGPoint) -> CGPoint {
        let desktopBounds = NSScreen.screens.reduce(CGRect.null) { partialResult, screen in
            partialResult.union(screen.frame)
        }
        XCTAssertFalse(desktopBounds.isNull, "Expected at least one screen when converting raw mouse coordinates")
        guard !desktopBounds.isNull else { return point }
        return CGPoint(x: point.x, y: desktopBounds.maxY - point.y)
    }
}
