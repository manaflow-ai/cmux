import XCTest

private func sidebarHelpPollUntil(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.05,
    condition: () -> Bool
) -> Bool {
    let start = ProcessInfo.processInfo.systemUptime
    while true {
        if condition() {
            return true
        }
        if (ProcessInfo.processInfo.systemUptime - start) >= timeout {
            return false
        }
        RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
    }
}

final class SidebarHelpMenuUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testHelpMenuOpensKeyboardShortcutsSection() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        launchAndActivate(app)

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))

        let helpButton = requireElement(
            candidates: helpButtonCandidates(in: app),
            timeout: 6.0,
            description: "sidebar help button"
        )
        helpButton.click()

        let keyboardShortcutsItem = requireElement(
            candidates: helpMenuItemCandidates(in: app, identifier: "SidebarHelpMenuOptionKeyboardShortcuts", title: "Keyboard Shortcuts"),
            timeout: 3.0,
            description: "Keyboard Shortcuts help menu item"
        )
        keyboardShortcutsItem.click()

        XCTAssertTrue(app.staticTexts["ShortcutRecordingHint"].waitForExistence(timeout: 6.0))
    }

    func testHelpMenuCheckForUpdatesTriggersSidebarUpdatePill() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_FEED_URL"] = "https://cmux.test/appcast.xml"
        app.launchEnvironment["CMUX_UI_TEST_FEED_MODE"] = "available"
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_VERSION"] = "9.9.9"
        app.launchEnvironment["CMUX_UI_TEST_AUTO_ALLOW_PERMISSION"] = "1"
        launchAndActivate(app)

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))

        let helpButton = requireElement(
            candidates: helpButtonCandidates(in: app),
            timeout: 6.0,
            description: "sidebar help button"
        )
        helpButton.click()

        let checkForUpdatesItem = requireElement(
            candidates: helpMenuItemCandidates(in: app, identifier: "SidebarHelpMenuOptionCheckForUpdates", title: "Check for Updates"),
            timeout: 3.0,
            description: "Check for Updates help menu item"
        )
        checkForUpdatesItem.click()

        let updatePill = app.buttons["UpdatePill"]
        XCTAssertTrue(updatePill.waitForExistence(timeout: 6.0))
        XCTAssertEqual(updatePill.label, "Update Available: 9.9.9")
    }

    func testHelpMenuSendFeedbackOpensComposerSheet() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        launchAndActivate(app)

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))

        let helpButton = requireElement(
            candidates: helpButtonCandidates(in: app),
            timeout: 6.0,
            description: "sidebar help button"
        )
        helpButton.click()

        let sendFeedbackItem = requireElement(
            candidates: helpMenuItemCandidates(in: app, identifier: "SidebarHelpMenuOptionSendFeedback", title: "Send Feedback"),
            timeout: 3.0,
            description: "Send Feedback help menu item"
        )
        sendFeedbackItem.click()

        XCTAssertTrue(app.staticTexts["Send Feedback"].waitForExistence(timeout: 3.0))
        XCTAssertTrue(
            firstExistingElement(
                candidates: [
                    app.textFields["SidebarFeedbackEmailField"],
                    app.textFields["Your Email"],
                ],
                timeout: 2.0
            ) != nil
        )
        XCTAssertTrue(
            firstExistingElement(
                candidates: [
                    app.buttons["SidebarFeedbackAttachButton"],
                    app.buttons["Attach Images"],
                ],
                timeout: 2.0
            ) != nil
        )
        XCTAssertTrue(
            firstExistingElement(
                candidates: [
                    app.buttons["SidebarFeedbackSendButton"],
                    app.buttons["Send"],
                ],
                timeout: 2.0
            ) != nil
        )
        XCTAssertTrue(
            app.staticTexts[
                "A human will read this! You can also reach us at founders@manaflow.com."
            ].waitForExistence(timeout: 2.0)
        )

        let messageEditor = requireElement(
            candidates: [
                app.textViews["SidebarFeedbackMessageEditor"],
                app.scrollViews["SidebarFeedbackMessageEditor"],
                app.otherElements["SidebarFeedbackMessageEditor"],
                app.textViews["Message"],
            ],
            timeout: 2.0,
            description: "feedback message editor"
        )
        messageEditor.click()
        app.typeText("hello")
        XCTAssertTrue(app.staticTexts["5/4000"].waitForExistence(timeout: 2.0))
    }

    private func waitForWindowCount(atLeast count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        sidebarHelpPollUntil(timeout: timeout) {
            app.windows.count >= count
        }
    }

    private func helpButtonCandidates(in app: XCUIApplication) -> [XCUIElement] {
        let sidebar = app.otherElements["Sidebar"]
        return [
            app.buttons["SidebarHelpMenuButton"],
            app.buttons["Help"],
            sidebar.buttons["SidebarHelpMenuButton"],
            sidebar.buttons["Help"],
        ]
    }

    private func helpMenuItemCandidates(
        in app: XCUIApplication,
        identifier: String,
        title: String
    ) -> [XCUIElement] {
        [
            app.buttons[identifier],
            app.buttons[title],
        ]
    }

    private func firstExistingElement(
        candidates: [XCUIElement],
        timeout: TimeInterval
    ) -> XCUIElement? {
        var match: XCUIElement?
        let found = sidebarHelpPollUntil(timeout: timeout) {
            for candidate in candidates where candidate.exists {
                match = candidate
                return true
            }
            return false
        }
        return found ? match : nil
    }

    private func requireElement(
        candidates: [XCUIElement],
        timeout: TimeInterval,
        description: String
    ) -> XCUIElement {
        guard let element = firstExistingElement(candidates: candidates, timeout: timeout) else {
            XCTFail("Expected \(description) to exist")
            return candidates[0]
        }
        return element
    }

    private func launchAndActivate(_ app: XCUIApplication, activateTimeout: TimeInterval = 2.0) {
        app.launch()
        let activated = sidebarHelpPollUntil(timeout: activateTimeout) {
            guard app.state != .runningForeground else {
                return true
            }
            app.activate()
            return app.state == .runningForeground
        }
        if !activated {
            app.activate()
        }
        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 2.0) { app.state == .runningForeground },
            "App did not reach runningForeground before UI interactions"
        )
    }
}

final class FeedbackComposerShortcutUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCmdOptionFOpensFeedbackComposer() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launch()
        app.activate()

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 6.0) {
                app.windows.count >= 1
            }
        )

        app.typeKey("f", modifierFlags: [.command, .option])

        XCTAssertTrue(app.staticTexts["Send Feedback"].waitForExistence(timeout: 3.0))
        XCTAssertTrue(
            app.textFields["SidebarFeedbackEmailField"].waitForExistence(timeout: 2.0)
                || app.textFields["Your Email"].waitForExistence(timeout: 2.0)
        )
    }

    func testCmdOptionFWorksWithHiddenSidebar() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launch()
        app.activate()

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 6.0) {
                app.windows.count >= 1
            }
        )

        app.typeKey("b", modifierFlags: [.command])

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 3.0) {
                !app.buttons["SidebarHelpMenuButton"].exists && !app.buttons["Help"].exists
            }
        )

        app.typeKey("f", modifierFlags: [.command, .option])

        XCTAssertTrue(app.staticTexts["Send Feedback"].waitForExistence(timeout: 3.0))
    }

    func testCmdOptionFWorksFromSettingsWindow() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SHOW_SETTINGS"] = "1"
        app.launch()
        app.activate()

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 6.0) {
                app.windows.count >= 2
            }
        )

        app.typeKey("f", modifierFlags: [.command, .option])

        XCTAssertTrue(app.staticTexts["Send Feedback"].waitForExistence(timeout: 3.0))
        XCTAssertTrue(
            app.textFields["SidebarFeedbackEmailField"].waitForExistence(timeout: 2.0)
                || app.textFields["Your Email"].waitForExistence(timeout: 2.0)
        )
    }
}

final class CommandPaletteAllSurfacesUITests: XCTestCase {
    private var socketPath = ""
    private let hiddenSurfaceToken = "cmux-command-palette-hidden-surface"
    private let visibleSurfaceToken = "cmux-command-palette-visible-surface"
    private let noMatchWorkspaceQuery = "cmux-command-palette-no-match"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-ui-test-command-palette-\(UUID().uuidString).sock"
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    private func configureSocketControlledLaunch(
        _ app: XCUIApplication,
        showSettingsWindow: Bool = false
    ) {
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        if showSettingsWindow {
            app.launchEnvironment["CMUX_UI_TEST_SHOW_SETTINGS"] = "1"
        }
    }

    func testCmdShiftPBackspaceReturnsToWorkspaceResults() throws {
        let app = XCUIApplication()
        configureSocketControlledLaunch(app)
        launchAndActivate(app)

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 8.0) {
                app.windows.count >= 1
            },
            "Expected the main window to be visible"
        )
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control socket at \(socketPath)")

        let mainWindowId = try XCTUnwrap(
            socketCommand("current_window")?.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        openCommandPaletteCommands(app: app)

        _ = try XCTUnwrap(
            waitForCommandPaletteSnapshot(windowId: mainWindowId, mode: "commands", query: "", timeout: 5.0) { snapshot in
                self.commandPaletteResultRows(from: snapshot).contains { row in
                    let commandId = row["command_id"] as? String ?? ""
                    return !commandId.hasPrefix("switcher.")
                }
            }
        )

        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])

        let switcherSnapshot = try XCTUnwrap(
            waitForCommandPaletteSnapshot(windowId: mainWindowId, mode: "switcher", query: "", timeout: 5.0) { snapshot in
                self.commandPaletteResultRows(from: snapshot).contains { row in
                    let commandId = row["command_id"] as? String ?? ""
                    return commandId.hasPrefix("switcher.workspace.")
                }
            }
        )

        XCTAssertTrue(
            commandPaletteResultRows(from: switcherSnapshot).contains { row in
                let commandId = row["command_id"] as? String ?? ""
                return commandId.hasPrefix("switcher.workspace.")
            },
            "Expected deleting the command prefix to restore workspace rows. snapshot=\(switcherSnapshot)"
        )

        let rows = commandPaletteResultRows(from: switcherSnapshot)
        let firstRowCommandId = rows.first?["command_id"] as? String ?? ""
        XCTAssertTrue(
            firstRowCommandId.hasPrefix("switcher.workspace."),
            "Expected the first restored row to be a workspace. snapshot=\(switcherSnapshot)"
        )

        let firstWorkspaceRow = try XCTUnwrap(
            rows.first(where: { row in
                let commandId = row["command_id"] as? String ?? ""
                return commandId.hasPrefix("switcher.workspace.")
            }),
            "Expected a workspace row in the restored switcher results. snapshot=\(switcherSnapshot)"
        )
        let workspaceTitle = try XCTUnwrap(
            firstWorkspaceRow["title"] as? String,
            "Expected the restored workspace row to include a title. snapshot=\(switcherSnapshot)"
        )
        let workspaceLabel = app.staticTexts[workspaceTitle].firstMatch
        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 2.0) {
                workspaceLabel.exists && workspaceLabel.isHittable
            },
            "Expected the restored workspace row to be visibly rendered. title=\(workspaceTitle) snapshot=\(switcherSnapshot)"
        )

        let staleCommandLabel = app.staticTexts["Close Other Workspaces"].firstMatch
        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 2.0) {
                !staleCommandLabel.exists || !staleCommandLabel.isHittable
            },
            "Expected the stale command row to disappear after deleting the command prefix. snapshot=\(switcherSnapshot)"
        )
    }

    func testCmdShiftPCheckQueryPrefersCheckForUpdatesBeforeAttemptUpdate() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        launchAndActivate(app)

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 8.0) {
                app.windows.count >= 1
            },
            "Expected the main window to be visible"
        )

        openCommandPaletteCommands(app: app)
        let searchField = app.textFields["CommandPaletteSearchField"]
        searchField.typeText("check")

        let row0 = app.descendants(matching: .any).matching(identifier: "CommandPaletteResultRow.0").firstMatch
        let row1 = app.descendants(matching: .any).matching(identifier: "CommandPaletteResultRow.1").firstMatch

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 5.0) {
                row0.exists &&
                    row1.exists &&
                    (row0.value as? String) == "palette.checkForUpdates" &&
                    (row1.value as? String) == "palette.attemptUpdate"
            },
            "Expected the check query to rank Check for Updates before Attempt Update. row0=\(String(describing: row0.value)) row1=\(String(describing: row1.value))"
        )
        XCTAssertEqual(row0.value as? String, "palette.checkForUpdates")
        XCTAssertEqual(row1.value as? String, "palette.attemptUpdate")
    }

    func testCmdPSearchCanIncludeSurfacesFromOtherWorkspacesWhenEnabled() throws {
        let app = XCUIApplication()
        configureSocketControlledLaunch(app, showSettingsWindow: true)
        launchAndActivate(app)

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 8.0) {
                app.windows.count >= 2
            },
            "Expected the main window and Settings window to be visible"
        )
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control socket at \(socketPath)")

        let mainWindowId = try XCTUnwrap(socketCommand("current_window")?.trimmingCharacters(in: .whitespacesAndNewlines))
        let secondaryWorkspaceId = try XCTUnwrap(okUUID(from: socketCommand("new_workspace")))
        let initialSurfaceId = try XCTUnwrap(waitForSurfaceIDs(minimumCount: 1, timeout: 5.0).first)
        let hiddenSurfaceId = try XCTUnwrap(okUUID(from: socketCommand("new_surface --type=terminal")))

        XCTAssertEqual(
            socketCommand("report_pwd /tmp/\(hiddenSurfaceToken) --tab=\(secondaryWorkspaceId) --panel=\(hiddenSurfaceId)"),
            "OK"
        )
        XCTAssertEqual(socketCommand("focus_surface \(initialSurfaceId)"), "OK")
        XCTAssertEqual(
            socketCommand("report_pwd /tmp/\(visibleSurfaceToken) --tab=\(secondaryWorkspaceId) --panel=\(initialSurfaceId)"),
            "OK"
        )
        XCTAssertEqual(socketCommand("select_workspace 0"), "OK")
        XCTAssertEqual(socketCommand("focus_window \(mainWindowId)"), "OK")

        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        openCommandPalette(app: app, query: hiddenSurfaceToken)
        let disabledSnapshot = try XCTUnwrap(
            waitForCommandPaletteSnapshot(windowId: mainWindowId, query: hiddenSurfaceToken, timeout: 5.0) { snapshot in
                self.commandPaletteResultRows(from: snapshot).isEmpty
            }
        )
        XCTAssertEqual(commandPaletteResultRows(from: disabledSnapshot).count, 0)
        dismissCommandPalette(app: app)

        focusSettingsWindow(app: app)
        let toggle = try requireSearchAllSurfacesToggle(app: app)
        if !toggleIsOn(toggle) {
            toggle.click()
        }
        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 3.0) {
                toggle.exists && toggleIsOn(toggle)
            },
            "Expected the all-surfaces search setting to be enabled"
        )

        XCTAssertEqual(socketCommand("focus_window \(mainWindowId)"), "OK")

        openCommandPalette(app: app, query: hiddenSurfaceToken)
        let enabledSnapshot = try XCTUnwrap(
            waitForCommandPaletteSnapshot(windowId: mainWindowId, query: hiddenSurfaceToken, timeout: 5.0) { snapshot in
                self.commandPaletteResultRows(from: snapshot).contains { row in
                    let commandId = row["command_id"] as? String ?? ""
                    let trailingLabel = row["trailing_label"] as? String ?? ""
                    return commandId.hasPrefix("switcher.surface.") && trailingLabel == "Terminal"
                }
            }
        )

        XCTAssertTrue(
            commandPaletteResultRows(from: enabledSnapshot).contains { row in
                let commandId = row["command_id"] as? String ?? ""
                let trailingLabel = row["trailing_label"] as? String ?? ""
                return commandId.hasPrefix("switcher.surface.") && trailingLabel == "Terminal"
            },
            "Expected Cmd+P to surface the hidden terminal when all-surfaces search is enabled. snapshot=\(enabledSnapshot)"
        )
    }

    func testSwitcherEmptyStateDoesNotBlinkWhileRefiningNoMatchQuery() throws {
        let app = XCUIApplication()
        configureSocketControlledLaunch(app)
        launchAndActivate(app)

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 8.0) {
                app.windows.count >= 1
            },
            "Expected the main window to be visible"
        )
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control socket at \(socketPath)")

        let mainWindowId = try XCTUnwrap(
            socketCommand("current_window")?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        try seedWorkspaceSwitcherCorpus(workspaceCount: 96)

        let searchField = app.textFields["CommandPaletteSearchField"]
        app.typeKey("p", modifierFlags: [.command])
        XCTAssertTrue(searchField.waitForExistence(timeout: 5.0), "Expected command palette search field")
        searchField.click()

        let seededWorkspaceTitlePrefix = "\(noMatchWorkspaceQuery)-"
        try debugTypeText(noMatchWorkspaceQuery)

        let seededSnapshot = try XCTUnwrap(
            waitForCommandPaletteSnapshot(windowId: mainWindowId, query: noMatchWorkspaceQuery, timeout: 5.0) { snapshot in
                self.commandPaletteResultRows(from: snapshot).contains { row in
                    ((row["title"] as? String) ?? "").hasPrefix(seededWorkspaceTitlePrefix)
                }
            },
            "Expected seeded workspace titles to be indexed before exercising the no-match path"
        )
        XCTAssertTrue(
            commandPaletteResultRows(from: seededSnapshot).contains { row in
                ((row["title"] as? String) ?? "").hasPrefix(seededWorkspaceTitlePrefix)
            },
            "Expected the seeded workspace corpus to be searchable before the no-match assertion. snapshot=\(seededSnapshot)"
        )

        try clearCommandPaletteSearchField(app: app, windowId: mainWindowId)
        try debugTypeText(String(repeating: "z", count: 8))

        let emptyLabel = app.staticTexts["No workspaces match your search."].firstMatch
        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 5.0) {
                guard emptyLabel.exists else { return false }
                guard let snapshot = commandPaletteSnapshot(windowId: mainWindowId) else { return false }
                return (snapshot["query"] as? String) == String(repeating: "z", count: 8)
                    && self.commandPaletteResultRows(from: snapshot).isEmpty
            },
            "Expected the switcher to reach a visible no-results state before refining the query"
        )

        try debugTypeText("z")

        let refinedQuery = String(repeating: "z", count: 9)
        var refinedSnapshot: [String: Any]?
        var emptyLabelDisappearedWhileRefining = false
        let refinedQueryResolvedWhileKeepingEmptyStateVisible = sidebarHelpPollUntil(
            timeout: 5.0,
            pollInterval: 0.01
        ) {
            guard emptyLabel.exists else {
                emptyLabelDisappearedWhileRefining = true
                return false
            }
            guard let snapshot = commandPaletteSnapshot(windowId: mainWindowId) else { return false }
            guard (snapshot["query"] as? String) == refinedQuery else { return false }
            guard self.commandPaletteResultRows(from: snapshot).isEmpty else { return false }
            refinedSnapshot = snapshot
            return true
        }
        XCTAssertFalse(
            emptyLabelDisappearedWhileRefining,
            "Expected refining an already-empty switcher query to keep the empty-state label visible"
        )
        XCTAssertTrue(
            refinedQueryResolvedWhileKeepingEmptyStateVisible,
            "Expected the refined no-match query to resolve while keeping the empty-state label visible"
        )
        let resolvedRefinedSnapshot = try XCTUnwrap(refinedSnapshot)
        XCTAssertTrue(
            commandPaletteResultRows(from: resolvedRefinedSnapshot).isEmpty,
            "Expected the refined no-match query to stay empty. snapshot=\(resolvedRefinedSnapshot)"
        )
    }

    private func launchAndActivate(_ app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 4.0) {
                guard app.state != .runningForeground else { return true }
                app.activate()
                return app.state == .runningForeground
            },
            "App did not reach runningForeground before UI interactions"
        )
    }

    private func openCommandPalette(app: XCUIApplication, query: String) {
        let searchField = app.textFields["CommandPaletteSearchField"]
        app.typeKey("p", modifierFlags: [.command])
        XCTAssertTrue(searchField.waitForExistence(timeout: 5.0), "Expected command palette search field")
        searchField.click()
        searchField.typeText(query)
    }

    private func openCommandPaletteCommands(app: XCUIApplication) {
        let searchField = app.textFields["CommandPaletteSearchField"]
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(searchField.waitForExistence(timeout: 5.0), "Expected command palette search field")
        searchField.click()
    }

    private func dismissCommandPalette(app: XCUIApplication) {
        let searchField = app.textFields["CommandPaletteSearchField"]
        for _ in 0..<2 {
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            if sidebarHelpPollUntil(timeout: 1.0, condition: { !searchField.exists }) {
                return
            }
        }
        XCTAssertFalse(searchField.exists, "Expected command palette to dismiss")
    }

    private func focusSettingsWindow(app: XCUIApplication) {
        app.typeKey(",", modifierFlags: [.command])
    }

    private func requireSearchAllSurfacesToggle(app: XCUIApplication) throws -> XCUIElement {
        let toggleId = "CommandPaletteSearchAllSurfacesToggle"
        let scrollView = app.scrollViews.firstMatch
        let candidates = [
            app.switches[toggleId],
            app.checkBoxes[toggleId],
            app.buttons[toggleId],
            app.otherElements[toggleId],
        ]

        for _ in 0..<8 {
            if let element = firstExistingElement(candidates: candidates, timeout: 0.4), element.isHittable {
                return element
            }
            if scrollView.exists {
                scrollView.swipeUp()
            }
        }

        throw XCTSkip("Could not find the command palette all-surfaces toggle")
    }

    private func toggleIsOn(_ element: XCUIElement) -> Bool {
        let value = String(describing: element.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "1" || value == "true" || value == "on"
    }

    private func firstExistingElement(
        candidates: [XCUIElement],
        timeout: TimeInterval
    ) -> XCUIElement? {
        var match: XCUIElement?
        let found = sidebarHelpPollUntil(timeout: timeout) {
            for candidate in candidates where candidate.exists {
                match = candidate
                return true
            }
            return false
        }
        return found ? match : nil
    }

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        sidebarHelpPollUntil(timeout: timeout) {
            socketCommand("ping") == "PONG"
        }
    }

    private func waitForSurfaceIDs(minimumCount: Int, timeout: TimeInterval) -> [String] {
        var ids: [String] = []
        let found = sidebarHelpPollUntil(timeout: timeout) {
            ids = surfaceIDs()
            return ids.count >= minimumCount
        }
        return found ? ids : surfaceIDs()
    }

    private func surfaceIDs() -> [String] {
        guard let response = socketCommand("list_surfaces"), !response.isEmpty, !response.hasPrefix("No surfaces") else {
            return []
        }
        return response
            .split(separator: "\n")
            .compactMap { line in
                guard let range = line.range(of: ": ") else { return nil }
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    private func okUUID(from response: String?) -> String? {
        guard let response, response.hasPrefix("OK ") else { return nil }
        let value = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: value) != nil ? value : nil
    }

    private func debugTypeText(_ text: String) throws {
        let response = try XCTUnwrap(
            socketJSON(
                method: "debug.type",
                params: ["text": text]
            ),
            "Expected a response from debug.type"
        )
        XCTAssertEqual(response["ok"] as? Bool, true, "Expected debug.type to succeed. response=\(response)")
    }

    private func clearCommandPaletteSearchField(app: XCUIApplication, windowId: String) throws {
        let searchField = app.textFields["CommandPaletteSearchField"]
        searchField.click()
        app.typeKey("a", modifierFlags: [.command])
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        let clearedSnapshot = try XCTUnwrap(
            waitForCommandPaletteSnapshot(windowId: windowId, query: "", timeout: 5.0),
            "Expected the command palette query to clear"
        )
        XCTAssertEqual(
            clearedSnapshot["query"] as? String,
            "",
            "Expected the command palette query to clear"
        )
    }

    private func seedWorkspaceSwitcherCorpus(workspaceCount: Int) throws {
        guard workspaceCount > 1 else { return }

        for index in 1..<workspaceCount {
            let workspaceId = try XCTUnwrap(
                okUUID(from: socketCommand("new_workspace")),
                "Expected new_workspace to return a workspace ID"
            )
            let title = seededWorkspaceTitle(index: index)
            let response = try XCTUnwrap(
                socketJSON(
                    method: "workspace.rename",
                    params: [
                        "workspace_id": workspaceId,
                        "title": title,
                    ]
                ),
                "Expected a response from workspace.rename"
            )
            XCTAssertEqual(
                response["ok"] as? Bool,
                true,
                "Expected workspace.rename to succeed. response=\(response)"
            )
        }

        XCTAssertEqual(socketCommand("select_workspace 0"), "OK")
    }

    private func seededWorkspaceTitle(index: Int) -> String {
        "\(noMatchWorkspaceQuery)-\(index)-" + String(repeating: "workspace-", count: 8)
    }

    private func socketCommand(_ command: String) -> String? {
        ControlSocketClient(path: socketPath, responseTimeout: 2.0).sendLine(command)
    }

    private func commandPaletteResultRows(from snapshot: [String: Any]) -> [[String: Any]] {
        snapshot["results"] as? [[String: Any]] ?? []
    }

    private func waitForCommandPaletteSnapshot(
        windowId: String,
        mode: String = "switcher",
        query: String,
        timeout: TimeInterval,
        predicate: (([String: Any]) -> Bool)? = nil
    ) -> [String: Any]? {
        var latest: [String: Any]?
        let matched = sidebarHelpPollUntil(timeout: timeout) {
            guard let snapshot = commandPaletteSnapshot(windowId: windowId) else { return false }
            latest = snapshot
            guard (snapshot["visible"] as? Bool) == true else { return false }
            guard (snapshot["mode"] as? String) == mode else { return false }
            guard (snapshot["query"] as? String) == query else { return false }
            return predicate?(snapshot) ?? true
        }
        return matched ? latest : nil
    }

    private func commandPaletteSnapshot(windowId: String) -> [String: Any]? {
        let envelope = socketJSON(
            method: "debug.command_palette.results",
            params: [
                "window_id": windowId,
                "limit": 20,
            ]
        )
        guard let ok = envelope?["ok"] as? Bool, ok else { return nil }
        return envelope?["result"] as? [String: Any]
    }

    private func socketJSON(method: String, params: [String: Any]) -> [String: Any]? {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        return ControlSocketClient(path: socketPath, responseTimeout: 2.0).sendJSON(request)
    }

    private final class ControlSocketClient {
        private let path: String
        private let responseTimeout: TimeInterval

        init(path: String, responseTimeout: TimeInterval) {
            self.path = path
            self.responseTimeout = responseTimeout
        }

        func sendJSON(_ object: [String: Any]) -> [String: Any]? {
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let line = String(data: data, encoding: .utf8),
                  let response = sendLine(line),
                  let responseData = response.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                return nil
            }
            return parsed
        }

        func sendLine(_ line: String) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

#if os(macOS)
            var noSigPipe: Int32 = 1
            _ = withUnsafePointer(to: &noSigPipe) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    ptr,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
#endif

            var addr = sockaddr_un()
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)

            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= maxLen else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                memset(raw, 0, maxLen)
                for index in 0..<bytes.count {
                    raw[index] = bytes[index]
                }
            }

            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            let addrLen = socklen_t(pathOffset + bytes.count)
#if os(macOS)
            addr.sun_len = UInt8(min(Int(addrLen), 255))
#endif

            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, addrLen)
                }
            }
            guard connected == 0 else { return nil }

            let payload = line + "\n"
            let wrote: Bool = payload.withCString { cString in
                var remaining = strlen(cString)
                var pointer = UnsafeRawPointer(cString)
                while remaining > 0 {
                    let written = write(fd, pointer, remaining)
                    if written <= 0 { return false }
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                }
                return true
            }
            guard wrote else { return nil }

            let deadline = Date().addingTimeInterval(responseTimeout)
            var buffer = [UInt8](repeating: 0, count: 4096)
            var accumulator = ""
            while Date() < deadline {
                var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pollDescriptor, 1, 100)
                if ready < 0 {
                    return nil
                }
                if ready == 0 {
                    continue
                }
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                if let chunk = String(bytes: buffer[0..<count], encoding: .utf8) {
                    accumulator.append(chunk)
                    if let newline = accumulator.firstIndex(of: "\n") {
                        return String(accumulator[..<newline])
                    }
                }
            }

            return accumulator.isEmpty ? nil : accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
