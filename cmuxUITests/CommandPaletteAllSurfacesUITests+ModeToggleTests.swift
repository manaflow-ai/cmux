import XCTest


// MARK: - Minimal mode and menu-bar-only toggle tests
extension CommandPaletteAllSurfacesUITests {
    func testMinimalModeToggleKeepsSettingsWindowFocused() throws {
        let app = XCUIApplication()
        let diagnosticsPath = "/tmp/cmux-ui-test-settings-focus-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SHOW_SETTINGS"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        launchAndActivate(app)

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 8.0) {
                app.windows.count >= 2
            },
            "Expected the main window and Settings window to be visible"
        )

        focusSettingsWindow(app: app)
        let toggle = try requireMinimalModeToggle(app: app)
        let initialState = toggleIsOn(toggle)

        toggle.click()

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 3.0) {
                toggle.exists && toggleIsOn(toggle) != initialState
            },
            "Expected the minimal mode setting to toggle"
        )

        let diagnostics = waitForDiagnostics(
            at: diagnosticsPath,
            timeout: 3.0
        ) { data in
            data["keyWindowIdentifier"] == "cmux.settings" && data["settingsWindowIsKey"] == "1"
        }

        XCTAssertEqual(
            diagnostics?["keyWindowIdentifier"],
            "cmux.settings",
            "Expected the Settings window to remain key after toggling minimal mode. diagnostics=\(diagnostics ?? [:])"
        )
        XCTAssertEqual(
            diagnostics?["settingsWindowIsKey"],
            "1",
            "Expected the Settings window to report itself as key after toggling minimal mode. diagnostics=\(diagnostics ?? [:])"
        )
        XCTAssertTrue(
            diagnosticsRemainStable(
                at: diagnosticsPath,
                duration: 0.8
            ) { data in
                data["keyWindowIdentifier"] == "cmux.settings" && data["settingsWindowIsKey"] == "1"
            },
            "Expected the Settings window to stay key after toggling minimal mode. diagnostics=\(loadDiagnostics(at: diagnosticsPath) ?? [:])"
        )

        app.typeKey("w", modifierFlags: [.command])

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 3.0) {
                app.windows.count == 1 && !toggle.exists
            },
            "Expected Cmd+W after toggling minimal mode to close the focused Settings window instead of defocusing back to the workspace window"
        )
    }

    func testMenuBarOnlyToggleKeepsSettingsWindowFocused() throws {
        let app = XCUIApplication()
        let diagnosticsPath = "/tmp/cmux-ui-test-menu-bar-only-focus-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        resetMenuBarOnlyDefault()
        addTeardownBlock {
            app.terminate()
            self.resetMenuBarOnlyDefault()
            try? FileManager.default.removeItem(atPath: diagnosticsPath)
        }
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-menuBarOnly", "false",
            "-showMenuBarExtra", "true",
        ]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SHOW_SETTINGS"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        launchAndActivate(app)

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 8.0) {
                app.windows.count >= 2
            },
            "Expected the main window and Settings window to be visible"
        )

        focusSettingsWindow(app: app)
        let toggle = try requireMenuBarOnlyToggle(app: app)
        if toggleIsOn(toggle) {
            toggle.click()
            XCTAssertTrue(
                sidebarHelpPollUntil(timeout: 3.0) {
                    toggle.exists && !toggleIsOn(toggle)
                },
                "Expected menu-bar-only mode to start from off for this test"
            )
        }

        toggle.click()

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 3.0) {
                toggle.exists && toggleIsOn(toggle)
            },
            "Expected the menu-bar-only setting to toggle on"
        )

        let diagnostics = waitForDiagnostics(
            at: diagnosticsPath,
            timeout: 3.0
        ) { data in
            data["keyWindowIdentifier"] == "cmux.settings" && data["settingsWindowIsKey"] == "1"
        }

        XCTAssertEqual(
            diagnostics?["keyWindowIdentifier"],
            "cmux.settings",
            "Expected the Settings window to remain key after enabling menu-bar-only mode. diagnostics=\(diagnostics ?? [:])"
        )
        XCTAssertEqual(
            diagnostics?["settingsWindowIsKey"],
            "1",
            "Expected the Settings window to report itself as key after enabling menu-bar-only mode. diagnostics=\(diagnostics ?? [:])"
        )
        XCTAssertTrue(
            diagnosticsRemainStable(
                at: diagnosticsPath,
                duration: 0.8
            ) { data in
                data["keyWindowIdentifier"] == "cmux.settings" && data["settingsWindowIsKey"] == "1"
            },
            "Expected the Settings window to stay key after enabling menu-bar-only mode. diagnostics=\(loadDiagnostics(at: diagnosticsPath) ?? [:])"
        )

        toggle.click()
        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 3.0) {
                toggle.exists && !toggleIsOn(toggle)
            },
            "Expected the menu-bar-only setting to toggle back off"
        )
    }

    func testCommandPaletteCanEnableAndDisableMinimalMode() throws {
        let app = XCUIApplication()
        configureSocketControlledLaunch(app, showSettingsWindow: true)
        app.launchArguments += ["-workspacePresentationMode", "standard"]
        launchAndActivate(app)

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 8.0) {
                app.windows.count >= 2
            },
            "Expected the main window and Settings window to be visible"
        )
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control socket at \(socketPath)")

        let mainWindowId = try XCTUnwrap(
            socketCommand("current_window")?.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        focusSettingsWindow(app: app)
        let toggle = try requireMinimalModeToggle(app: app)
        if toggleIsOn(toggle) {
            toggle.click()
            XCTAssertTrue(
                sidebarHelpPollUntil(timeout: 3.0) {
                    toggle.exists && !toggleIsOn(toggle)
                },
                "Expected the minimal mode setting to start from off for this test"
            )
        }

        XCTAssertEqual(socketCommand("focus_window \(mainWindowId)"), "OK")
        openCommandPaletteCommands(app: app)
        let searchField = app.textFields["CommandPaletteSearchField"]
        searchField.typeText("minimal")

        let enableSnapshot = try XCTUnwrap(
            waitForCommandPaletteSnapshot(windowId: mainWindowId, mode: "commands", query: "minimal", timeout: 5.0) { snapshot in
                self.commandPaletteResultRows(from: snapshot).contains { row in
                    (row["command_id"] as? String) == "palette.enableMinimalMode"
                }
            },
            "Expected the command palette to show Enable Minimal Mode while standard mode is active"
        )
        XCTAssertFalse(
            commandPaletteResultRows(from: enableSnapshot).contains { row in
                (row["command_id"] as? String) == "palette.disableMinimalMode"
            },
            "Expected Disable Minimal Mode to stay hidden while standard mode is active. snapshot=\(enableSnapshot)"
        )

        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        focusSettingsWindow(app: app)
        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 3.0) {
                toggle.exists && toggleIsOn(toggle)
            },
            "Expected running the command palette action to enable minimal mode"
        )

        XCTAssertEqual(socketCommand("focus_window \(mainWindowId)"), "OK")
        openCommandPaletteCommands(app: app)
        let disableSearchField = app.textFields["CommandPaletteSearchField"]
        disableSearchField.typeText("minimal")

        let disableSnapshot = try XCTUnwrap(
            waitForCommandPaletteSnapshot(windowId: mainWindowId, mode: "commands", query: "minimal", timeout: 5.0) { snapshot in
                self.commandPaletteResultRows(from: snapshot).contains { row in
                    (row["command_id"] as? String) == "palette.disableMinimalMode"
                }
            },
            "Expected the command palette to show Disable Minimal Mode while minimal mode is active"
        )
        XCTAssertFalse(
            commandPaletteResultRows(from: disableSnapshot).contains { row in
                (row["command_id"] as? String) == "palette.enableMinimalMode"
            },
            "Expected Enable Minimal Mode to stay hidden while minimal mode is active. snapshot=\(disableSnapshot)"
        )

        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        focusSettingsWindow(app: app)
        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 3.0) {
                toggle.exists && !toggleIsOn(toggle)
            },
            "Expected running the command palette action to disable minimal mode"
        )
    }

    private func requireMinimalModeToggle(app: XCUIApplication) throws -> XCUIElement {
        let scrollView = app.scrollViews.firstMatch
        let candidates = [
            app.switches["SettingsMinimalModeToggle"],
            app.checkBoxes["SettingsMinimalModeToggle"],
            app.buttons["SettingsMinimalModeToggle"],
            app.otherElements["SettingsMinimalModeToggle"],
            app.switches["Minimal Mode"],
            app.checkBoxes["Minimal Mode"],
            app.buttons["Minimal Mode"],
            app.otherElements["Minimal Mode"],
        ]

        for _ in 0..<8 {
            if let element = firstExistingElement(candidates: candidates, timeout: 0.4), element.isHittable {
                return element
            }
            if scrollView.exists {
                scrollView.swipeUp()
            }
        }

        throw XCTSkip("Could not find the minimal mode toggle")
    }

    private func requireMenuBarOnlyToggle(app: XCUIApplication) throws -> XCUIElement {
        let scrollView = app.scrollViews.firstMatch
        let candidates = [
            app.switches["SettingsMenuBarOnlyToggle"],
            app.checkBoxes["SettingsMenuBarOnlyToggle"],
            app.buttons["SettingsMenuBarOnlyToggle"],
            app.otherElements["SettingsMenuBarOnlyToggle"],
            app.switches["Menu Bar Only"],
            app.checkBoxes["Menu Bar Only"],
            app.buttons["Menu Bar Only"],
            app.otherElements["Menu Bar Only"],
        ]

        for _ in 0..<8 {
            if let element = firstExistingElement(candidates: candidates, timeout: 0.4), element.isHittable {
                return element
            }
            if scrollView.exists {
                scrollView.swipeUp()
            }
        }

        throw XCTSkip("Could not find the menu-bar-only toggle")
    }

    private func resetMenuBarOnlyDefault() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", debugDefaultsDomain, "menuBarOnly", "-bool", "false"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private func waitForDiagnostics(
        at path: String,
        timeout: TimeInterval,
        condition: ([String: String]) -> Bool
    ) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: String]?

        while Date() < deadline {
            if let data = loadDiagnostics(at: path) {
                last = data
                if condition(data) {
                    return data
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        return last
    }

    private func diagnosticsRemainStable(
        at path: String,
        duration: TimeInterval,
        condition: ([String: String]) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            guard let data = loadDiagnostics(at: path), condition(data) else {
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }

    private func loadDiagnostics(at path: String) -> [String: String]? {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: String] else {
            return nil
        }
        return object
    }

}
