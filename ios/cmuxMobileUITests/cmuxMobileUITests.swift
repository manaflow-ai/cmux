import XCTest

final class cmuxMobileUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSignInPairingAndWorkspaceShell() throws {
        let app = launchApp()

        XCTAssertTrue(app.buttons["MobileSignInButton"].waitForExistence(timeout: 8))
        app.buttons["MobileSignInButton"].tap()

        XCTAssertTrue(app.textFields["MobilePairingCodeField"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["MobileScanQRCodeButton"].isEnabled)
        try typeText("debug", into: app.textFields["MobilePairingCodeField"], in: app)
        app.buttons["MobileConnectButton"].tap()

        try openSelectedWorkspaceIfNeeded(app)
        XCTAssertTrue(app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 4))
        assertTerminalRow(1, label: "Mobile Core: enabled", in: app)
    }

    @MainActor
    func testCreateWorkspaceAndTerminalFromShell() throws {
        let app = try launchConnectedApp()

        let newWorkspaceButton = app.buttons.matching(identifier: "MobileNewWorkspaceButton").firstMatch
        XCTAssertTrue(newWorkspaceButton.waitForExistence(timeout: 4))
        newWorkspaceButton.tap()
        XCTAssertTrue(app.staticTexts["Workspace 3"].waitForExistence(timeout: 4))
        assertTerminalRow(2, label: "terminal: Terminal 1", in: app)

        app.buttons["MobileTerminalDropdown"].tap()
        let newTerminal = app.buttons["MobileNewTerminalMenuItem"]
        XCTAssertTrue(newTerminal.waitForExistence(timeout: 4))
        newTerminal.tap()

        assertTerminalRow(2, label: "terminal: Terminal 2", in: app)
    }

    @MainActor
    func testTerminalDropdownSwitchesToAlternateScreenSnapshot() throws {
        let app = try launchConnectedApp()

        app.buttons["MobileTerminalDropdown"].tap()
        let tuiTerminal = app.buttons["MobileTerminalMenuItem-terminal-tui"]
        XCTAssertTrue(tuiTerminal.waitForExistence(timeout: 4))
        tuiTerminal.tap()

        assertTerminalRow(0, label: "LAZYGIT", in: app)
        assertTerminalRow(1, label: "files branches log", in: app)
        assertTerminalRow(3, label: "q quit", in: app)
    }

    @MainActor
    func testTerminalShellDoesNotExposeSendBar() throws {
        let app = try launchConnectedApp()

        XCTAssertTrue(app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.textFields["MobileTerminalInputField"].exists)
        XCTAssertFalse(app.buttons["MobileTerminalSendButton"].exists)
    }

    @MainActor
    private func launchConnectedApp() throws -> XCUIApplication {
        let app = launchApp()
        app.buttons["MobileSignInButton"].tap()
        XCTAssertTrue(app.textFields["MobilePairingCodeField"].waitForExistence(timeout: 4))
        try typeText("debug", into: app.textFields["MobilePairingCodeField"], in: app)
        app.buttons["MobileConnectButton"].tap()
        try openSelectedWorkspaceIfNeeded(app)
        return app
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor
    private func openSelectedWorkspaceIfNeeded(_ app: XCUIApplication) throws {
        let buildStatusRow = terminalRow(1, in: app)
        if buildStatusRow.waitForExistence(timeout: 1),
           buildStatusRow.label == "Mobile Core: enabled" {
            return
        }
        let row = app.descendants(matching: .any)["MobileWorkspaceRow-workspace-main"]
        if row.waitForExistence(timeout: 2) {
            row.tap()
        }
    }

    @MainActor
    private func assertTerminalRow(
        _ index: Int,
        label expectedLabel: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let row = terminalRow(index, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 4), file: file, line: line)
        let predicate = NSPredicate(format: "label == %@", expectedLabel)
        let labelExpectation = XCTNSPredicateExpectation(predicate: predicate, object: row)
        let result = XCTWaiter.wait(for: [labelExpectation], timeout: 4)
        XCTAssertEqual(result, .completed, file: file, line: line)
        XCTAssertEqual(row.label, expectedLabel, file: file, line: line)
    }

    @MainActor
    private func terminalRow(_ index: Int, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["MobileTerminalRow-\(index)"]
    }

    @MainActor
    private func typeText(_ text: String, into element: XCUIElement, in app: XCUIApplication) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 4))
        element.tap()
        element.typeText(text)
    }
}
