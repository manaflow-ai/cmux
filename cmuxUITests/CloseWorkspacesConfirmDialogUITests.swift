import XCTest
import Foundation

final class CloseWorkspacesConfirmDialogUITests: XCTestCase {
    private var socketPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-ui-test-close-workspaces-\(UUID().uuidString).sock"
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func testCommandPaletteCloseOtherWorkspacesShowsSingleSummaryDialog() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] = "1"
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for close-workspaces confirmation test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control socket to respond at \(socketPath)")

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
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SIDEBAR_SELECTED_WORKSPACE_INDICES"] = "0,1"
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for close-workspaces shortcut test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control socket to respond at \(socketPath)")

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
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if socketCommand("ping") == "PONG" {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return socketCommand("ping") == "PONG"
    }

    private func waitForWorkspaceCount(_ expectedCount: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if workspaceCount() == expectedCount {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return workspaceCount() == expectedCount
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

    private func socketCommand(_ cmd: String) -> String? {
        let nc = "/usr/bin/nc"
        guard FileManager.default.isExecutableFile(atPath: nc) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nc)
        proc.arguments = ["-U", socketPath, "-w", "2"]

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return nil
        }

        if let data = (cmd + "\n").data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        inPipe.fileHandleForWriting.closeFile()

        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let outStr = String(data: outData, encoding: .utf8) else { return nil }
        return outStr.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isCloseWorkspacesAlertPresent(app: XCUIApplication) -> Bool {
        if closeWorkspacesDialog(app: app).exists { return true }
        if closeWorkspacesAlert(app: app).exists { return true }
        return app.staticTexts["Close workspaces?"].exists
    }

    private func waitForCloseWorkspacesAlert(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isCloseWorkspacesAlertPresent(app: app) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return isCloseWorkspacesAlertPresent(app: app)
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

    private func closeWorkspacesDialog(app: XCUIApplication) -> XCUIElement {
        app.dialogs.containing(.staticText, identifier: "Close workspaces?").firstMatch
    }

    private func closeWorkspacesAlert(app: XCUIApplication) -> XCUIElement {
        app.alerts.containing(.staticText, identifier: "Close workspaces?").firstMatch
    }
}
