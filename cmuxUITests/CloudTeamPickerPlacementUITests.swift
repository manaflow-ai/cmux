import XCTest

final class CloudTeamPickerPlacementUITests: XCTestCase {
    private let flagKeys = [
        "cmux.flags.override.cloud-machines-enabled-release",
        "cmux.flags.override.sidebar-account-button-enabled-release",
    ]
    private let teamPickerShortcutKey = "shortcut.openTeamPicker"
    private var savedTeamPickerShortcut: Any?
    private var savedFlags: [String: Any] = [:]
    private var fixtureDefaults: UserDefaults?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.cmuxterm.app.debug"))
        fixtureDefaults = defaults
        savedTeamPickerShortcut = defaults.object(forKey: teamPickerShortcutKey)
        defaults.set(Self.defaultTeamPickerShortcutData, forKey: teamPickerShortcutKey)
        // The flag reader accepts typed Booleans. Launch arguments such as YES
        // are strings and do not force the effective flag on.
        for key in flagKeys {
            savedFlags[key] = defaults.object(forKey: key)
            defaults.set(true, forKey: key)
        }
        defaults.synchronize()
    }


    private static let defaultTeamPickerShortcutData = Data(#"{"key":"t","command":true,"shift":true,"option":true,"control":false}"#.utf8)
    override func tearDown() {
        for key in flagKeys {
            fixtureDefaults?.set(savedFlags[key], forKey: key)
        }
        if let savedTeamPickerShortcut {
            fixtureDefaults?.set(savedTeamPickerShortcut, forKey: teamPickerShortcutKey)
        } else {
            fixtureDefaults?.removeObject(forKey: teamPickerShortcutKey)
        }
        fixtureDefaults?.synchronize()
        fixtureDefaults = nil
        savedFlags.removeAll()
        super.tearDown()
    }

    func testAccountFooterDoesNotOfferTeamPickerAndCloudHeaderDoes() {
        let app = launchSignedInApp()
        defer { app.terminate() }
        let accountButton = app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label == %@", "SidebarAccountMenuButton", "Account"
        )).firstMatch
        XCTAssertTrue(accountButton.waitForExistence(timeout: 10))
        accountButton.click()
        XCTAssertTrue(app.buttons["SidebarAccountSignOutButton"].waitForExistence(timeout: 5))
        capture("account-popover")
        XCTAssertFalse(
            app.buttons["SidebarAccountTeamPickerButton"].waitForExistence(timeout: 2),
            "The local account popover must not offer team switching."
        )
        XCTAssertFalse(app.buttons["SidebarAccountCreateTeamButton"].exists)

        let cloudMode = app.buttons["RightSidebarModeButton.machines"]
        XCTAssertTrue(cloudMode.waitForExistence(timeout: 10))
        cloudMode.click()
        capture("cloud-header")
        XCTAssertTrue(
            app.buttons["CloudTeamPickerButton"].waitForExistence(timeout: 10),
            "The signed-in Cloud header must offer team scope."
        )
    }

    func testShortcutAndPaletteRevealCloudAndOpenItsPicker() {
        let app = launchSignedInApp(sidebarVisible: false)
        defer { app.terminate() }
        app.typeKey("t", modifierFlags: [.command, .option, .shift])
        let create = app.buttons["CloudTeamPickerCreateTeamButton"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["CloudTeamPickerButton"].exists)
        XCTAssertFalse(app.buttons["SidebarAccountSignOutButton"].exists)
        capture("shortcut-opens-cloud-picker")

        create.click()
        let name = app.textFields["Team name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Draft team")
        app.buttons["Cancel"].click()
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        capture("cloud-create-team-editor-cancelled")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(create.waitForNonExistence(timeout: 5))
        app.buttons["RightSidebar.closeButton"].click()

        invokePickerFromPalette(app)
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["CloudTeamPickerButton"].exists)
        capture("palette-opens-cloud-picker")
    }

    func testCloudGateExplainsWhyPickerCannotOpen() {
        let app = launchSignedInApp(cloudEnabled: false, sidebarVisible: false)
        defer { app.terminate() }
        app.typeKey("t", modifierFlags: [.command, .option, .shift])
        let unavailable = app.staticTexts["Cloud Machines are temporarily unavailable."]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["CloudTeamPickerButton"].exists)
        capture("shortcut-cloud-unavailable")
        app.buttons["OK"].click()
        XCTAssertTrue(unavailable.waitForNonExistence(timeout: 5))

        invokePickerFromPalette(app)
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["CloudTeamPickerButton"].exists)
        capture("palette-cloud-unavailable")
    }

    private func invokePickerFromPalette(_ app: XCUIApplication) {
        app.typeKey("p", modifierFlags: [.command, .shift])
        let search = app.textFields["CommandPaletteSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("open team picker")
        let command = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND value == %@",
            "CommandPaletteResultRow.", "palette.auth.teamPicker"
        )).firstMatch
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        command.click()
    }

    private func launchSignedInApp(
        cloudEnabled: Bool = true,
        sidebarVisible: Bool = true
    ) -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTH_FIXTURE"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTH_USER_ID"] = "team-picker-fixture"
        app.launchEnvironment["CMUX_UITEST_AUTH_NAME"] = "Team Picker Fixture"
        if sidebarVisible {
            app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] = "1"
        }
        app.launchArguments += [
            "-workspacePresentationMode", "standard",
            "-cloud.beta.machines.enabled", cloudEnabled ? "YES" : "NO",
            "-fileExplorer.isVisible", sidebarVisible ? "YES" : "NO",
            "-rightSidebar.mode", "files",
            "-menuBarOnly", "false",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        return app
    }

    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
