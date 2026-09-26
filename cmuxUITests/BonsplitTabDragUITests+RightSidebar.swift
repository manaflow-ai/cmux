import XCTest

@MainActor
extension BonsplitTabDragUITests {
    func testRightSidebarCloseButtonKeepsPersistentTitlebarToggle() {
        let (app, dataPath) = launchConfiguredApp(
            presentationMode: .standard,
            showRightSidebar: true,
            alwaysShowShortcutHints: true
        )

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

        let titlebarToggle = rightSidebarTitlebarToggle(in: app)
        XCTAssertTrue(
            titlebarToggle.waitForExistence(timeout: 5.0),
            "Expected a persistent right-sidebar toggle in the titlebar."
        )
        XCTAssertTrue(
            waitForCondition(timeout: 3.0) { titlebarToggle.isHittable },
            "Expected the persistent right-sidebar titlebar toggle to be hittable. button=\(titlebarToggle.debugDescription)"
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
        // The shared hint defaults intentionally overlay the button. Keep the
        // pill inside its chrome lane; testRightSidebarHintsKeepControlFrames
        // separately checks that showing hints does not move the controls.
        XCTAssertLessThanOrEqual(
            shortcutHint.frame.maxY,
            closeButton.frame.maxY + 1,
            "Expected close shortcut hint to stay within the header control lane. hint=\(shortcutHint.frame) button=\(closeButton.frame)"
        )

        attachRightSidebarScreenshot(app, name: "Sidebar open with persistent toggle")
        closeButton.click()
        XCTAssertTrue(
            waitForCondition(timeout: 3.0) {
                !closeButton.exists || !closeButton.isHittable
            },
            "Expected clicking the right sidebar close button to hide the sidebar."
        )
        XCTAssertTrue(titlebarToggle.isHittable, "Closing the panel must leave its persistent toggle hittable.")
        attachRightSidebarScreenshot(app, name: "Sidebar hidden with persistent toggle")

        XCTAssertTrue(
            ensureAppForegroundForKeyboardInteraction(app, timeout: 6.0),
            "Expected cmux to be foreground before toggling the right sidebar shortcut. state=\(app.state.rawValue)"
        )
        titlebarToggle.click()
        XCTAssertTrue(
            waitForCondition(timeout: 3.0) {
                closeButton.exists && closeButton.isHittable
            },
            "Expected the persistent titlebar toggle to reopen the right sidebar."
        )
        attachRightSidebarScreenshot(app, name: "Sidebar reopened through persistent toggle")

        titlebarToggle.click()
        XCTAssertTrue(
            waitForCondition(timeout: 3.0) {
                !closeButton.exists || !closeButton.isHittable
            },
            "Expected the persistent titlebar toggle to hide the right sidebar."
        )
    }

    func testRightSidebarHintsKeepControlFrames() throws {
        var referenceFrames: [CGRect]?
        for showHints in [false, true] {
            let app = try launchRightSidebarChrome(alwaysShowShortcutHints: showHints)
            let controls = [
                app.buttons["RightSidebar.openAsPaneButton"],
                app.buttons["RightSidebar.closeButton"],
                rightSidebarTitlebarToggle(in: app),
            ]
            for control in controls {
                XCTAssertTrue(waitForCondition(timeout: 5) { control.exists && control.isHittable })
            }
            let windowOrigin = app.windows.firstMatch.frame.origin
            let frames = controls.map { $0.frame.offsetBy(dx: -windowOrigin.x, dy: -windowOrigin.y) }
            if let referenceFrames {
                for (frame, reference) in zip(frames, referenceFrames) {
                    XCTAssertEqual(frame.minX, reference.minX, accuracy: 1)
                    XCTAssertEqual(frame.minY, reference.minY, accuracy: 1)
                    XCTAssertEqual(frame.width, reference.width, accuracy: 1)
                    XCTAssertEqual(frame.height, reference.height, accuracy: 1)
                }
                XCTAssertTrue(app.staticTexts["rightSidebarCloseShortcutHint"].waitForExistence(timeout: 5))
            } else {
                referenceFrames = frames
                XCTAssertFalse(app.staticTexts["rightSidebarCloseShortcutHint"].exists)
            }
            attachRightSidebarScreenshot(app, name: "Shortcut hints \(showHints ? "shown" : "hidden")")
            app.terminate()
        }
    }

    func testRightSidebarTitlebarPresentationAndOptOut() throws {
        let configurations: [(WorkspacePresentationMode, Bool, Bool)] = [
            (.standard, true, true),
            (.standard, false, false),
            (.minimal, true, true),
        ]
        for (presentation, showToggle, showOpenAsPane) in configurations {
            let app = try launchRightSidebarChrome(
                presentationMode: presentation,
                showTitlebarToggle: showToggle,
                showOpenAsPaneButton: showOpenAsPane
            )
            let closeButton = app.buttons["RightSidebar.closeButton"]
            let openButton = app.buttons["RightSidebar.openAsPaneButton"]
            let toggle = rightSidebarTitlebarToggle(in: app)
            let expectsToggle = presentation == .standard && showToggle
            XCTAssertTrue(waitForCondition(timeout: 5) {
                (toggle.exists && toggle.isHittable) == expectsToggle
                    && openButton.exists == showOpenAsPane
            })
            XCTAssertTrue(closeButton.isHittable)
            if showOpenAsPane {
                XCTAssertTrue(openButton.isHittable)
                XCTAssertLessThan(openButton.frame.maxX, closeButton.frame.minX)
            }
            if expectsToggle {
                XCTAssertLessThan(closeButton.frame.maxX, toggle.frame.minX)
            }
            attachRightSidebarScreenshot(app, name: "\(presentation.rawValue) toggle=\(showToggle) openAsPane=\(showOpenAsPane)")
            closeButton.click()
            XCTAssertTrue(waitForCondition(timeout: 3) { !closeButton.exists || !closeButton.isHittable })
            app.terminate()
        }
    }

    func testRightSidebarFullscreenReleasesTitlebarReservation() throws {
        let app = try launchRightSidebarChrome()
        let window = app.windows.firstMatch
        let closeButton = app.buttons["RightSidebar.closeButton"]
        let toggle = rightSidebarTitlebarToggle(in: app)
        XCTAssertTrue(waitForCondition(timeout: 5) { toggle.exists && toggle.isHittable })
        let standardWindowFrame = window.frame
        let standardTrailingGap = window.frame.maxX - closeButton.frame.maxX

        app.typeKey("f", modifierFlags: [.control, .command])
        XCTAssertTrue(waitForCondition(timeout: 10) {
            window.frame.width > standardWindowFrame.width
                && (!toggle.exists || !toggle.isHittable)
                && closeButton.isHittable
                && window.frame.maxX - closeButton.frame.maxX < standardTrailingGap - 20
        }, "Fullscreen must hide the accessory and release its reserved header space.")
        attachRightSidebarScreenshot(app, name: "Fullscreen sidebar without titlebar reservation")

        app.typeKey("f", modifierFlags: [.control, .command])
        XCTAssertTrue(waitForCondition(timeout: 10) {
            toggle.exists && toggle.isHittable && closeButton.isHittable
                && abs(window.frame.width - standardWindowFrame.width) < 2
        })
        XCTAssertEqual(window.frame.maxX - closeButton.frame.maxX, standardTrailingGap, accuracy: 2)
        XCTAssertLessThan(closeButton.frame.maxX, toggle.frame.minX)
    }

    private func launchRightSidebarChrome(
        presentationMode: WorkspacePresentationMode = .standard,
        alwaysShowShortcutHints: Bool = false,
        showTitlebarToggle: Bool = true,
        showOpenAsPaneButton: Bool = true
    ) throws -> XCUIApplication {
        let (app, path) = launchConfiguredApp(
            presentationMode: presentationMode,
            showRightSidebar: true,
            alwaysShowShortcutHints: alwaysShowShortcutHints,
            showTitlebarToggle: showTitlebarToggle,
            showOpenAsPaneButton: showOpenAsPaneButton,
            windowSize: "944x604"
        )
        XCTAssertTrue(ensureAppRunningAfterLaunch(app, timeout: launchTimeout))
        let ready = try XCTUnwrap(waitForJSONKey("ready", equals: "1", atPath: path, timeout: setupTimeout))
        XCTAssertTrue((ready["setupError"] ?? "").isEmpty, "\(ready)")
        XCTAssertTrue(waitForCondition(timeout: 5) {
            app.buttons["RightSidebar.closeButton"].exists && app.buttons["RightSidebar.closeButton"].isHittable
        })
        return app
    }

    private func rightSidebarTitlebarToggle(in app: XCUIApplication) -> XCUIElement {
        // The accessory belongs to this window. Keep absence checks out of
        // unrelated application descendants such as dynamically populated menus.
        app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "titlebarControl.toggleRightSidebar").firstMatch
    }

    private func attachRightSidebarScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
