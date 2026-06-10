import XCTest
import Foundation
import CoreGraphics


// MARK: - Right Sidebar Tests
extension BonsplitTabDragUITests {
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

}
