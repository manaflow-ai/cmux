import XCTest
import Foundation
import CoreGraphics
import ImageIO

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

    func testMinimalModeVisuallyRendersPaneTabs() {
        let (app, dataPath) = launchConfiguredApp()

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: launchTimeout),
            "Expected app to launch for minimal-mode pane-tab rendering UI test. state=\(app.state.rawValue)"
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
        let alphaTab = app.buttons[alphaTitle]
        XCTAssertTrue(alphaTab.waitForExistence(timeout: 5.0), "Expected alpha tab to exist")
        XCTAssertGreaterThan(alphaTab.frame.width, 20, "Expected alpha tab to have a renderable frame. frame=\(alphaTab.frame)")
        XCTAssertGreaterThan(alphaTab.frame.height, 10, "Expected alpha tab to have a renderable frame. frame=\(alphaTab.frame)")

        guard let stats = screenshotStats(for: alphaTab) else {
            XCTFail("Failed to sample alpha tab screenshot. frame=\(alphaTab.frame)")
            return
        }

        XCTAssertFalse(
            stats.isProbablyBlank,
            "Expected minimal-mode pane tab pixels to render, not a uniform backdrop. stats=\(stats) frame=\(alphaTab.frame)"
        )
    }

    func testRightSidebarModeBarKeepsFixedHeightAcrossPresentationModes() {
        let expectedModeBarHeight: CGFloat = 28
        var referenceTopInset: CGFloat?

        for presentationMode in [WorkspacePresentationMode.minimal, .standard] {
            let (app, dataPath) = launchConfiguredApp(presentationMode: presentationMode, showRightSidebar: true)
            defer { app.terminate() }

            XCTAssertTrue(
                ensureForegroundAfterLaunch(app, timeout: launchTimeout),
                "Expected app to launch for \(presentationMode.rawValue)-mode right-sidebar alignment UI test. state=\(app.state.rawValue)"
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

            guard let geometry = waitForJSONNumber(
                "rightSidebarModeBarWidth",
                greaterThan: 1,
                atPath: dataPath,
                timeout: 5.0
            ) else {
                XCTFail("Timed out waiting for right sidebar mode bar geometry. data=\(loadJSON(atPath: dataPath) ?? [:])")
                return
            }
            XCTAssertEqual(
                geometry["rightSidebarVisible"],
                "1",
                "Expected right sidebar to be visible before measuring its titlebar. data=\(geometry)"
            )
            let modeBarHeight = CGFloat(Double(geometry["rightSidebarModeBarHeight"] ?? "") ?? .nan)
            let modeBarMinY = CGFloat(Double(geometry["rightSidebarModeBarMinY"] ?? "") ?? .nan)
            let titlebarHeight = CGFloat(Double(geometry["rightSidebarTitlebarHeight"] ?? "") ?? .nan)

            XCTAssertEqual(
                modeBarHeight,
                expectedModeBarHeight,
                accuracy: 2,
                "Expected \(presentationMode.rawValue)-mode right sidebar mode bar to stay compact. geometry=\(geometry)"
            )
            XCTAssertEqual(
                titlebarHeight,
                expectedModeBarHeight,
                accuracy: 0.5,
                "Expected \(presentationMode.rawValue)-mode right sidebar chrome metric to stay compact. geometry=\(geometry)"
            )
            XCTAssertEqual(
                modeBarHeight,
                alphaTab.frame.height,
                accuracy: 2,
                "Expected \(presentationMode.rawValue)-mode right sidebar mode bar to match Bonsplit pane tab height. geometry=\(geometry) alphaTab=\(alphaTab.frame)"
            )

            if let referenceTopInset {
                XCTAssertEqual(
                    modeBarMinY,
                    referenceTopInset,
                    accuracy: 2,
                    "Expected right sidebar mode bar top position not to shift between presentation modes. mode=\(presentationMode.rawValue) geometry=\(geometry) window=\(window.frame)"
                )
            } else {
                referenceTopInset = modeBarMinY
            }
        }
    }

    func testMinimalModeTitlebarDoubleClickZoomsWindow() {
        let (app, dataPath) = launchConfiguredApp(windowSize: "640x420")

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: launchTimeout),
            "Expected app to launch for minimal-mode titlebar double-click UI test. state=\(app.state.rawValue)"
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

        let initialFrame = window.frame
        let betaTitle = ready["betaTitle"] ?? "UITest Beta"
        let betaTab = app.buttons[betaTitle]
        XCTAssertTrue(betaTab.waitForExistence(timeout: 5.0), "Expected beta tab to exist")

        let point = CGPoint(
            x: min(initialFrame.maxX - 64, max(betaTab.frame.maxX + 80, initialFrame.midX)),
            y: initialFrame.minY + 16
        )
        doubleClick(in: window, atAccessibilityPoint: point)

        XCTAssertTrue(
            waitForCondition(timeout: 4.0) {
                let frame = window.frame
                return frame.width > initialFrame.width + 80 || frame.height > initialFrame.height + 80
            },
            "Expected titlebar double-click in minimal mode to zoom the window. initial=\(initialFrame) current=\(window.frame)"
        )
    }

    func testSidebarWorkspaceRowsKeepStableTopInsetAcrossPresentationModes() {
        let expectedTopInset: CGFloat = 32

        for presentationMode in [WorkspacePresentationMode.minimal, .standard] {
            let (app, dataPath) = launchConfiguredApp(presentationMode: presentationMode)
            defer { app.terminate() }

            XCTAssertTrue(
                ensureForegroundAfterLaunch(app, timeout: launchTimeout),
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

    private enum WorkspacePresentationMode: String {
        case standard
        case minimal
    }

    private func launchConfiguredApp(
        startWithHiddenSidebar: Bool = false,
        presentationMode: WorkspacePresentationMode = .minimal,
        showRightSidebar: Bool = false,
        windowSize: String? = nil
    ) -> (XCUIApplication, String) {
        let app = XCUIApplication()
        let dataPath = "/tmp/cmux-ui-test-bonsplit-tab-drag-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)

        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"] = dataPath
        if startWithHiddenSidebar {
            app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_START_WITH_HIDDEN_SIDEBAR"] = "1"
        }
        if let windowSize {
            app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_WINDOW_SIZE"] = windowSize
        }
        if showRightSidebar {
            app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] = "1"
        }
        app.launchArguments += ["-workspacePresentationMode", presentationMode.rawValue]
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }
        return (app, dataPath)
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

    private func waitForJSONNumber(
        _ key: String,
        greaterThan threshold: Double,
        atPath path: String,
        timeout: TimeInterval
    ) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadJSON(atPath: path),
               let rawValue = data[key],
               let value = Double(rawValue),
               value > threshold {
                return data
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadJSON(atPath: path),
           let rawValue = data[key],
           let value = Double(rawValue),
           value > threshold {
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

    private struct ScreenshotStats: CustomStringConvertible {
        let sampleCount: Int
        let uniqueQuantized: Int
        let lumaStdDev: Double
        let modeFraction: Double

        var isProbablyBlank: Bool {
            lumaStdDev < 2.5 && modeFraction > 0.992
        }

        var description: String {
            "samples=\(sampleCount) unique=\(uniqueQuantized) stddev=\(String(format: "%.3f", lumaStdDev)) mode=\(String(format: "%.4f", modeFraction))"
        }
    }

    private func screenshotStats(for element: XCUIElement) -> ScreenshotStats? {
        cropStats(pngData: element.screenshot().pngRepresentation)
    }

    private func cgImage(from pngData: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func decodeRGBA(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: height * bytesPerRow)

        let ok = buffer.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }

            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        return ok ? buffer : nil
    }

    private func cropStats(pngData: Data) -> ScreenshotStats? {
        guard let image = cgImage(from: pngData),
              let buffer = decodeRGBA(image) else {
            return nil
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let step = 3
        var lumas = [Double]()
        lumas.reserveCapacity((width / step) * (height / step))
        var histogram = [UInt16: Int]()
        histogram.reserveCapacity(256)
        var count = 0

        for y in stride(from: 0, to: height, by: step) {
            let rowBase = y * bytesPerRow
            for x in stride(from: 0, to: width, by: step) {
                let index = rowBase + x * bytesPerPixel
                let red = Double(buffer[index])
                let green = Double(buffer[index + 1])
                let blue = Double(buffer[index + 2])
                let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                lumas.append(luma)

                let redQuantized = UInt16(UInt8(buffer[index]) >> 4)
                let greenQuantized = UInt16(UInt8(buffer[index + 1]) >> 4)
                let blueQuantized = UInt16(UInt8(buffer[index + 2]) >> 4)
                let key = (redQuantized << 8) | (greenQuantized << 4) | blueQuantized
                histogram[key, default: 0] += 1
                count += 1
            }
        }

        guard count > 0 else { return nil }
        let mean = lumas.reduce(0.0, +) / Double(lumas.count)
        let variance = lumas.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lumas.count)
        let modeCount = histogram.values.max() ?? 0

        return ScreenshotStats(
            sampleCount: count,
            uniqueQuantized: histogram.count,
            lumaStdDev: sqrt(variance),
            modeFraction: Double(modeCount) / Double(count)
        )
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

    private func doubleClick(in window: XCUIElement, atAccessibilityPoint point: CGPoint) {
        let target = window.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(
                dx: point.x - window.frame.minX,
                dy: point.y - window.frame.minY
            )
        )
        target.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        target.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func dragTab(_ sourceTab: XCUIElement, before targetTab: XCUIElement) {
        let source = sourceTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = targetTab.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        source.press(forDuration: 0.25, thenDragTo: target)
    }
}
