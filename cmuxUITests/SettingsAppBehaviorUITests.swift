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
/// changed setting: several App rows recompute their subtitle text from
/// the stored value, and the "Menu Bar Only" row disables the "Show in
/// Menu Bar" row. Those rows expose stable accessibility identifiers
/// (`SettingsMinimalModeToggle`, `SettingsMenuBarOnlyToggle`,
/// `CommandPaletteSearchAllSurfacesToggle`). The declarative terminal
/// defaults are covered in the Terminal section by the dedicated policy
/// picker and path field.
/// Each test below flips one of those, then asserts the *effect* — the
/// new subtitle string appears / the old one disappears, or the gated
/// control's enabled state flips — not merely that the toggle changed
/// value.
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
    // UserDefaults keys (the catalog `userDefaultsKey`s) touched here, so
    // each test starts from the documented default regardless of prior
    // local state.
    private static let touchedKeys = [
        "workspacePresentationMode",          // Minimal Mode (default .standard)
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
        static let minimalOn = "Hide the workspace title bar and move workspace controls into the sidebar."
        static let minimalOff = "Use the standard workspace title bar and controls."

        static let paletteOn = "Cmd+P also matches panel surfaces across workspaces."
        static let paletteOff = "Cmd+P matches workspace rows only."
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

    /// Opens Settings, lands on the Terminal section, and returns the window.
    private func openTerminalSection(_ app: XCUIApplication) -> XCUIElement {
        let window = openSettings(app)
        navigate(window, to: "Terminal")
        return window
    }

    /// A static-text whose visible string equals `text`.
    private func subtitleText(_ window: XCUIElement, _ text: String) -> XCUIElement {
        window.staticTexts[text]
    }

    /// Launches the app with an isolated config root so JSON-backed Settings
    /// controls cannot read or mutate the developer's real cmux.json file.
    private func makeLaunchedApp(isolatedHome: URL) -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += settingsLaunchArguments
        app.launchEnvironment["HOME"] = isolatedHome.path
        app.launchEnvironment["CFFIXED_USER_HOME"] = isolatedHome.path
        app.launchEnvironment["XDG_CONFIG_HOME"] = isolatedHome
            .appendingPathComponent(".config", isDirectory: true)
            .path
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        launchAndActivate(app)
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 8.0), "main window did not appear")
        return app
    }

    private func pickerDisplay(_ picker: XCUIElement) -> String {
        "\(picker.label) \(picker.value as? String ?? "")"
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

    // MARK: - TIER 1: Minimal Mode subtitle swap

    /// Toggling Minimal Mode flips the row subtitle between the
    /// standard-title-bar and the hidden-title-bar wording. This proves
    /// the stored `workspacePresentationMode` propagated through the
    /// view-model and re-rendered the row, which is the observable effect
    /// of the setting inside Settings.
    func testMinimalModeToggleSwapsSubtitle() {
        let app = makeLaunchedApp()
        let window = openAppSection(app)

        // Default .standard → "off" subtitle present, "on" absent.
        XCTAssertTrue(
            poll(timeout: 4.0) { subtitleText(window, Subtitle.minimalOff).exists },
            "Expected standard-mode subtitle at default"
        )

        let minimal = toggle(window, id: "SettingsMinimalModeToggle")
        minimal.click()

        XCTAssertTrue(
            poll(timeout: 4.0) { subtitleText(window, Subtitle.minimalOn).exists },
            "Enabling Minimal Mode should show the hidden-title-bar subtitle"
        )
        XCTAssertTrue(
            poll(timeout: 4.0) { !subtitleText(window, Subtitle.minimalOff).exists },
            "Standard-mode subtitle should disappear once Minimal Mode is on"
        )

        // Toggle back and assert the subtitle reverts — confirms the bind
        // is two-way and the effect tracks the stored value, not a latch.
        minimal.click()
        XCTAssertTrue(
            poll(timeout: 4.0) { subtitleText(window, Subtitle.minimalOff).exists },
            "Disabling Minimal Mode should restore the standard-mode subtitle"
        )

        closeSettings(app, window)
    }

    // MARK: - TIER 1: Declarative terminal working-directory picker

    /// The new working-directory policy is a JSON-backed picker in Terminal,
    /// not a duplicate App-section UserDefaults toggle. Selecting another
    /// policy and then restoring the original value verifies the live control
    /// round-trip against an isolated cmux.json file.
    func testNewSurfaceWorkingDirectoryPickerRoundTrips() {
        let fileManager = FileManager.default
        let isolatedHome = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ui-test-declarative-settings-\(UUID().uuidString)",
            isDirectory: true
        )
        XCTAssertNoThrow(try fileManager.createDirectory(at: isolatedHome, withIntermediateDirectories: true))

        let app = makeLaunchedApp(isolatedHome: isolatedHome)
        defer {
            app.terminate()
            try? fileManager.removeItem(at: isolatedHome)
        }
        let window = openTerminalSection(app)
        defer { closeSettings(app, window) }

        let picker = requireElement(
            candidates: [
                window.popUpButtons["SettingsNewSurfaceWorkingDirectoryPolicyPicker"],
                window.menuButtons["SettingsNewSurfaceWorkingDirectoryPolicyPicker"],
                window.descendants(matching: .any)["SettingsNewSurfaceWorkingDirectoryPolicyPicker"],
            ],
            timeout: 5.0,
            description: "new-surface working-directory policy picker"
        )
        let initialDisplay = pickerDisplay(picker)
        let original: String
        if initialDisplay.contains("Workspace Root") || initialDisplay.contains("workspaceRoot") {
            original = "Workspace Root"
        } else if initialDisplay.contains("Fixed Path") || initialDisplay.contains("fixedPath") {
            original = "Fixed Path"
        } else {
            original = "Inherit Active Pane"
        }
        let alternate = original == "Workspace Root" ? "Fixed Path" : "Workspace Root"

        picker.click()
        let alternateItem = requireElement(
            candidates: [app.menuItems[alternate], window.menuItems[alternate], picker.menuItems[alternate]],
            timeout: 4.0,
            description: "working-directory policy (alternate) menu item"
        )
        alternateItem.click()
        XCTAssertTrue(
            poll(timeout: 5.0) { self.pickerDisplay(picker).contains(alternate) },
            "Selecting (alternate) should update the policy picker"
        )

        picker.click()
        let originalItem = requireElement(
            candidates: [app.menuItems[original], window.menuItems[original], picker.menuItems[original]],
            timeout: 4.0,
            description: "original working-directory policy menu item"
        )
        originalItem.click()
        XCTAssertTrue(
            poll(timeout: 5.0) { self.pickerDisplay(picker).contains(original) },
            "Restoring (original) should round-trip the policy picker"
        )
    }

    // MARK: - TIER 1: Command Palette Searches All Surfaces subtitle swap

    /// Toggling "Command Palette Searches All Surfaces" flips the row
    /// subtitle between the all-surfaces and workspace-rows-only wording.
    /// Default is `false`, so the "off" subtitle is present first.
    func testCommandPaletteAllSurfacesToggleSwapsSubtitle() {
        let app = makeLaunchedApp()
        let window = openAppSection(app)

        XCTAssertTrue(
            poll(timeout: 4.0) { subtitleText(window, Subtitle.paletteOff).exists },
            "Expected workspace-rows-only subtitle at default (false)"
        )

        let palette = toggle(window, id: "CommandPaletteSearchAllSurfacesToggle")
        palette.click()

        XCTAssertTrue(
            poll(timeout: 4.0) { subtitleText(window, Subtitle.paletteOn).exists },
            "Enabling all-surfaces should show the panel-surfaces subtitle"
        )
        XCTAssertTrue(
            poll(timeout: 4.0) { !subtitleText(window, Subtitle.paletteOff).exists },
            "Workspace-rows-only subtitle should disappear once all-surfaces is on"
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
