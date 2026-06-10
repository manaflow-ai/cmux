import XCTest


// MARK: - Shared palette and settings UI helpers
extension CommandPaletteAllSurfacesUITests {
    func launchAndActivate(_ app: XCUIApplication) {
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

    func openCommandPaletteCommands(app: XCUIApplication) {
        let searchField = app.textFields["CommandPaletteSearchField"]
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(searchField.waitForExistence(timeout: 5.0), "Expected command palette search field")
        searchField.click()
    }

    func focusSettingsWindow(app: XCUIApplication) {
        app.typeKey(",", modifierFlags: [.command])
    }

    func toggleIsOn(_ element: XCUIElement) -> Bool {
        let value = String(describing: element.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "1" || value == "true" || value == "on"
    }

    func firstExistingElement(
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

    func commandPaletteResultRows(from snapshot: [String: Any]) -> [[String: Any]] {
        snapshot["results"] as? [[String: Any]] ?? []
    }

    func waitForCommandPaletteSnapshot(
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

    func commandPaletteSnapshot(windowId: String) -> [String: Any]? {
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

}
