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

    func testRightSidebarCloseButtonLivesInsideSidebarChrome() {
        let (app, dataPath) = launchConfiguredApp(showRightSidebar: true, alwaysShowShortcutHints: true)

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: launchTimeout),
            "Expected app to launch for right-sidebar close button UI test. state=\(app.state.rawValue)"
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

        let titlebarToggle = app.descendants(matching: .any).matching(identifier: "titlebarControl.toggleRightSidebar").firstMatch
        XCTAssertFalse(
            titlebarToggle.waitForExistence(timeout: 1.0),
            "Expected right sidebar toggle to be removed from the global titlebar."
        )

        let closeButton = app.buttons["RightSidebar.closeButton"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5.0), "Expected close button inside the right sidebar chrome.")
        XCTAssertTrue(
            waitForCondition(timeout: 3.0) { closeButton.isHittable },
            "Expected right sidebar close button to be hittable. button=\(closeButton.debugDescription)"
        )

        let shortcutHint = app.staticTexts["rightSidebarCloseShortcutHint"]
        XCTAssertTrue(shortcutHint.waitForExistence(timeout: 5.0), "Expected Cmd+Option+B hint over the close button.")
        let focusShortcutHint = app.staticTexts["rightSidebarFocusShortcutHint"]
        XCTAssertTrue(focusShortcutHint.waitForExistence(timeout: 5.0), "Expected Cmd+Shift+E hint inside the right sidebar.")
        let window = app.windows.element(boundBy: 0)
        XCTAssertTrue(window.waitForExistence(timeout: 5.0), "Expected main window to exist.")
        XCTAssertGreaterThanOrEqual(
            shortcutHint.frame.minY,
            window.frame.minY - 1,
            "Expected close shortcut hint to stay inside the visible window bounds. hint=\(shortcutHint.frame) window=\(window.frame)"
        )
        XCTAssertGreaterThanOrEqual(
            focusShortcutHint.frame.minY,
            window.frame.minY - 1,
            "Expected focus shortcut hint to stay inside the visible window bounds. hint=\(focusShortcutHint.frame) window=\(window.frame)"
        )
        XCTAssertLessThanOrEqual(
            abs(shortcutHint.frame.midX - closeButton.frame.midX),
            40,
            "Expected close shortcut hint to stay attached to the close button. hint=\(shortcutHint.frame) button=\(closeButton.frame)"
        )
        XCTAssertLessThan(
            shortcutHint.frame.midY,
            closeButton.frame.midY,
            "Expected close shortcut hint to render above the close button so it does not shift titlebar controls. hint=\(shortcutHint.frame) button=\(closeButton.frame)"
        )

        closeButton.click()
        XCTAssertTrue(
            waitForCondition(timeout: 3.0) {
                !closeButton.exists || !closeButton.isHittable
            },
            "Expected clicking the right sidebar close button to hide the sidebar."
        )

        app.typeKey("b", modifierFlags: [.command, .option])
        XCTAssertTrue(
            waitForCondition(timeout: 3.0) {
                closeButton.exists && closeButton.isHittable
            },
            "Expected Cmd+Option+B to reopen the right sidebar."
        )

        app.typeKey("b", modifierFlags: [.command, .option])
        XCTAssertTrue(
            waitForCondition(timeout: 3.0) {
                !closeButton.exists || !closeButton.isHittable
            },
            "Expected Cmd+Option+B to hide the right sidebar when it is open."
        )
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

    func testDoubleClickingPaneTabRenamesInline() {
        let (app, dataPath) = launchConfiguredApp()

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: launchTimeout),
            "Expected app to launch for pane tab double-click rename UI test. state=\(app.state.rawValue)"
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

        let betaTitle = ready["betaTitle"] ?? "UITest Beta"
        let renamedTitle = "Renamed Beta \(UUID().uuidString.prefix(4))"
        let window = app.windows.element(boundBy: 0)
        let alphaTitle = ready["alphaTitle"] ?? "UITest Alpha"
        let alphaTab = app.buttons[alphaTitle]
        let betaTab = app.buttons[betaTitle]

        XCTAssertTrue(window.waitForExistence(timeout: 5.0), "Expected main window to exist")
        XCTAssertTrue(alphaTab.waitForExistence(timeout: 5.0), "Expected alpha tab to exist")
        XCTAssertTrue(betaTab.waitForExistence(timeout: 5.0), "Expected beta tab to exist")
        let alphaFrameBeforeRename = alphaTab.frame
        let betaFrameBeforeRename = betaTab.frame
        let beforeRenameScreenshot = window.screenshot()
        addWindowScreenshot(named: "pane-tab-before-inline-rename", screenshot: beforeRenameScreenshot)

        doubleClick(in: window, atAccessibilityPoint: CGPoint(x: betaTab.frame.midX, y: betaTab.frame.midY))

        let dialog = app.dialogs.containing(.staticText, identifier: "Rename Tab").firstMatch
        XCTAssertFalse(dialog.waitForExistence(timeout: 0.5), "Expected double-clicking a pane tab to avoid the Rename Tab dialog")

        let nameField = app.textFields["paneTab.inlineRenameField"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 3.0), "Expected double-clicking a pane tab to show an inline rename field")
        let duringRenameScreenshot = window.screenshot()
        addWindowScreenshot(named: "pane-tab-during-inline-rename", screenshot: duringRenameScreenshot)
        XCTAssertVisibleHighlightCrop(
            beforeRenameScreenshot,
            comparedTo: duringRenameScreenshot,
            cropInWindow: paneTabTitleCrop(for: betaFrameBeforeRename),
            in: window,
            minMeanLumaDiff: 1.0,
            "Expected pane tab title pixels to show the full-selection highlight when inline editing starts"
        )
        XCTAssertStableFrame(
            alphaTab.frame,
            comparedTo: alphaFrameBeforeRename,
            accuracy: 1.0,
            "Expected neighboring pane tab geometry to stay stable while another tab is inline-renaming"
        )
        XCTAssertCenteredVertically(
            nameField.frame,
            in: betaFrameBeforeRename,
            accuracy: 1.0,
            "Expected pane tab inline editor to stay vertically centered in the original tab bounds"
        )
        XCTAssertGreaterThanOrEqual(
            nameField.frame.minY,
            betaFrameBeforeRename.minY - 1.0,
            "Expected pane tab inline editor to stay inside the original tab bounds"
        )
        XCTAssertLessThanOrEqual(
            nameField.frame.maxY,
            betaFrameBeforeRename.maxY + 1.0,
            "Expected pane tab inline editor to stay inside the original tab bounds"
        )
        XCTAssertLessThanOrEqual(
            nameField.frame.height,
            betaFrameBeforeRename.height + 1.0,
            "Expected inline pane tab rename field not to exceed the original tab height"
        )
        app.typeText(renamedTitle)
        clickOutsideInlineEditor(in: window)

        XCTAssertFalse(
            nameField.waitForExistence(timeout: 1.0),
            "Expected clicking outside the pane tab inline editor to stop editing"
        )

        XCTAssertTrue(
            app.buttons[renamedTitle].waitForExistence(timeout: 5.0),
            "Expected the renamed pane tab to be visible"
        )
        XCTAssertTrue(
            waitForCondition(timeout: 5.0) {
                loadJSON(atPath: dataPath)?["trackedPaneTabTitles"]?.contains(renamedTitle) == true
            },
            "Expected recorder state to include renamed pane tab. data=\(loadJSON(atPath: dataPath) ?? [:])"
        )
    }

    func testDoubleClickingSidebarWorkspaceRenamesInline() {
        let (app, dataPath) = launchConfiguredApp()

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: launchTimeout),
            "Expected app to launch for sidebar workspace double-click rename UI test. state=\(app.state.rawValue)"
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

        let workspaceId = ready["workspaceId"] ?? ""
        let renamedTitle = "Renamed Workspace \(UUID().uuidString.prefix(4))"
        let window = app.windows.element(boundBy: 0)
        let workspaceRow = app.descendants(matching: .any).matching(identifier: "sidebarWorkspace.\(workspaceId)").firstMatch

        XCTAssertTrue(window.waitForExistence(timeout: 5.0), "Expected main window to exist")
        XCTAssertTrue(workspaceRow.waitForExistence(timeout: 5.0), "Expected workspace row to exist")
        let rowFrameBeforeRename = workspaceRow.frame
        let beforeRenameScreenshot = window.screenshot()
        addWindowScreenshot(named: "sidebar-before-inline-rename", screenshot: beforeRenameScreenshot)

        doubleClick(in: window, atAccessibilityPoint: CGPoint(x: workspaceRow.frame.midX, y: workspaceRow.frame.midY))

        let dialog = app.dialogs.containing(.staticText, identifier: "Rename Workspace").firstMatch
        XCTAssertFalse(dialog.waitForExistence(timeout: 0.5), "Expected double-clicking a workspace row to avoid the Rename Workspace dialog")

        let nameField = app.textFields["sidebar.workspace.inlineRenameField"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 3.0), "Expected double-clicking a workspace row to show an inline rename field")
        let duringRenameScreenshot = window.screenshot()
        addWindowScreenshot(named: "sidebar-during-inline-rename", screenshot: duringRenameScreenshot)
        XCTAssertVisibleHighlightCrop(
            beforeRenameScreenshot,
            comparedTo: duringRenameScreenshot,
            cropInWindow: sidebarWorkspaceTitleCrop(for: rowFrameBeforeRename),
            in: window,
            minMeanLumaDiff: 1.0,
            "Expected sidebar workspace title pixels to show the full-selection highlight when inline editing starts"
        )
        XCTAssertStableFrame(
            workspaceRow.frame,
            comparedTo: rowFrameBeforeRename,
            accuracy: 1.0,
            "Expected inline workspace rename not to change sidebar row geometry"
        )
        XCTAssertGreaterThanOrEqual(
            nameField.frame.minY,
            workspaceRow.frame.minY - 1.0,
            "Expected sidebar inline editor to stay inside the original workspace row bounds"
        )
        XCTAssertLessThanOrEqual(
            nameField.frame.maxY,
            workspaceRow.frame.maxY + 1.0,
            "Expected sidebar inline editor to stay inside the original workspace row bounds"
        )
        app.typeText(renamedTitle)
        clickOutsideInlineEditor(in: window)

        XCTAssertFalse(
            nameField.waitForExistence(timeout: 1.0),
            "Expected clicking outside the workspace inline editor to stop editing"
        )

        XCTAssertTrue(
            waitForCondition(timeout: 5.0) {
                workspaceRow.label.contains(renamedTitle)
            },
            "Expected the sidebar workspace row label to include the inline rename. label=\(workspaceRow.label)"
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

    func testManyPaneTabBarActionsUseTrailingWhitespaceBeforeClipping() {
        let actionButtonCount = 10
        let (app, dataPath) = launchConfiguredApp(
            startWithHiddenSidebar: true,
            windowSize: "760x420",
            actionButtonCount: actionButtonCount
        )

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: launchTimeout),
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

    private enum WorkspacePresentationMode: String {
        case standard
        case minimal
    }

    private func launchConfiguredApp(
        startWithHiddenSidebar: Bool = false,
        presentationMode: WorkspacePresentationMode = .minimal,
        showRightSidebar: Bool = false,
        alwaysShowShortcutHints: Bool = false,
        windowSize: String? = nil,
        actionButtonCount: Int? = nil
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
        if let actionButtonCount {
            app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_ACTION_BUTTON_COUNT"] = String(actionButtonCount)
        }
        if showRightSidebar {
            app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] = "1"
        }
        if alwaysShowShortcutHints {
            app.launchEnvironment["CMUX_UI_TEST_SHORTCUT_HINTS_ALWAYS_SHOW"] = "1"
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

    private func waitForCondition(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func addWindowScreenshot(named name: String, window: XCUIElement) {
        addWindowScreenshot(named: name, screenshot: window.screenshot())
    }

    private func addWindowScreenshot(named name: String, screenshot: XCUIScreenshot) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func paneTabTitleCrop(for tabFrame: CGRect) -> CGRect {
        CGRect(
            x: tabFrame.minX + 22,
            y: tabFrame.minY + 2,
            width: max(1, tabFrame.width - 56),
            height: max(1, tabFrame.height - 4)
        )
    }

    private func sidebarWorkspaceTitleCrop(for rowFrame: CGRect) -> CGRect {
        CGRect(
            x: rowFrame.minX + 24,
            y: rowFrame.minY + 2,
            width: max(1, rowFrame.width - 32),
            height: min(20, max(1, rowFrame.height - 4))
        )
    }

    private func XCTAssertVisibleHighlightCrop(
        _ before: XCUIScreenshot,
        comparedTo after: XCUIScreenshot,
        cropInWindow crop: CGRect,
        in window: XCUIElement,
        minMeanLumaDiff: Double,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let diff = meanAbsLumaDiff(
            pngA: before.pngRepresentation,
            pngB: after.pngRepresentation,
            normalizedCrop: normalizedCrop(crop, in: window)
        ) else {
            XCTFail("Unable to compare inline rename screenshots", file: file, line: line)
            return
        }
        XCTAssertGreaterThanOrEqual(
            diff,
            minMeanLumaDiff,
            "\(message()) diff=\(String(format: "%.3f", diff)) crop=\(crop) window=\(window.frame)",
            file: file,
            line: line
        )
    }

    private func normalizedCrop(_ crop: CGRect, in window: XCUIElement) -> CGRect {
        let windowFrame = window.frame
        return CGRect(
            x: (crop.minX - windowFrame.minX) / windowFrame.width,
            y: (crop.minY - windowFrame.minY) / windowFrame.height,
            width: crop.width / windowFrame.width,
            height: crop.height / windowFrame.height
        )
    }

    private func meanAbsLumaDiff(pngA: Data, pngB: Data, normalizedCrop: CGRect) -> Double? {
        guard let imageA = cgImage(from: pngA),
              let imageB = cgImage(from: pngB) else {
            return nil
        }
        guard imageA.width == imageB.width, imageA.height == imageB.height else { return nil }
        let width = imageA.width
        let height = imageA.height
        guard width > 0, height > 0 else { return nil }

        let cropPx = CGRect(
            x: max(0, min(CGFloat(width - 1), normalizedCrop.origin.x * CGFloat(width))),
            y: max(0, min(CGFloat(height - 1), normalizedCrop.origin.y * CGFloat(height))),
            width: max(1, min(CGFloat(width), normalizedCrop.width * CGFloat(width))),
            height: max(1, min(CGFloat(height), normalizedCrop.height * CGFloat(height)))
        ).integral

        let x0 = Int(cropPx.minX)
        let y0 = Int(cropPx.minY)
        let x1 = Int(min(CGFloat(width), cropPx.maxX))
        let y1 = Int(min(CGFloat(height), cropPx.maxY))
        guard x1 > x0, y1 > y0 else { return nil }

        guard let bufA = decodeRGBA(imageA), let bufB = decodeRGBA(imageB) else { return nil }
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        let step = 2
        var total = 0.0
        var count = 0
        for y in stride(from: y0, to: y1, by: step) {
            let row = y * bytesPerRow
            for x in stride(from: x0, to: x1, by: step) {
                let i = row + x * bytesPerPixel
                let ar = Double(bufA[i])
                let ag = Double(bufA[i + 1])
                let ab = Double(bufA[i + 2])
                let br = Double(bufB[i])
                let bg = Double(bufB[i + 1])
                let bb = Double(bufB[i + 2])
                let al = 0.2126 * ar + 0.7152 * ag + 0.0722 * ab
                let bl = 0.2126 * br + 0.7152 * bg + 0.0722 * bb
                total += abs(al - bl)
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : nil
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
        var buf = [UInt8](repeating: 0, count: height * bytesPerRow)

        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else { return false }

            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        return ok ? buf : nil
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
        target.doubleClick()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func clickOutsideInlineEditor(in window: XCUIElement) {
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)).click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func XCTAssertCenteredVertically(
        _ actual: CGRect,
        in expected: CGRect,
        accuracy: CGFloat,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.midY, expected.midY, accuracy: accuracy, message(), file: file, line: line)
        let topMargin = actual.minY - expected.minY
        let bottomMargin = expected.maxY - actual.maxY
        XCTAssertEqual(topMargin, bottomMargin, accuracy: accuracy, message(), file: file, line: line)
    }

    private func XCTAssertStableFrame(
        _ actual: CGRect,
        comparedTo expected: CGRect,
        accuracy: CGFloat,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, message(), file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, message(), file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, message(), file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, message(), file: file, line: line)
    }

    private func dragTab(_ sourceTab: XCUIElement, before targetTab: XCUIElement) {
        let source = sourceTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = targetTab.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        source.press(forDuration: 0.25, thenDragTo: target)
    }
}
