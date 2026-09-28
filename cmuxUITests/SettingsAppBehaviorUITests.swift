import AppKit
import XCTest

/// Behavioral XCUITests for the Settings **App** section.
///
/// The App section is a single `SettingsCard` with ~30 rows. Most rows
/// drive runtime behavior that lives inside the main-app / Ghostty
/// terminal / Metal surface (dock badge, pane ring/flash, reorder,
/// iMessage, file drops, etc.) which a freshly launched UI-test app
/// cannot exercise without a runtime seam — those are documented as
/// TIER 2 / TIER 3 below.
///
/// What *is* observable through XCUITest, deterministically and without
/// adding any app seam, is the Settings window's own reaction to a
/// changed setting: several App toggles report the stored value while
/// their row keeps one fixed subtitle, and the "Menu Bar Only" row
/// disables the "Show in Menu Bar" row. Those rows expose stable accessibility identifiers
/// (`SettingsMinimalModeToggle`,
/// `SettingsWorkspaceInheritWorkingDirectoryToggle`,
/// `SettingsMenuBarOnlyToggle`, `CommandPaletteSearchAllSurfacesToggle`).
/// Each test below flips one of those, then asserts the toggle value
/// tracks the stored setting and the fixed subtitle stays, or that the
/// gated control's enabled state flips.
///
/// Subtitle strings are matched against the English `defaultValue`s in
/// `AppSection.swift`; the harness forces `-AppleLanguages (en)` so the
/// labels are stable across machines.
///
/// TIER 2 (needs runtime seam): effect lives in the main-app window /
/// Ghostty / Metal surface or in timing; not observable from a fresh
/// UI-test launch without an app seam this test must not add.
///   - Theme (app.appearance / appearanceMode): repaints the terminal
///     and chrome via the Metal-backed surface; appearance is not a
///     queryable accessibility attribute.
///   - App Icon (app.appIcon / appIconMode): swaps the Dock/app icon
///     image; Dock tile imagery is not an XCUITest accessibility element.
///   - New Workspace Placement (app.newWorkspacePlacement): only
///     observable after creating ≥2 workspaces and inspecting sidebar
///     order; requires workspace scaffolding the fresh UI-test launch
///     does not have (CMUX_UI_TEST_MODE skips session restore).
///   - Keep Workspace Open When Closing Last Surface
///     (closeWorkspaceOnLastSurfaceShortcut): only observable by closing
///     the last surface of a real workspace and checking whether the
///     workspace survives; needs workspace+surface scaffolding.
///   - Focus Pane on First Click (paneFirstClickFocus.enabled): effect is
///     window-activation + pane-focus timing on an inactive window;
///     requires two windows and focus-state inspection of a Ghostty pane.
///   - File Drops (fileDrop.defaultBehavior): effect is on a drag-and-drop
///     gesture over a terminal/editor surface; XCUITest cannot synthesize
///     the file-promise drag this consumes.
///   - Open Supported Files / Open Markdown (openSupportedFilesInCmux,
///     openMarkdownInCmuxViewer): effect triggers on Cmd-click of a file
///     in a terminal surface, opening a preview/markdown window; needs a
///     live terminal with clickable file text.
///   - iMessage Mode (app.iMessageMode): reorders a workspace to top and
///     shows the submitted message when an agent prompt is sent; needs an
///     agent surface and a send action.
///   - Reorder on Notification (workspaceAutoReorderOnNotification): needs
///     ≥2 workspaces and an injected notification to observe reordering.
///   - Dock Badge (notificationDockBadgeEnabled): sets the Dock tile
///     badge label; Dock tile state is not an XCUITest element.
///   - Show in Menu Bar (showMenuBarExtra): adds/removes an NSStatusItem
///     in the system menu bar, which is a separate process surface not in
///     this app's element tree. (Its *disabled* gating by Menu Bar Only is
///     TIER 1 below.)
///   - Unread Pane Ring / Pane Flash (notificationPaneRingEnabled,
///     notificationPaneFlashEnabled): draw a ring/flash overlay on a pane
///     inside the Ghostty/Metal surface on notification; not queryable and
///     needs an injected notification.
///   - Warn Before Quit (confirmQuit/warnBeforeQuitShortcut): effect is a
///     confirmation sheet on Cmd+Q; exercising it would terminate the app
///     under test mid-run.
///   - Warn Before Closing Tab (warnBeforeClosingTabShortcut): effect is a
///     confirmation sheet when closing a real tab; needs a tab to close
///     (the *subtitle* swap would be TIER 1, but this row has no stable
///     accessibility id to flip the toggle deterministically).
///   - Warn Before Tab Close Button (warnBeforeClosingTabXButton): same —
///     confirmation on the tab "X" button; needs a tab and a stable id.
///   - Hide Tab Close Button (hideTabCloseButton): hides the per-tab close
///     "X" in the main window tab strip; needs a workspace tab present and
///     has no stable accessibility id on its Settings toggle to flip.
///   - Rename Selects Existing Name (commandPalette.renameSelectAllOnFocus):
///     effect is whether the Command Palette rename field starts fully
///     selected vs caret-at-end; needs the palette open on a renamable
///     row and selection-range inspection.
///   - Preferred Editor / Notification Sound / Notification Command:
///     out-of-process effects (launch an editor, play a sound, run a shell
///     command); not in-app observable.
///
/// TIER 3 (not e2e): cross-app/external/no in-app UI effect.
///   - Send anonymous telemetry (sendAnonymousTelemetry): gates a network
///     analytics pipeline read only at next launch; no UI effect to assert
///     and nothing should hit the network from a test. Verify via the
///     telemetry client's unit tests instead.
final class SettingsAppBehaviorUITests: SettingsUITestCase {
    func testMobilePairingSettingsLightAndDarkCaptures() throws {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication.cmuxTestApplication()
            app.launchArguments += settingsLaunchArguments + ["-appearanceMode", appearance]
            app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
            launchAndActivate(app)
            defer { app.terminate() }
            let window = openSettings(app)
            navigate(window, to: "Mobile")
            let pairingToggle = window.checkBoxes["SettingsMobileIOSPairingHostToggle"].firstMatch
            XCTAssertTrue(pairingToggle.waitForExistence(timeout: 5))
            let detail = window.staticTexts["Lets iPhone and iPad pair with and connect to this Mac."].firstMatch
            if !isOn(pairingToggle) {
                pairingToggle.click()
            }
            XCTAssertTrue(poll(timeout: 5) { self.isOn(pairingToggle) })
            let title = window.staticTexts["Enable iOS pairing"].firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertTrue(detail.waitForExistence(timeout: 5))
            let header = try XCTUnwrap(window.staticTexts.matching(identifier: "Mobile").allElementsBoundByIndex.first {
                $0.frame.minX > window.frame.minX + 150
            })
            XCTAssertLessThan(title.frame.minY, window.staticTexts["Forward Notifications to iPhone"].firstMatch.frame.minY)
            let crop = header.frame.union(title.frame).union(detail.frame).insetBy(dx: -12, dy: -12)
            let source = try XCTUnwrap(window.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let scale = CGFloat(source.width) / window.frame.width
            let pixels = CGRect(
                x: (crop.minX - window.frame.minX) * scale,
                y: (crop.minY - window.frame.minY) * scale,
                width: crop.width * scale,
                height: crop.height * scale
            ).integral
            let cropped = try XCTUnwrap(source.cropping(to: pixels))
            let capture = XCTAttachment(image: NSImage(cgImage: cropped, size: crop.size))
            capture.name = "MacSettingsMobilePairing-\(appearance)"
            capture.lifetime = .keepAlways
            add(capture)
            let full = XCTAttachment(screenshot: window.screenshot())
            full.name = "Mac Settings - \(appearance)"
            full.lifetime = .keepAlways
            add(full)
            pairingToggle.click()
            app.terminate()
        }
    }

    func testGermanSettingsNavigationAndSearchUseTranslations() {
        assertLocalizedNavigation(
            language: "de", account: "Konto", shortcuts: "Tastaturkurzbefehle",
            searchLabel: "Suchen", languageLabel: "Sprache", rightToLeft: false
        )
    }

    func testArabicSettingsNavigationAndSearchUseTranslations() {
        assertLocalizedNavigation(
            language: "ar", account: "حساب", shortcuts: "اختصارات لوحة المفاتيح",
            searchLabel: "بحث", languageLabel: "اللغة", rightToLeft: true
        )
    }

    private func assertLocalizedNavigation(
        language: String, account: String, shortcuts: String,
        searchLabel: String, languageLabel: String, rightToLeft: Bool
    ) {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += [
            "-AppleLanguages", "(\(language))", "-appLanguage", "system",
            "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
            "-menuBarOnly", "false",
            "-AppleTextDirection", rightToLeft ? "YES" : "NO",
            "-NSForceRightToLeftWritingDirection", rightToLeft ? "YES" : "NO",
        ]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        launchAndActivate(app)
        defer { app.terminate() }
        // Open Settings after launch activation so the main window cannot
        // cover its search field during the startup window ordering.
        app.typeKey(",", modifierFlags: .command)
        let window = app.windows["cmux.settings"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        let sidebar = window.outlines.firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        XCTAssertTrue(sidebar.staticTexts[account].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(sidebar.staticTexts[shortcuts].firstMatch.exists)
        XCTAssertEqual(sidebar.frame.midX > window.frame.midX, rightToLeft)

        let search = requireElement(
            candidates: [window.searchFields.firstMatch, window.textFields[searchLabel].firstMatch],
            timeout: 5,
            description: "localized Settings search field"
        )
        search.click()
        search.typeText(languageLabel)
        XCTAssertTrue(sidebar.staticTexts[languageLabel].firstMatch.waitForExistence(timeout: 5))
        search.typeKey("a", modifierFlags: .command)
        search.typeText("Language")
        XCTAssertTrue(sidebar.staticTexts[languageLabel].firstMatch.waitForExistence(timeout: 5))
    }

    // UserDefaults keys (the catalog `userDefaultsKey`s) touched here, so
    // each test starts from the documented default regardless of prior
    // local state.
    private static let touchedKeys = [
        "workspacePresentationMode",          // Minimal Mode (default .standard)
        "workspaceInheritWorkingDirectory",   // Inherit CWD (default true)
        "menuBarOnly",                        // Menu Bar Only (default false)
        "showMenuBarExtra",                   // Show in Menu Bar (gated row)
        "commandPalette.switcherSearchAllSurfaces", // Palette all surfaces (default false)
        "forwardNotificationsToPhone",
        "forwardNotificationsToPhoneMode",
        "forwardNotificationsHideContent",
    ]

    override func setUp() {
        super.setUp()
        resetDefaults(Self.touchedKeys)
    }

    override func tearDown() {
        resetDefaults(Self.touchedKeys)
        super.tearDown()
    }

    // MARK: - English subtitle strings (must match AppSection defaultValues)

    private enum Subtitle {
        static let minimal = "Hides the workspace title bar and shows its controls in the sidebar."
        static let inherit = "Starts new workspaces in the working directory of the current workspace."
        static let palette = "Includes terminal, browser, and Markdown surfaces from every workspace in command palette results."
    }

    // MARK: - Helpers

    /// Opens Settings, lands on the App section, and returns the window.
    private func openAppSection(_ app: XCUIApplication) -> XCUIElement {
        let window = openSettings(app)
        navigate(window, to: "App")
        // The App section header carries a stable id; wait for it so we
        // know the detail pane rendered before we touch any row.
        let header = window.descendants(matching: .any)["SettingsAppSection"]
        XCTAssertTrue(poll(timeout: 4.0) { header.exists }, "App section did not render")
        return window
    }

    /// A static-text whose visible string equals `text`.
    private func subtitleText(_ window: XCUIElement, _ text: String) -> XCUIElement {
        window.staticTexts[text]
    }

    func testMobilePushForwardingIsVisibleAndDefaultsToAlways() {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += settingsLaunchArguments
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SHOW_SETTINGS"] = "1"
        // Headless CI leaves the app running in the background. Keep XCTest
        // alive through that known launch failure, then restore fail-fast so
        // every Settings assertion below remains a real regression failure.
        continueAfterFailure = true
        let launchOptions = XCTExpectedFailure.Options()
        launchOptions.isStrict = false
        XCTExpectFailure(
            "Headless CI may launch the app without foreground activation",
            options: launchOptions
        ) {
            app.launch()
        }
        continueAfterFailure = false
        XCTAssertTrue(
            poll(timeout: 10.0) {
                app.state == .runningForeground || app.state == .runningBackground
            },
            "App failed to launch. state=\(app.state.rawValue)"
        )
        let window = app.windows["Settings"]
        XCTAssertTrue(
            poll(timeout: 8.0) { window.exists },
            "Settings window did not open"
        )
        navigate(window, to: "Mobile")

        let forwarding = toggle(
            window,
            id: "SettingsMobilePhonePushForwardingToggle"
        )
        XCTAssertEqual(forwarding.value as? String, "1")

        let mode = requireElement(
            candidates: [
                window.popUpButtons["SettingsMobilePhonePushModePicker"],
                window.menuButtons["SettingsMobilePhonePushModePicker"],
                window.descendants(matching: .any)["SettingsMobilePhonePushModePicker"],
            ],
            timeout: 4,
            description: "phone push forwarding mode picker"
        )
        XCTAssertTrue(mode.label.contains("Always") || mode.value as? String == "Always")
        _ = toggle(window, id: "SettingsMobilePhonePushHideContentToggle")
    }

    // MARK: - TIER 1: Minimal Mode toggle keeps its fixed subtitle

    /// Toggling Minimal Mode flips the stored `workspacePresentationMode`,
    /// which the toggle value reads back through the view-model. The row
    /// shows the same subtitle in both states.
    func testMinimalModeToggleKeepsFixedSubtitle() {
        let app = makeLaunchedApp()
        let window = openAppSection(app)

        XCTAssertTrue(
            poll(timeout: 4.0) { subtitleText(window, Subtitle.minimal).exists },
            "Expected the Minimal Mode subtitle at default"
        )
        let minimal = toggle(window, id: "SettingsMinimalModeToggle")
        XCTAssertFalse(isOn(minimal), "Minimal Mode should start off (.standard)")

        minimal.click()
        XCTAssertTrue(
            poll(timeout: 4.0) { self.isOn(minimal) },
            "Minimal Mode should be on after one click"
        )
        XCTAssertTrue(
            subtitleText(window, Subtitle.minimal).exists,
            "The same subtitle should be shown while Minimal Mode is on"
        )

        // Toggle back to confirm the bind is two-way and tracks the stored
        // value, not a latch.
        minimal.click()
        XCTAssertTrue(
            poll(timeout: 4.0) { !self.isOn(minimal) },
            "Minimal Mode should be off after a second click"
        )
        XCTAssertTrue(
            subtitleText(window, Subtitle.minimal).exists,
            "The same subtitle should be shown after Minimal Mode turns off"
        )

        closeSettings(app, window)
    }

    // MARK: - TIER 1: Inherit Working Directory toggle keeps its fixed subtitle

    /// Default is `true`, so the toggle starts on; one click turns it off
    /// and the row keeps the same subtitle.
    func testInheritWorkingDirectoryToggleKeepsFixedSubtitle() {
        let app = makeLaunchedApp()
        let window = openAppSection(app)

        XCTAssertTrue(
            poll(timeout: 4.0) { subtitleText(window, Subtitle.inherit).exists },
            "Expected the inherit subtitle at default"
        )
        let inherit = toggle(window, id: "SettingsWorkspaceInheritWorkingDirectoryToggle")
        XCTAssertTrue(isOn(inherit), "Inherit Working Directory should start on (true)")

        inherit.click()
        XCTAssertTrue(
            poll(timeout: 4.0) { !self.isOn(inherit) },
            "Inherit Working Directory should be off after one click"
        )
        XCTAssertTrue(
            subtitleText(window, Subtitle.inherit).exists,
            "The same subtitle should be shown while inherit is off"
        )

        closeSettings(app, window)
    }

    // MARK: - TIER 1: Command Palette Searches All Surfaces keeps its fixed subtitle

    /// Default is `false`, so the toggle starts off; one click turns it on
    /// and the row keeps the same subtitle.
    func testCommandPaletteAllSurfacesToggleKeepsFixedSubtitle() {
        let app = makeLaunchedApp()
        let window = openAppSection(app)

        XCTAssertTrue(
            poll(timeout: 4.0) { subtitleText(window, Subtitle.palette).exists },
            "Expected the all-surfaces subtitle at default"
        )
        let palette = toggle(window, id: "CommandPaletteSearchAllSurfacesToggle")
        XCTAssertFalse(isOn(palette), "All-surfaces search should start off (false)")

        palette.click()
        XCTAssertTrue(
            poll(timeout: 4.0) { self.isOn(palette) },
            "All-surfaces search should be on after one click"
        )
        XCTAssertTrue(
            subtitleText(window, Subtitle.palette).exists,
            "The same subtitle should be shown while all-surfaces search is on"
        )

        closeSettings(app, window)
    }

    // MARK: - TIER 1: Menu Bar Only disables the Show in Menu Bar row

    /// "Menu Bar Only" gates the "Show in Menu Bar" row with
    /// `.disabled(menuBarOnly.current)`. Enabling Menu Bar Only must make
    /// the Show-in-Menu-Bar toggle report `isEnabled == false`; disabling
    /// it must re-enable that toggle. This is the in-Settings observable
    /// effect of the Menu Bar Only setting (the actual Dock-icon hiding is
    /// TIER 2). We locate the gated toggle by walking to the row that
    /// follows the Menu Bar Only row.
    func testMenuBarOnlyDisablesShowInMenuBarRow() {
        let app = makeLaunchedApp()
        let window = openAppSection(app)

        let menuBarOnly = toggle(window, id: "SettingsMenuBarOnlyToggle")

        // The "Show in Menu Bar" row has no explicit id; identify it by its
        // title static text, then find the nearest sibling toggle/checkbox.
        // Resolve the gated control as the switch/checkbox whose enabled
        // state we can read. With only the Menu Bar Only toggle carrying an
        // id, the remaining switches in the card are addressed positionally;
        // we assert the *aggregate* effect: when Menu Bar Only is on, at
        // least one previously-enabled switch in the card becomes disabled,
        // and re-enabling Menu Bar Only restores it.
        let showInMenuBarTitle = window.staticTexts["Show in Menu Bar"]
        XCTAssertTrue(
            poll(timeout: 4.0) { showInMenuBarTitle.exists },
            "Show in Menu Bar row should be present"
        )

        // Count enabled toggle controls before turning Menu Bar Only on.
        // SwiftUI `Toggle(.switch)` surfaces as either a switch or a
        // checkbox in XCUITest depending on host config, so count both
        // kinds (matching the harness `toggle()` resolution). The gated
        // Show-in-Menu-Bar row contributes one enabled control at default.
        func enabledToggleCount() -> Int {
            let switches = window.switches.allElementsBoundByIndex
            let checkboxes = window.checkBoxes.allElementsBoundByIndex
            return (switches + checkboxes).filter { $0.exists && $0.isEnabled }.count
        }

        let baselineEnabled = enabledToggleCount()

        menuBarOnly.click()
        // Effect: the gated Show-in-Menu-Bar control becomes disabled, so the
        // count of enabled toggle controls drops by at least one.
        XCTAssertTrue(
            poll(timeout: 4.0) { enabledToggleCount() < baselineEnabled },
            "Enabling Menu Bar Only should disable the gated Show in Menu Bar control"
        )

        menuBarOnly.click()
        XCTAssertTrue(
            poll(timeout: 4.0) { enabledToggleCount() >= baselineEnabled },
            "Disabling Menu Bar Only should re-enable the gated control"
        )

        closeSettings(app, window)
    }
}
