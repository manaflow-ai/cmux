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
        XCTAssertTrue(app.menuItems["SidebarAccountSignOutButton"].waitForExistence(timeout: 5))
        capture("account-menu")
        XCTAssertFalse(
            app.descendants(matching: .any)["SidebarAccountTeamPickerButton"].waitForExistence(timeout: 2),
            "The local account menu must not offer team switching."
        )
        XCTAssertFalse(app.descendants(matching: .any)["SidebarAccountCreateTeamButton"].exists)
        // A native menu swallows the next outside click, so close it first.
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

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
        let create = createTeamItem(app)
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["CloudTeamPickerButton"].exists)
        assertDropdownAnchoredUnderTrigger(app)
        XCTAssertFalse(app.menuItems["SidebarAccountSignOutButton"].exists)
        capture("shortcut-opens-cloud-picker")

        create.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let name = sheet.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("Draft team")
        button(in: sheet, identifier: "CloudCreateTeamSheet.cancel", label: "Cancel").click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(create.waitForNonExistence(timeout: 5))
        capture("cloud-create-team-sheet-cancelled")
        app.buttons["RightSidebar.closeButton"].click()

        invokePickerFromPalette(app)
        assertDropdownAnchoredUnderTrigger(app)
        capture("palette-opens-cloud-picker")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(create.waitForNonExistence(timeout: 5))
    }

    /// #15072: the picker is a pull-down menu under the trigger's leading edge,
    /// not a centered popover bubble that truncates team names.
    func testDropdownAnchorsUnderTriggerShowsFullNamesAndSwitchesTeams() {
        let app = launchSignedInApp(teams: Self.fixtureTeams)
        defer { app.terminate() }
        let trigger = openCloudHeader(app)
        waitForLabel(of: trigger, containing: Self.longTeamName)

        trigger.click()
        assertDropdownAnchoredUnderTrigger(app)
        let longTeam = teamItem(app, id: "team-long", title: Self.longTeamName)
        let alpha = teamItem(app, id: "team-alpha", title: "Alpha Squad")
        XCTAssertTrue(longTeam.waitForExistence(timeout: 5))
        XCTAssertEqual(longTeam.title, Self.longTeamName, "Menu rows carry the full team name.")
        XCTAssertTrue(alpha.exists)
        XCTAssertTrue(alpha.isEnabled)
        capture("team-dropdown-open")

        alpha.click()
        XCTAssertTrue(alpha.waitForNonExistence(timeout: 5))
        waitForLabel(of: trigger, containing: "Alpha Squad")
        capture("team-dropdown-switched")
    }

    func testPendingSwitchDisablesMenuAndFailedSwitchReportsError() {
        // The switch stays pending until the test creates this file, then fails.
        let switchGate = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-team-switch-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: switchGate) }
        let app = launchSignedInApp(teams: Self.fixtureTeams, environment: [
            "CMUX_UITEST_AUTH_FIXTURE_TEAM_SWITCH_GATE": switchGate.path,
            "CMUX_UITEST_AUTH_FIXTURE_REJECT_TEAM_ID": "team-alpha",
        ])
        defer { app.terminate() }
        let trigger = openCloudHeader(app)
        waitForLabel(of: trigger, containing: Self.longTeamName)

        trigger.click()
        teamItem(app, id: "team-alpha", title: "Alpha Squad").click()
        // The trigger stays one button and tells VoiceOver a switch is pending.
        waitForValue(of: trigger, "Switching teams…")
        trigger.click()
        let switching = app.menuItems.matching(NSPredicate(
            format: "identifier == %@ OR title == %@", "CloudTeamPickerSwitchingStatus", "Switching teams…"
        )).firstMatch
        XCTAssertTrue(switching.waitForExistence(timeout: 5), "A pending switch stays visible in the menu.")
        XCTAssertFalse(teamItem(app, id: "team-long", title: Self.longTeamName).isEnabled)
        XCTAssertFalse(teamItem(app, id: "team-alpha", title: "Alpha Squad").isEnabled)
        XCTAssertFalse(createTeamItem(app).isEnabled)
        capture("team-dropdown-pending")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(switching.waitForNonExistence(timeout: 5))
        XCTAssertTrue(FileManager.default.createFile(atPath: switchGate.path, contents: Data()))

        assertTeamChangeError(app, "Could not switch teams. Try again.")
        waitForLabel(of: trigger, containing: Self.longTeamName)
        capture("team-dropdown-switch-failed")
    }

    /// Create closes the sheet at once and the header shows the new team while
    /// the server works. A rejected create restores the previous team, reports
    /// the failure under the header and offers the name again.
    func testCreateTeamIsOptimisticAndRejectedCreateRollsBack() {
        // Creates stay pending until the test creates this file.
        let createGate = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-team-create-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: createGate) }
        let app = launchSignedInApp(teams: Self.fixtureTeams, environment: [
            "CMUX_UITEST_AUTH_FIXTURE_REJECT_TEAM_NAME": "Taken Team",
            "CMUX_UITEST_AUTH_FIXTURE_TEAM_CREATE_GATE": createGate.path,
        ])
        defer { app.terminate() }
        let trigger = openCloudHeader(app)
        waitForLabel(of: trigger, containing: Self.longTeamName)

        trigger.click()
        createTeamItem(app).click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let name = sheet.textFields.firstMatch
        let create = button(in: sheet, identifier: "CloudCreateTeamSheet.create", label: "Create")
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertFalse(create.isEnabled, "An empty name cannot be submitted.")
        name.click()
        name.typeText("   ")
        XCTAssertFalse(create.isEnabled, "A blank name cannot be submitted.")

        name.typeText("Taken Team")
        create.click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Create does not wait for the server.")
        waitForLabel(of: trigger, containing: "Taken Team")
        waitForValue(of: trigger, "Creating team…")
        trigger.click()
        let creating = app.menuItems.matching(NSPredicate(
            format: "identifier == %@ OR title == %@", "CloudTeamPickerCreatingStatus", "Creating team…"
        )).firstMatch
        XCTAssertTrue(creating.waitForExistence(timeout: 5), "A pending create stays visible in the menu.")
        let pendingTeam = app.menuItems.matching(NSPredicate(
            format: "identifier == %@ OR title == %@", "CloudTeamPickerPendingTeam", "Taken Team"
        )).firstMatch
        XCTAssertTrue(pendingTeam.exists, "The menu lists the team being created.")
        XCTAssertFalse(pendingTeam.isEnabled)
        XCTAssertFalse(teamItem(app, id: "team-long", title: Self.longTeamName).isEnabled)
        XCTAssertFalse(createTeamItem(app).isEnabled)
        capture("create-team-pending")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(creating.waitForNonExistence(timeout: 5))

        XCTAssertTrue(FileManager.default.createFile(atPath: createGate.path, contents: Data()))
        assertTeamChangeError(app, "Could not create that team. Try again.")
        waitForLabel(of: trigger, containing: Self.longTeamName)
        capture("create-team-rejected")

        trigger.click()
        createTeamItem(app).click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        waitForValue(of: name, "Taken Team")
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Launch Crew")
        create.click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        waitForLabel(of: trigger, containing: "Launch Crew")

        trigger.click()
        XCTAssertTrue(teamItem(app, id: "uitest-created-team-1", title: "Launch Crew").waitForExistence(timeout: 5))
        capture("create-team-selected")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testCloudGateExplainsWhyPickerCannotOpen() {
        let app = launchSignedInApp(cloudEnabled: false, sidebarVisible: false)
        defer { app.terminate() }
        app.typeKey("t", modifierFlags: [.command, .option, .shift])
        let unavailable = app.staticTexts["Cloud Machines are temporarily unavailable."]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["CloudTeamPickerButton"].exists)
        capture("shortcut-cloud-unavailable")
        // Runners with a Touch Bar also expose the alert's OK there.
        app.sheets.firstMatch.buttons["OK"].click()
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
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            "CommandPaletteResultRow.", ".palette.auth.teamPicker"
        )).firstMatch
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        command.click()
    }

    private static let longTeamName = "Benjamin Swerdlow's Team"
    private static let fixtureTeams = #"[{"id":"team-long","displayName":"Benjamin Swerdlow's Team"},{"id":"team-alpha","displayName":"Alpha Squad"}]"#

    private func openCloudHeader(_ app: XCUIApplication) -> XCUIElement {
        let cloudMode = app.buttons["RightSidebarModeButton.machines"]
        XCTAssertTrue(cloudMode.waitForExistence(timeout: 10))
        cloudMode.click()
        let trigger = app.buttons["CloudTeamPickerButton"]
        XCTAssertTrue(trigger.waitForExistence(timeout: 10))
        return trigger
    }

    private func teamItem(_ app: XCUIApplication, id: String, title: String) -> XCUIElement {
        app.menuItems.matching(NSPredicate(
            format: "identifier == %@ OR title == %@", "CloudTeamPickerTeam_\(id)", title
        )).firstMatch
    }

    private func createTeamItem(_ app: XCUIApplication) -> XCUIElement {
        app.menuItems.matching(NSPredicate(
            format: "identifier == %@ OR title == %@", "CloudTeamPickerCreateTeamButton", "Create Team…"
        )).firstMatch
    }

    private func button(in element: XCUIElement, identifier: String, label: String) -> XCUIElement {
        element.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", identifier, label)).firstMatch
    }

    private func waitForLabel(
        of element: XCUIElement,
        containing text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", text),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: 10), .completed,
            "Expected \(element.label) to contain \(text)", file: file, line: line
        )
    }

    private func waitForValue(
        of element: XCUIElement,
        _ value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: 10), .completed,
            "Expected \(element) to have value \(value)", file: file, line: line
        )
    }

    /// The right sidebar's own identifier can replace the ones inside it, so
    /// this checks that the message keeps its identifier and its text.
    private func assertTeamChangeError(
        _ app: XCUIApplication,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let errorText = app.staticTexts["CloudTeamPickerError"]
        XCTAssertTrue(errorText.waitForExistence(timeout: 10), "A rejected team change reports its failure.",
                      file: file, line: line)
        XCTAssertTrue(
            errorText.label == message || errorText.value as? String == message,
            "VoiceOver reads the failure message, not \(errorText.label) / \(String(describing: errorText.value)).",
            file: file, line: line
        )
    }

    /// The menu opens as a pull-down: its leading edge meets the trigger's and
    /// its top sits just under the trigger, with no popover bubble.
    private func assertDropdownAnchoredUnderTrigger(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let create = createTeamItem(app)
        XCTAssertTrue(create.waitForExistence(timeout: 10), "The team menu opened.", file: file, line: line)
        let trigger = app.buttons["CloudTeamPickerButton"]
        XCTAssertTrue(trigger.exists, file: file, line: line)
        XCTAssertEqual(app.popovers.count, 0, "The team picker must not open a popover.", file: file, line: line)
        let menu = app.menus.containing(NSPredicate(
            format: "identifier == %@ OR title == %@", "CloudTeamPickerCreateTeamButton", "Create Team…"
        )).firstMatch
        XCTAssertTrue(menu.exists, file: file, line: line)
        let menuFrame = menu.frame
        let triggerFrame = trigger.frame
        XCTAssertEqual(menuFrame.minX, triggerFrame.minX, accuracy: 8,
                       "Menu \(menuFrame) must align with trigger \(triggerFrame).", file: file, line: line)
        XCTAssertGreaterThanOrEqual(menuFrame.minY, triggerFrame.maxY - 2, file: file, line: line)
        XCTAssertLessThanOrEqual(menuFrame.minY, triggerFrame.maxY + 12, file: file, line: line)
        XCTAssertGreaterThanOrEqual(menuFrame.width, triggerFrame.width - 1, file: file, line: line)
    }

    private func launchSignedInApp(
        cloudEnabled: Bool = true,
        sidebarVisible: Bool = true,
        teams: String? = nil,
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTH_FIXTURE"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTH_USER_ID"] = "team-picker-fixture"
        app.launchEnvironment["CMUX_UITEST_AUTH_NAME"] = "Team Picker Fixture"
        if let teams {
            app.launchEnvironment["CMUX_UITEST_AUTH_FIXTURE_TEAMS"] = teams
        }
        app.launchEnvironment.merge(environment) { _, new in new }
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
