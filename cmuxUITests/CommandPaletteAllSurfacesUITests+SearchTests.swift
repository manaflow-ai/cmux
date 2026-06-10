import XCTest


// MARK: - Switcher search and results tests
extension CommandPaletteAllSurfacesUITests {
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

    private func openCommandPalette(app: XCUIApplication, query: String) {
        let searchField = app.textFields["CommandPaletteSearchField"]
        app.typeKey("p", modifierFlags: [.command])
        XCTAssertTrue(searchField.waitForExistence(timeout: 5.0), "Expected command palette search field")
        searchField.click()
        searchField.typeText(query)
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

}
