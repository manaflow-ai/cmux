import XCTest

/// The Cloud tab's section headers: Cloud Machines' hover "+" opens the same
/// New Machine sheet as Cmd-Y, once per click, and My Devices no longer
/// explains its ⋯ menu in a hint line.
final class CloudSectionHeaderActionsUITests: XCTestCase {
    private let flagKeys = [
        "cmux.flags.override.cloud-machines-enabled-release",
    ]
    private var savedFlags: [String: Any] = [:]
    private var fixtureDefaults: UserDefaults?

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.cmuxterm.app.debug"))
        fixtureDefaults = defaults
        // The flag reader accepts typed Booleans; launch-argument strings do not
        // force the effective flag on.
        for key in flagKeys {
            savedFlags[key] = defaults.object(forKey: key)
            defaults.set(true, forKey: key)
        }
        defaults.synchronize()
    }

    override func tearDown() {
        for key in flagKeys {
            fixtureDefaults?.set(savedFlags[key], forKey: key)
        }
        fixtureDefaults?.synchronize()
        fixtureDefaults = nil
        savedFlags.removeAll()
        super.tearDown()
    }

    func testCloudMachinesPlusOpensOneNewMachineSheetLikeCmdY() {
        let app = launchSignedInApp()
        defer { app.terminate() }
        let cloudMode = app.buttons["RightSidebarModeButton.machines"]
        XCTAssertTrue(cloudMode.waitForExistence(timeout: 10))
        cloudMode.click()

        let tree = app.descendants(matching: .any).matching(identifier: "CloudMachinesTree").firstMatch
        XCTAssertTrue(tree.waitForExistence(timeout: 10), "Expected the Cloud tree with its section headers")
        // The team picker bar above the tree has its own "New Machine" +, so
        // the header + is found by its identifier inside the tree only.
        let plus = tree.buttons.matching(identifier: "CloudMachinesNewMachineButton").firstMatch
        // Faded at rest, the + keeps its place in the accessibility tree.
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "Expected the Cloud Machines header + in the tree")
        XCTAssertEqual(plus.label, "New Machine")

        // The My Devices controls keep their rows and lose the ⋯ hint.
        XCTAssertTrue(app.buttons["DevicesOptionsMenu"].exists || app.menuButtons["DevicesOptionsMenu"].exists)
        XCTAssertFalse(
            app.staticTexts["Change these options in the ⋯ menu next to My Devices."].exists,
            "The redundant ⋯ hint must be gone"
        )
        capture(app, "cloud-headers-at-rest")

        // Pointing at the + hovers its header row, which fades the + in.
        plus.hover()
        capture(app, "cloud-machines-header-hovered")
        plus.click()
        assertOneNewMachineSheet(in: app, opener: "the Cloud Machines +")
        capture(app, "new-machine-sheet-from-plus")
        cancelNewMachineSheet(in: app)

        app.typeKey("y", modifierFlags: [.command])
        assertOneNewMachineSheet(in: app, opener: "Cmd-Y")
        capture(app, "new-machine-sheet-from-cmd-y")
        cancelNewMachineSheet(in: app)
    }

    private func assertOneNewMachineSheet(in app: XCUIApplication, opener: String) {
        let create = Self.buttons(in: app, identifier: "NewMachineSheet.create", label: "Create")
        // The presenter reads the account's plan before the sheet appears.
        let opened = app.sheets.firstMatch.waitForExistence(timeout: 30)
            && create.firstMatch.waitForExistence(timeout: 5)
        if !opened {
            print("CloudSectionHeaderActionsUITests hierarchy:\n\(app.debugDescription.prefix(8000))")
        }
        XCTAssertTrue(opened, "Expected \(opener) to open the New Machine sheet")
        XCTAssertTrue(app.staticTexts["New Machine"].waitForExistence(timeout: 3))
        // One click, one flow: a second presentation would stack a second sheet
        // or a second Create button.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        XCTAssertEqual(app.sheets.count, 1, "\(opener) must open exactly one New Machine sheet")
        XCTAssertEqual(create.count, 1, "\(opener) must open exactly one New Machine sheet")
    }

    private func cancelNewMachineSheet(in app: XCUIApplication) {
        let cancel = Self.buttons(in: app, identifier: "NewMachineSheet.cancel", label: "Cancel").firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.click()
        let create = Self.buttons(in: app, identifier: "NewMachineSheet.create", label: "Create").firstMatch
        XCTAssertTrue(create.waitForNonExistence(timeout: 5), "Cancel should close the sheet")
    }

    private static func buttons(in app: XCUIApplication, identifier: String, label: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", identifier, label))
    }

    private func launchSignedInApp() -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTH_FIXTURE"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTH_USER_ID"] = "cloud-header-actions-fixture"
        app.launchEnvironment["CMUX_UITEST_AUTH_NAME"] = "Cloud Header Actions Fixture"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] = "1"
        app.launchArguments += [
            "-workspacePresentationMode", "standard",
            "-cloud.beta.machines.enabled", "YES",
            "-fileExplorer.isVisible", "YES",
            "-rightSidebar.mode", "files",
            "-menuBarOnly", "false",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
