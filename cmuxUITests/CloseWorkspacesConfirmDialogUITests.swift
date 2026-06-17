import XCTest
import Foundation

final class CloseWorkspacesConfirmDialogUITests: XCTestCase {
    private var socketPath = ""
    private var diagnosticsPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-ui-test-close-workspaces-\(UUID().uuidString).sock"
        diagnosticsPath = "/tmp/cmux-ui-test-close-workspaces-\(UUID().uuidString).json"
        launchTag = "ui-tests-close-workspaces-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: taggedSocketPath())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: taggedSocketPath())
        super.tearDown()
    }

    func testCommandPaletteCloseOtherWorkspacesShowsSingleSummaryDialog() {
        let app = XCUIApplication()
        configureSocketLaunchEnvironment(app)
        app.launchEnvironment["CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] = "1"
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for close-workspaces confirmation test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(
            waitForSocketPong(timeout: 12.0),
            "Expected control socket to respond at \(socketPath). diagnostics=\(loadJSON(atPath: diagnosticsPath) ?? [:])"
        )

        XCTAssertEqual(socketCommand("new_workspace")?.prefix(2), "OK")
        XCTAssertEqual(socketCommand("new_workspace")?.prefix(2), "OK")
        XCTAssertTrue(
            waitForWorkspaceCount(3, timeout: 5.0),
            "Expected 3 workspaces before running the close-other-workspaces command. list=\(socketCommand("list_workspaces") ?? "<nil>")"
        )
        XCTAssertEqual(socketCommand("select_workspace 1"), "OK")

        app.typeKey("p", modifierFlags: [.command, .shift])

        let searchField = app.textFields["CommandPaletteSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5.0), "Expected command palette search field")
        searchField.click()
        searchField.typeText("Close Other Workspaces")

        let resultButton = app.buttons["Close Other Workspaces"].firstMatch
        if resultButton.waitForExistence(timeout: 5.0) {
            resultButton.click()
        } else {
            app.typeKey(.return, modifierFlags: [])
        }

        XCTAssertTrue(
            waitForCloseWorkspacesAlert(app: app, timeout: 5.0),
            "Expected a single aggregated close-workspaces alert"
        )

        clickCancelOnCloseWorkspacesAlert(app: app)

        XCTAssertFalse(
            isCloseWorkspacesAlertPresent(app: app),
            "Expected aggregated close-workspaces alert to dismiss after clicking Cancel"
        )
        XCTAssertTrue(
            waitForWorkspaceCount(3, timeout: 5.0),
            "Expected all workspaces to remain after cancelling multi-close. list=\(socketCommand("list_workspaces") ?? "<nil>")"
        )
    }

    func testCmdShiftWUsesSidebarMultiSelectionSummaryDialog() {
        let app = XCUIApplication()
        configureSocketLaunchEnvironment(app)
        app.launchEnvironment["CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SIDEBAR_SELECTED_WORKSPACE_INDICES"] = "0,1"
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for close-workspaces shortcut test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(
            waitForSocketPong(timeout: 12.0),
            "Expected control socket to respond at \(socketPath). diagnostics=\(loadJSON(atPath: diagnosticsPath) ?? [:])"
        )

        XCTAssertEqual(socketCommand("new_workspace")?.prefix(2), "OK")
        XCTAssertTrue(
            waitForWorkspaceCount(2, timeout: 5.0),
            "Expected 2 workspaces before running Cmd+Shift+W. list=\(socketCommand("list_workspaces") ?? "<nil>")"
        )

        app.typeKey("w", modifierFlags: [.command, .shift])

        XCTAssertTrue(
            waitForCloseWorkspacesAlert(app: app, timeout: 5.0),
            "Expected Cmd+Shift+W to use the aggregated close-workspaces alert for sidebar multi-selection"
        )

        clickCancelOnCloseWorkspacesAlert(app: app)

        XCTAssertFalse(
            isCloseWorkspacesAlertPresent(app: app),
            "Expected aggregated close-workspaces alert to dismiss after clicking Cancel"
        )
        XCTAssertTrue(
            waitForWorkspaceCount(2, timeout: 5.0),
            "Expected both workspaces to remain after cancelling Cmd+Shift+W multi-close. list=\(socketCommand("list_workspaces") ?? "<nil>")"
        )
    }

    func testCmdShiftWCloseWorkspacesPromptIsWindowModalSheet() {
        let app = XCUIApplication()
        let recorderPath = "/tmp/cmux-ui-test-close-workspaces-presentation-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: recorderPath)
        configureSocketLaunchEnvironment(app)
        app.launchEnvironment["CMUX_UI_TEST_KEYEQUIV_PATH"] = recorderPath
        app.launchEnvironment["CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SIDEBAR_SELECTED_WORKSPACE_INDICES"] = "0,1"
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for close-workspaces modal routing test. state=\(app.state.rawValue)"
        )

        app.typeKey("n", modifierFlags: [.command])
        app.typeKey("n", modifierFlags: [.command])
        let sidebarSelection = waitForJSONKey(
            "tabCount",
            equals: "3",
            atPath: recorderPath,
            timeout: 10.0
        )
        XCTAssertEqual(
            sidebarSelection?["sidebarSelectedWorkspaceCount"],
            "2",
            "Expected Cmd+N to create three workspaces and UI-test setup to select two before Cmd+Shift+W. recorder=\(sidebarSelection ?? loadJSON(atPath: recorderPath) ?? [:])"
        )

        app.typeKey("w", modifierFlags: [.command, .shift])
        let closePrompt = waitForJSONKey(
            "closeConfirmationTitle",
            equals: "Close workspaces?",
            atPath: recorderPath,
            timeout: 5.0
        )
        XCTAssertEqual(
            closePrompt?["closeConfirmationTitle"],
            "Close workspaces?",
            "Expected Cmd+Shift+W to use the aggregated close-workspaces alert for sidebar multi-selection. recorder=\(closePrompt ?? loadJSON(atPath: recorderPath) ?? [:])"
        )

        let presentation = waitForJSONKey(
            "closeConfirmationAttachedSheet",
            equals: "1",
            atPath: recorderPath,
            timeout: 5.0
        )
        XCTAssertEqual(
            presentation?["closeConfirmationPresentation"],
            "sheet",
            "Workspace close confirmation should be attached to the cmux window so it cannot get stranded as a separate app-modal alert. recorder=\(presentation ?? loadJSON(atPath: recorderPath) ?? [:])"
        )
        XCTAssertEqual(
            presentation?["closeConfirmationAttachedSheet"],
            "1",
            "Expected the close confirmation to report an attached sheet. recorder=\(presentation ?? loadJSON(atPath: recorderPath) ?? [:])"
        )

        clickCancelOnCloseWorkspacesAlert(app: app)
    }

    func testCmdShiftWTargetsFocusedWindowWorkspaceWhenMultipleWindowsAreOpen() {
        let app = XCUIApplication()
        let recorderPath = "/tmp/cmux-ui-test-close-workspace-focused-window-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: recorderPath)
        configureSocketLaunchEnvironment(app)
        app.launchEnvironment["CMUX_UI_TEST_KEYEQUIV_PATH"] = recorderPath
        app.launchEnvironment["CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] = "1"
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for focused-window workspace close test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(
            waitForSocketPong(timeout: 12.0),
            "Expected control socket to respond at \(socketPath). diagnostics=\(loadJSON(atPath: diagnosticsPath) ?? [:])"
        )

        let focusedWindowId = requireUUID(from: socketCommand("current_window"), context: "initial current_window")
        let focusedWorkspaceId = requireUUID(
            from: socketCommand("new_workspace focused-window-target"),
            context: "new workspace in focused window"
        )
        XCTAssertEqual(socketCommand("current_workspace"), focusedWorkspaceId)

        _ = requireUUID(from: socketCommand("new_window"), context: "new_window")
        let otherWorkspaceId = requireUUID(
            from: socketCommand("new_workspace other-window-target"),
            context: "new workspace in other window"
        )
        XCTAssertEqual(socketCommand("current_workspace"), otherWorkspaceId)

        XCTAssertEqual(socketCommand("focus_window \(focusedWindowId)"), "OK")
        XCTAssertTrue(
            waitForKeyWindow(focusedWindowId, timeout: 5.0),
            "Expected focus_window to make the first cmux window key before Cmd+Shift+W. windows=\(socketCommand("list_windows") ?? "<nil>")"
        )
        XCTAssertEqual(socketCommand("current_workspace"), focusedWorkspaceId)

        app.typeKey("w", modifierFlags: [.command, .shift])

        let target = waitForJSONKey(
            "closeConfirmationTargetWorkspaceId",
            equals: focusedWorkspaceId,
            atPath: recorderPath,
            timeout: 5.0
        )
        XCTAssertEqual(
            target?["closeConfirmationTargetWindowId"],
            focusedWindowId,
            "Cmd+Shift+W should target the selected workspace in the focused/key window, not the other cmux window. recorder=\(target ?? loadJSON(atPath: recorderPath) ?? [:])"
        )

        let presentation = waitForJSONKey(
            "closeConfirmationHostWindowId",
            equals: focusedWindowId,
            atPath: recorderPath,
            timeout: 5.0
        )
        XCTAssertEqual(
            presentation?["closeConfirmationPresentation"],
            "sheet",
            "Close workspace confirmation should attach to the same focused window that owns the target workspace. recorder=\(presentation ?? loadJSON(atPath: recorderPath) ?? [:])"
        )

        clickCancelOnCloseWorkspaceAlert(app: app)
    }

    private func configureSocketLaunchEnvironment(_ app: XCUIApplication) {
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launchEnvironment["CMUX_TAG"] = launchTag
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        var resolvedPath: String?
        let ready = waitForControlSocketReady(
            pingTimeout: timeout,
            socketFileExists: { self.socketCandidates().contains { FileManager.default.fileExists(atPath: $0) } },
            pingReturnsPong: {
                let originalPath = self.socketPath
                for candidate in self.socketCandidates() {
                    guard FileManager.default.fileExists(atPath: candidate) else { continue }
                    self.socketPath = candidate
                    if self.socketCommand("ping") == "PONG" {
                        resolvedPath = candidate
                        return true
                    }
                    self.socketPath = originalPath
                }
                return false
            }
        )
        if let resolvedPath { socketPath = resolvedPath }
        if ready {
            return true
        }
        if let diagnostics = loadJSON(atPath: diagnosticsPath),
           controlSocketDiagnosticsReportReady(diagnostics) {
            if let expectedPath = diagnostics["socketExpectedPath"],
               !expectedPath.isEmpty,
               FileManager.default.fileExists(atPath: expectedPath) {
                socketPath = expectedPath
                return true
            } else if let readyCandidate = socketCandidates().first(where: { FileManager.default.fileExists(atPath: $0) }) {
                socketPath = readyCandidate
                return true
            }
        }
        return false
    }

    private func socketCandidates() -> [String] {
        var candidates = [socketPath, taggedSocketPath()]
        var seen = Set<String>()
        candidates.removeAll { !seen.insert($0).inserted }
        return candidates
    }

    private func taggedSocketPath() -> String {
        let slug = launchTag
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "/tmp/cmux-debug-\(slug).sock"
    }

    private func waitForWorkspaceCount(_ expectedCount: Int, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.workspaceCount() == expectedCount
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func workspaceCount() -> Int {
        guard let response = socketCommand("list_workspaces") else { return -1 }
        if response == "No workspaces" {
            return 0
        }
        return response
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }

    private func waitForJSONKey(_ key: String, equals expected: String, atPath path: String, timeout: TimeInterval) -> [String: String]? {
        var latest: [String: String]?
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                latest = self.loadJSON(atPath: path)
                return latest?[key] == expected
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed ? latest : nil
    }

    private func loadJSON(atPath path: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return json
    }

    func socketCommand(_ cmd: String, responseTimeout: TimeInterval = 2.0) -> String? {
        if let response = CloseWorkspacesControlSocketClient(path: socketPath, responseTimeout: responseTimeout).sendLine(cmd) {
            return response
        }
        return socketCommandViaNetcat(cmd, responseTimeout: responseTimeout)
    }

    private func socketCommandViaNetcat(_ cmd: String, responseTimeout: TimeInterval = 2.0) -> String? {
        let nc = "/usr/bin/nc"
        guard FileManager.default.isExecutableFile(atPath: nc) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        let timeoutSeconds = max(1, Int(ceil(responseTimeout)))
        let script = "printf '%s\\n' \(shellSingleQuote(cmd)) | \(nc) -U \(shellSingleQuote(socketPath)) -w \(timeoutSeconds) 2>/dev/null"
        proc.arguments = ["-lc", script]

        let outPipe = Pipe()
        proc.standardOutput = outPipe

        do {
            try proc.run()
        } catch {
            return nil
        }

        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let outStr = String(data: outData, encoding: .utf8) else { return nil }
        let trimmed = outStr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func shellSingleQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func isCloseWorkspacesAlertPresent(app: XCUIApplication) -> Bool {
        if closeWorkspacesDialog(app: app).exists { return true }
        if closeWorkspacesAlert(app: app).exists { return true }
        return app.staticTexts["Close workspaces?"].exists
    }

    private func waitForCloseWorkspacesAlert(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.isCloseWorkspacesAlertPresent(app: app)
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func clickCancelOnCloseWorkspacesAlert(app: XCUIApplication) {
        let dialog = closeWorkspacesDialog(app: app)
        if dialog.exists {
            dialog.buttons["Cancel"].firstMatch.click()
            return
        }
        let alert = closeWorkspacesAlert(app: app)
        if alert.exists {
            alert.buttons["Cancel"].firstMatch.click()
            return
        }
        let anyDialog = app.dialogs.firstMatch
        if anyDialog.exists, anyDialog.buttons["Cancel"].exists {
            anyDialog.buttons["Cancel"].firstMatch.click()
        }
    }

    private func clickCancelOnCloseWorkspaceAlert(app: XCUIApplication) {
        let dialog = closeWorkspaceDialog(app: app)
        if dialog.exists {
            dialog.buttons["Cancel"].firstMatch.click()
            return
        }
        let alert = closeWorkspaceAlert(app: app)
        if alert.exists {
            alert.buttons["Cancel"].firstMatch.click()
            return
        }
        let anyDialog = app.dialogs.firstMatch
        if anyDialog.exists, anyDialog.buttons["Cancel"].exists {
            anyDialog.buttons["Cancel"].firstMatch.click()
        }
    }

    private func closeWorkspacesDialog(app: XCUIApplication) -> XCUIElement {
        app.dialogs.containing(.staticText, identifier: "Close workspaces?").firstMatch
    }

    private func closeWorkspacesAlert(app: XCUIApplication) -> XCUIElement {
        app.alerts.containing(.staticText, identifier: "Close workspaces?").firstMatch
    }

    private func closeWorkspaceDialog(app: XCUIApplication) -> XCUIElement {
        app.dialogs.containing(.staticText, identifier: "Close workspace?").firstMatch
    }

    private func closeWorkspaceAlert(app: XCUIApplication) -> XCUIElement {
        app.alerts.containing(.staticText, identifier: "Close workspace?").firstMatch
    }

}
