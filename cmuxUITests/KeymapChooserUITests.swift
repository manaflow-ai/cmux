import XCTest

/// UI coverage for the first-run base keymap chooser.
///
/// The chooser suppresses itself under a test harness, so these tests are the
/// only way to drive it from XCUITest and the only way `scripts/ui-test` can
/// capture a frame of the sheet. Each launch here does two things the app never
/// does together on its own: it points `HOME` at a throwaway directory so the
/// install reads as new, and it sets `CMUX_UI_TEST_KEYMAP_CHOOSER=1` to opt
/// back in.
///
/// Identifiers under test, from `ShortcutKeymapChooserView` and
/// `ShortcutKeymapPresetRow`:
/// - `KeymapChooser` — the sheet.
/// - `KeymapChooserPreset-<rawValue>` — one row per style.
/// - `KeymapChooserPreview`, `KeymapChooserPreviewMore` — the preview column.
/// - `KeymapChooserApply`, `KeymapChooserKeepCurrent` — the two answers.
/// - `SettingsKeyboardShortcutsBaseKeymapCompare` — the Settings entry point.
final class KeymapChooserUITests: SettingsUITestCase {
    private var isolatedHomes: [URL] = []

    override func tearDown() {
        for home in isolatedHomes {
            try? FileManager.default.removeItem(at: home)
        }
        isolatedHomes = []
        super.tearDown()
    }

    /// A HOME with nothing in it, so the shortcut store creates `cmux.json`
    /// from its own template and the install reads as a first run.
    private func makeFreshHome() -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-keymap-chooser-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        isolatedHomes.append(home)
        return home
    }

    private func launchApp(freshInstall: Bool, optIntoChooser: Bool) -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += settingsLaunchArguments
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        if freshInstall {
            let home = makeFreshHome()
            app.launchEnvironment["HOME"] = home.path
            app.launchEnvironment["CFFIXED_USER_HOME"] = home.path
            app.launchEnvironment["XDG_CONFIG_HOME"] =
                home.appendingPathComponent(".config", isDirectory: true).path
            app.launchArguments += [
                "-cmux.shortcuts.keymapChooser.answered.v1", "NO",
            ]
        }
        if optIntoChooser {
            app.launchEnvironment["CMUX_UI_TEST_KEYMAP_CHOOSER"] = "1"
        }
        launchAndActivate(app)
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 8.0), "main window did not appear")
        return app
    }

    private func sheet(_ app: XCUIApplication, timeout: TimeInterval = 10.0) -> XCUIElement {
        let chooser = app.descendants(matching: .any)["KeymapChooser"]
        XCTAssertTrue(poll(timeout: timeout) { chooser.exists }, "chooser sheet did not appear")
        return chooser
    }

    // MARK: - The sheet a new install sees

    /// The frame `scripts/ui-test` captures for the PR. Everything the chooser
    /// promises is on screen at once: five styles, a preview, and two answers.
    func testFreshInstallShowsTheChooserWithEveryStyleAndBothAnswers() {
        let app = launchApp(freshInstall: true, optIntoChooser: true)
        let chooser = sheet(app)
        for preset in ["cmux", "terminal", "iterm2", "tmux", "browser"] {
            let row = app.descendants(matching: .any)["KeymapChooserPreset-\(preset)"]
            XCTAssertTrue(poll(timeout: 4.0) { row.exists }, "missing style row for \(preset)")
        }
        XCTAssertTrue(app.descendants(matching: .any)["KeymapChooserPreview"].exists, "missing preview")
        XCTAssertTrue(app.descendants(matching: .any)["KeymapChooserApply"].exists, "missing apply button")
        XCTAssertTrue(
            app.descendants(matching: .any)["KeymapChooserKeepCurrent"].exists,
            "missing keep-current button"
        )
        XCTAssertTrue(chooser.exists)
        app.terminate()
    }

    /// The footnote is the only thing telling you the six preview rows are not
    /// the whole change set, so it has to appear for a style that hides some
    /// and stay away for one that hides none.
    func testFootnoteAppearsOnlyForStylesWithHiddenOverrides() {
        let app = launchApp(freshInstall: true, optIntoChooser: true)
        _ = sheet(app)
        let footnote = app.descendants(matching: .any)["KeymapChooserPreviewMore"]

        app.descendants(matching: .any)["KeymapChooserPreset-tmux"].click()
        XCTAssertTrue(
            poll(timeout: 4.0) { footnote.exists },
            "tmux writes more than the preview shows, so the footnote must be there"
        )

        app.descendants(matching: .any)["KeymapChooserPreset-browser"].click()
        XCTAssertTrue(
            poll(timeout: 4.0) { !footnote.exists },
            "the browser style previews all of its own overrides, so there is nothing to footnote"
        )
        app.terminate()
    }

    /// "Not Now" dismisses the chooser without changing the shortcuts.
    func testKeepCurrentDismissesTheSheet() {
        let app = launchApp(freshInstall: true, optIntoChooser: true)
        let chooser = sheet(app)
        app.descendants(matching: .any)["KeymapChooserKeepCurrent"].click()
        XCTAssertTrue(poll(timeout: 5.0) { !chooser.exists }, "Not Now did not dismiss the chooser")
        app.terminate()
    }

    // MARK: - The suppression that protects every other UI test

    /// Without the opt-in a fresh install stays quiet, which is what keeps a
    /// modal sheet from swallowing the keystrokes the other UI tests send.
    func testFreshInstallStaysQuietWithoutTheOptIn() {
        let app = launchApp(freshInstall: true, optIntoChooser: false)
        let chooser = app.descendants(matching: .any)["KeymapChooser"]
        // Give it as long as the opt-in case gets, so passing cannot mean
        // "the assertion ran before the sheet would have appeared".
        XCTAssertFalse(
            poll(timeout: 10.0) { chooser.exists },
            "the chooser opened under a test harness that did not ask for it"
        )
        app.terminate()
    }

    // MARK: - The Settings entry point

    /// Settings does not go through the first-run gate, so Compare reaches the
    /// chooser on an install that was never asked and never will be.
    func testSettingsCompareButtonOpensTheChooserWithoutTheOptIn() {
        let app = launchApp(freshInstall: false, optIntoChooser: false)
        let window = openSettings(app)
        navigate(window, to: "Keyboard Shortcuts")
        let compare = requireElement(
            candidates: [
                window.buttons["SettingsKeyboardShortcutsBaseKeymapCompare"],
                window.descendants(matching: .any)["SettingsKeyboardShortcutsBaseKeymapCompare"],
            ],
            timeout: 8.0,
            description: "Base Keymap Compare button"
        )
        compare.click()
        let chooser = app.descendants(matching: .any)["KeymapChooser"]
        XCTAssertTrue(poll(timeout: 8.0) { chooser.exists }, "Compare did not open the chooser")
        app.terminate()
    }
}
