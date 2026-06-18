import XCTest
import Foundation
import CoreGraphics

final class BonsplitTabDragUITests: XCTestCase {
    private let launchTimeout: TimeInterval = 20.0
    private let setupTimeout: TimeInterval = 25.0

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        let cleanup = XCUIApplication()
        cleanup.terminate()
        _ = cleanup.wait(for: .notRunning, timeout: 2.0)
    }

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

    func testRightSidebarModeBarKeepsFixedHeightAcrossPresentationModes() {
        let expectedModeBarHeight: CGFloat = 28
        var referenceTopInset: CGFloat?

        for presentationMode in [WorkspacePresentationMode.minimal, .standard] {
            let (app, dataPath) = launchConfiguredApp(presentationMode: presentationMode, showRightSidebar: true)
            defer { app.terminate() }

            XCTAssertTrue(
                ensureAppRunningAfterLaunch(app, timeout: launchTimeout),
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
            XCTAssertGreaterThanOrEqual(
                alphaTab.frame.height,
                modeBarHeight,
                "Expected \(presentationMode.rawValue)-mode Bonsplit pane tab hit target to cover the compact chrome lane. geometry=\(geometry) alphaTab=\(alphaTab.frame)"
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
            ensureAppRunningAfterLaunch(app, timeout: launchTimeout),
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
        let openAsPaneButton = app.buttons["RightSidebar.openAsPaneButton"]
        XCTAssertTrue(openAsPaneButton.waitForExistence(timeout: 5.0), "Expected open-as-pane button inside the right sidebar chrome.")
        XCTAssertTrue(
            waitForCondition(timeout: 3.0) { openAsPaneButton.isHittable },
            "Expected right sidebar open-as-pane button to be hittable. button=\(openAsPaneButton.debugDescription)"
        )
        XCTAssertEqual(openAsPaneButton.frame.width, closeButton.frame.width, accuracy: 1)
        XCTAssertEqual(openAsPaneButton.frame.height, closeButton.frame.height, accuracy: 1)
        XCTAssertEqual(openAsPaneButton.frame.minY, closeButton.frame.minY, accuracy: 1)
        XCTAssertEqual(openAsPaneButton.frame.maxY, closeButton.frame.maxY, accuracy: 1)
        let headerGeometryKeys = [
            "rightSidebarHeaderCloseMinX",
            "rightSidebarHeaderCloseMaxX",
            "rightSidebarHeaderCloseMinY",
            "rightSidebarHeaderCloseMaxY",
            "rightSidebarHeaderCloseWidth",
            "rightSidebarHeaderCloseHeight",
            "rightSidebarHeaderOpenAsPaneMinX",
            "rightSidebarHeaderOpenAsPaneMaxX",
            "rightSidebarHeaderOpenAsPaneMinY",
            "rightSidebarHeaderOpenAsPaneMaxY",
            "rightSidebarHeaderOpenAsPaneWidth",
            "rightSidebarHeaderOpenAsPaneHeight",
        ]
        guard let headerGeometry = waitForJSONNumbers(
            headerGeometryKeys,
            atPath: dataPath,
            timeout: 5.0
        ),
              let closeMinX = Double(headerGeometry["rightSidebarHeaderCloseMinX"] ?? ""),
              let closeMaxX = Double(headerGeometry["rightSidebarHeaderCloseMaxX"] ?? ""),
              let closeWidth = Double(headerGeometry["rightSidebarHeaderCloseWidth"] ?? ""),
              let closeHeight = Double(headerGeometry["rightSidebarHeaderCloseHeight"] ?? ""),
              let closeMinY = Double(headerGeometry["rightSidebarHeaderCloseMinY"] ?? ""),
              let closeMaxY = Double(headerGeometry["rightSidebarHeaderCloseMaxY"] ?? ""),
              let openMinX = Double(headerGeometry["rightSidebarHeaderOpenAsPaneMinX"] ?? ""),
              let openMaxX = Double(headerGeometry["rightSidebarHeaderOpenAsPaneMaxX"] ?? ""),
              let openWidth = Double(headerGeometry["rightSidebarHeaderOpenAsPaneWidth"] ?? ""),
              let openHeight = Double(headerGeometry["rightSidebarHeaderOpenAsPaneHeight"] ?? ""),
              let openMinY = Double(headerGeometry["rightSidebarHeaderOpenAsPaneMinY"] ?? ""),
              let openMaxY = Double(headerGeometry["rightSidebarHeaderOpenAsPaneMaxY"] ?? "") else {
            XCTFail("Timed out waiting for right sidebar header control geometry. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }
        XCTAssertEqual(closeMaxX - closeMinX, closeWidth, accuracy: 0.5, "Expected close x bounds to match width. geometry=\(headerGeometry)")
        XCTAssertEqual(openMaxX - openMinX, openWidth, accuracy: 0.5, "Expected open-as-pane x bounds to match width. geometry=\(headerGeometry)")
        XCTAssertLessThan(openMaxX, closeMinX, "Expected open-as-pane control to remain left of close. geometry=\(headerGeometry)")
        XCTAssertEqual(openWidth, closeWidth, accuracy: 0.5, "Expected header accessory controls to share width. geometry=\(headerGeometry)")
        XCTAssertEqual(openHeight, closeHeight, accuracy: 0.5, "Expected header accessory controls to share height. geometry=\(headerGeometry)")
        XCTAssertEqual(openMinY, closeMinY, accuracy: 0.5, "Expected header accessory controls to share top edge. geometry=\(headerGeometry)")
        XCTAssertEqual(openMaxY, closeMaxY, accuracy: 0.5, "Expected header accessory controls to share bottom edge. geometry=\(headerGeometry)")

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

        XCTAssertTrue(
            ensureAppForegroundForKeyboardInteraction(app, timeout: 6.0),
            "Expected cmux to be foreground before toggling the right sidebar shortcut. state=\(app.state.rawValue)"
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

    func testLaunchCompletesWithHiddenRightSidebarRestoringFindMode() {
        let (app, dataPath) = launchConfiguredApp(
            rightSidebarMode: "find",
            showRightSidebar: false
        )

        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: launchTimeout),
            "Expected app to keep running with hidden right sidebar in find mode. state=\(app.state.rawValue) data=\(loadJSON(atPath: dataPath) ?? [:])"
        )
        guard let ready = waitForJSONKey("ready", equals: "1", atPath: dataPath, timeout: setupTimeout) else {
            XCTFail("Timed out waiting for ready=1 with hidden right sidebar in find mode. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }

        if let setupError = ready["setupError"], !setupError.isEmpty {
            XCTFail("Setup failed: \(setupError)")
            return
        }

        XCTAssertEqual(ready["rightSidebarVisible"], "0")
        XCTAssertNotEqual(app.state, .notRunning, "Expected app to still be running after hidden right-sidebar setup. data=\(loadJSON(atPath: dataPath) ?? [:])")
        XCTAssertFalse(
            app.textFields["FileExplorerSearchField"].firstMatch.exists,
            "Hidden right sidebar should not expose the File Explorer search field at launch."
        )
    }

    func testTitlebarShortcutHintsDoNotCoverHeaderIcons() {
        let (app, dataPath) = launchConfiguredApp(alwaysShowShortcutHints: true)

        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: launchTimeout),
            "Expected app to launch for titlebar shortcut hint geometry test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(waitForAnyJSON(atPath: dataPath, timeout: setupTimeout), "Expected titlebar geometry data at \(dataPath)")
        guard let ready = waitForJSONKey("ready", equals: "1", atPath: dataPath, timeout: setupTimeout) else {
            XCTFail("Timed out waiting for ready=1. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }

        if let setupError = ready["setupError"], !setupError.isEmpty {
            XCTFail("Setup failed: \(setupError)")
            return
        }

        let controls = [
            "titlebarControl_toggleSidebar",
            "titlebarControl_showNotifications",
            "titlebarControl_newTab",
            "titlebarControl_focusHistoryBack",
            "titlebarControl_focusHistoryForward",
        ]
        let hints = [
            "titlebarShortcutHint_toggleSidebar",
            "titlebarShortcutHint_showNotifications",
            "titlebarShortcutHint_newTab",
            "titlebarShortcutHint_focusHistoryBack",
            "titlebarShortcutHint_focusHistoryForward",
        ]
        let trafficLights = [
            "titlebarTrafficLightClose",
            "titlebarTrafficLightMinimize",
            "titlebarTrafficLightZoom",
        ]
        let allPrefixes = controls + hints + trafficLights
        let keys = allPrefixes.flatMap { prefix in
            ["\(prefix)X", "\(prefix)Y", "\(prefix)Width", "\(prefix)Height"]
        }
        guard let geometry = waitForJSONNumbers(keys, atPath: dataPath, timeout: 5.0) else {
            XCTFail("Timed out waiting for titlebar control geometry. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }

        func rect(_ prefix: String) -> CGRect {
            CGRect(
                x: Double(geometry["\(prefix)X"] ?? "") ?? 0,
                y: Double(geometry["\(prefix)Y"] ?? "") ?? 0,
                width: Double(geometry["\(prefix)Width"] ?? "") ?? 0,
                height: Double(geometry["\(prefix)Height"] ?? "") ?? 0
            )
        }

        let closeTrafficLight = rect("titlebarTrafficLightClose")
        XCTAssertGreaterThan(closeTrafficLight.width, 0)
        XCTAssertGreaterThan(closeTrafficLight.height, 0)

        for trafficLight in trafficLights.dropFirst() {
            let frame = rect(trafficLight)
            XCTAssertEqual(frame.width, closeTrafficLight.width, accuracy: 0.5, "Expected traffic lights to share width. geometry=\(geometry)")
            XCTAssertEqual(frame.height, closeTrafficLight.height, accuracy: 0.5, "Expected traffic lights to share height. geometry=\(geometry)")
            XCTAssertEqual(frame.midY, closeTrafficLight.midY, accuracy: 0.5, "Expected traffic lights to share vertical center. geometry=\(geometry)")
        }

        let firstControlHeight = rect(controls[0]).height
        for (controlPrefix, hintPrefix) in zip(controls, hints) {
            let control = rect(controlPrefix)
            let hint = rect(hintPrefix)
            XCTAssertEqual(control.height, firstControlHeight, accuracy: 0.5, "Expected titlebar controls to share height. geometry=\(geometry)")
            XCTAssertEqual(control.midY, closeTrafficLight.midY, accuracy: 1.0, "Expected \(controlPrefix) to align to traffic light center. geometry=\(geometry)")
            XCTAssertFalse(
                control.intersects(hint),
                "Expected shortcut hint \(hintPrefix) not to cover titlebar control \(controlPrefix). geometry=\(geometry)"
            )
        }
    }

    func testMinimalModeTitlebarDoubleClickZoomsWindow() {
        let (app, dataPath) = launchConfiguredApp(windowSize: "640x420")

        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: launchTimeout),
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

    private enum WorkspacePresentationMode: String {
        case standard
        case minimal
    }

    private func launchConfiguredApp(
        startWithHiddenSidebar: Bool = false,
        presentationMode: WorkspacePresentationMode = .minimal,
        rightSidebarMode: String? = nil,
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
        if let rightSidebarMode {
            app.launchArguments += [
                "-rightSidebar.mode", rightSidebarMode,
                "-fileExplorer.isVisible", showRightSidebar ? "1" : "0",
            ]
        }
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }
        return (app, dataPath)
    }

    private func ensureAppRunningAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let launched = waitForCondition(timeout: timeout) {
            app.state == .runningForeground ||
                app.state == .runningBackground ||
                app.windows.firstMatch.exists
        }
        guard launched else { return false }
        return ensureAppReadyForBonsplitInteraction(app, timeout: 6.0)
    }

    private func ensureAppReadyForBonsplitInteraction(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.state == .runningForeground {
            return true
        }
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App foreground activation may fail on headless CI runners", options: options) {
            app.activate()
        }
        let reachedForeground = waitForCondition(timeout: timeout) {
            app.state == .runningForeground
        }
        if reachedForeground {
            return true
        }
        // Bonsplit gestures target realized windows; headless runners can keep reporting
        // .unknown after launch even when the window is queryable and ready for coordinates.
        return app.windows.firstMatch.waitForExistence(timeout: timeout)
    }

    private func ensureAppForegroundForKeyboardInteraction(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.state == .runningForeground {
            return true
        }
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App foreground activation may fail on headless CI runners", options: options) {
            app.activate()
        }
        return waitForCondition(timeout: timeout) {
            app.state == .runningForeground
        }
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

    private func waitForJSONNumbers(
        _ keys: [String],
        atPath path: String,
        timeout: TimeInterval
    ) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadJSON(atPath: path),
               keys.allSatisfy({ key in
                   guard let rawValue = data[key],
                         Double(rawValue) != nil else {
                       return false
                   }
                   return true
               }) {
                return data
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadJSON(atPath: path),
           keys.allSatisfy({ key in
               guard let rawValue = data[key],
                     Double(rawValue) != nil else {
                   return false
               }
               return true
           }) {
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
