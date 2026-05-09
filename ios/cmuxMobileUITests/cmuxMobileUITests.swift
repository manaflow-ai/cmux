import UIKit
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
        XCTAssertFalse(app.buttons["MobileScanQRCodeButton"].isEnabled)
        app.textFields["MobilePairingCodeField"].tap()
        app.textFields["MobilePairingCodeField"].typeText("debug")
        app.buttons["MobileConnectButton"].tap()

        try openSelectedWorkspaceIfNeeded(app)
        XCTAssertTrue(app.staticTexts["cmux-macbook"].exists)
        XCTAssertTrue(app.staticTexts["Mobile Sync: enabled"].waitForExistence(timeout: 4))
    }

    @MainActor
    func testCreateWorkspaceAndTerminalFromShell() throws {
        let app = launchApp()
        try connect(app)

        let newWorkspaceButton = app.buttons.matching(identifier: "MobileNewWorkspaceButton").firstMatch
        XCTAssertTrue(newWorkspaceButton.waitForExistence(timeout: 4))
        newWorkspaceButton.tap()
        XCTAssertTrue(app.staticTexts["Workspace 3"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["terminal: Terminal 1"].waitForExistence(timeout: 4))

        app.buttons["MobileTerminalDropdown"].tap()
        let newTerminal = app.buttons["MobileNewTerminalMenuItem"]
        XCTAssertTrue(newTerminal.waitForExistence(timeout: 4))
        newTerminal.tap()

        XCTAssertTrue(app.staticTexts["terminal: Terminal 2"].waitForExistence(timeout: 4))
    }

    @MainActor
    func testTerminalDropdownSwitchesVisibleTerminal() throws {
        let app = launchApp()
        try connect(app)

        app.buttons["MobileTerminalDropdown"].tap()
        let agentTerminal = app.buttons["MobileTerminalMenuItem-terminal-agent"]
        XCTAssertTrue(agentTerminal.waitForExistence(timeout: 4))
        agentTerminal.tap()

        XCTAssertTrue(app.staticTexts["$ git status --short"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["## feat-ios-minimal-shell"].exists)
    }

    @MainActor
    func testTerminalDropdownSwitchesToAlternateScreenSnapshot() throws {
        let app = launchApp()
        try connect(app)

        app.buttons["MobileTerminalDropdown"].tap()
        let tuiTerminal = app.buttons["MobileTerminalMenuItem-terminal-tui"]
        XCTAssertTrue(tuiTerminal.waitForExistence(timeout: 4))
        tuiTerminal.tap()

        XCTAssertTrue(app.staticTexts["LAZYGIT"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["files branches log"].exists)
        XCTAssertTrue(app.staticTexts["q quit"].exists)
    }

    @MainActor
    func testIPadShowsWorkspaceListAndTerminalTogether() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("iPad-only split view check")
        }

        let app = launchApp()
        try connect(app)

        XCTAssertTrue(app.descendants(matching: .any)["MobileWorkspaceList"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["cmux-macbook"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Mobile Sync: enabled"].exists)
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor
    private func connect(_ app: XCUIApplication) throws {
        XCTAssertTrue(app.buttons["MobileSignInButton"].waitForExistence(timeout: 8))
        app.buttons["MobileSignInButton"].tap()

        let field = app.textFields["MobilePairingCodeField"]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText("debug")
        app.buttons["MobileConnectButton"].tap()
        try openSelectedWorkspaceIfNeeded(app)
        XCTAssertTrue(app.staticTexts["Mobile Sync: enabled"].waitForExistence(timeout: 4))
    }

    @MainActor
    private func openSelectedWorkspaceIfNeeded(_ app: XCUIApplication) throws {
        if app.staticTexts["Mobile Sync: enabled"].waitForExistence(timeout: 1) {
            return
        }

        let row = app.otherElements["MobileWorkspaceRow-workspace-main"]
        if row.waitForExistence(timeout: 2) {
            row.tap()
            return
        }

        let fallback = app.staticTexts["cmux"]
        if fallback.waitForExistence(timeout: 2) {
            fallback.tap()
            return
        }

        XCTFail("Could not open the selected workspace")
    }
}
