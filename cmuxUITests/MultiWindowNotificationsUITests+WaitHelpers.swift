import XCTest
import Foundation
import CoreGraphics


// MARK: - Launch, Wait, and Lookup Helpers
extension MultiWindowNotificationsUITests {
    func clickNotificationPopoverRowAndWaitForFocusChange(
        button: XCUIElement,
        app: XCUIApplication,
        from token: String?,
        timeout: TimeInterval
    ) -> Bool {
        // `.click()` on a button inside an NSPopover can be flaky on the VM; prefer a coordinate click
        // within the left side of the row (away from the clear button).
        if button.exists {
            let coord = button.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
            coord.click()
        } else {
            button.click()
        }

        // If the coordinate click was swallowed (popover auto-dismiss, etc), retry with a normal click.
        let firstDeadline = min(1.0, timeout)
        if waitForFocusChange(from: token, timeout: firstDeadline) {
            return true
        }
        button.click()
        return waitForFocusChange(from: token, timeout: max(0.0, timeout - firstDeadline))
    }

    func waitForWindowCount(atLeast count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            app.windows.count >= count
        }
    }

    func launchAllowingHeadlessBackgroundActivation(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }
    }

    func ensureAppRunningAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            app.state == .runningForeground || app.state == .runningBackground
        }
    }

    func ensureAppForegroundForInteraction(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
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

    func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func waitForFocusChange(from token: String?, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let data = self.loadData(),
                  let current = data["focusToken"],
                  !current.isEmpty else {
                return false
            }
            return current != token
        }
    }

    func waitForData(keys: [String], timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let data = self.loadData() else { return false }
            return keys.allSatisfy { (data[$0] ?? "").isEmpty == false }
        }
    }

    func waitForDataMatch(timeout: TimeInterval, predicate: @escaping ([String: String]) -> Bool) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let data = self.loadData() else { return false }
            return predicate(data)
        }
    }

    func waitForNotification(title: String, timeout: TimeInterval) -> [String: Any]? {
        var matched: [String: Any]?
        _ = waitForCondition(timeout: timeout) {
            guard let rows = self.notificationRowsViaCLI() else { return false }
            matched = rows.first(where: { $0["title"] as? String == title })
            return matched != nil
        }
        return matched
    }

    func waitForNotificationRead(_ id: String, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let rows = self.notificationRowsViaCLI(),
                  let row = rows.first(where: { $0["id"] as? String == id }) else {
                return false
            }
            return row["is_read"] as? Bool == true
        }
    }

    private func notificationRowsViaCLI() -> [[String: Any]]? {
        let result = runCmuxCommand(
            socketPath: socketPath,
            arguments: ["list-notifications", "--json", "--id-format", "uuids"],
            responseTimeoutSeconds: 4.0,
            cliStrategy: .bundledOnly
        )
        guard result.terminationStatus == 0 else { return nil }
        guard let data = result.stdout.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [[String: Any]]
    }

    func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    func waitForSocketPong(timeout: TimeInterval) -> String? {
        var lastResponse: String?
        _ = waitForCondition(timeout: timeout) {
            lastResponse = self.socketCommand("ping")
            return lastResponse == "PONG"
        }
        return lastResponse == "PONG" ? "PONG" : (socketCommand("ping") ?? lastResponse)
    }

    func waitForCommandCompletionWhileBackgrounded(
        statusPath: String,
        app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        var sawCompletion = false
        let completed = waitForCondition(timeout: timeout) {
            if app.state == .runningForeground {
                return false
            }
            if FileManager.default.fileExists(atPath: statusPath) {
                sawCompletion = true
                return true
            }
            return false
        }
        guard completed || sawCompletion || FileManager.default.fileExists(atPath: statusPath) else {
            return false
        }

        return waitForCondition(timeout: 0.75) {
            app.state != .runningForeground
        }
    }

    func waitForAppToLeaveForeground(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            app.state != .runningForeground
        }
    }

    private func firstSurfaceId(forWorkspaceId workspaceId: String) -> String? {
        guard let response = socketCommand("list_surfaces \(workspaceId)"),
              !response.isEmpty,
              !response.hasPrefix("ERROR"),
              response != "No surfaces" else {
            return nil
        }

        for line in response.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let candidate = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if UUID(uuidString: candidate) != nil {
                return candidate
            }
        }
        return nil
    }

    func waitForCondition(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() },
            object: nil
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func firstSurfaceIdViaCLI(forWorkspaceId workspaceId: String) -> String? {
        guard let paneId = firstPaneIdViaCLI(forWorkspaceId: workspaceId) else {
            return firstSurfaceId(forWorkspaceId: workspaceId)
        }
        let result = runCmuxCommand(
            socketPath: socketPath,
            arguments: [
                "list-pane-surfaces",
                "--workspace",
                workspaceId,
                "--pane",
                paneId,
                "--id-format",
                "uuids"
            ],
            responseTimeoutSeconds: 3.0
        )
        guard result.terminationStatus == 0 else {
            if isSocketPermissionFailure(result.stderr) {
                return firstSurfaceId(forWorkspaceId: workspaceId)
            }
            return nil
        }
        return firstHandle(in: result.stdout)
    }

    private func firstPaneIdViaCLI(forWorkspaceId workspaceId: String) -> String? {
        let result = runCmuxCommand(
            socketPath: socketPath,
            arguments: [
                "list-panes",
                "--workspace",
                workspaceId,
                "--id-format",
                "uuids"
            ],
            responseTimeoutSeconds: 3.0
        )
        guard result.terminationStatus == 0 else {
            if isSocketPermissionFailure(result.stderr) {
                return nil
            }
            return nil
        }
        return firstHandle(in: result.stdout)
    }

    private func firstHandle(in output: String) -> String? {
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("No ") else { continue }
            if line.hasPrefix("* ") || line.hasPrefix("  ") {
                line = String(line.dropFirst(2))
            }
            guard let token = line.split(whereSeparator: \.isWhitespace).first else { continue }
            return String(token)
        }
        return nil
    }

}
