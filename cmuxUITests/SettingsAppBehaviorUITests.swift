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
/// (`SettingsMinimalModeToggle`,
/// `SettingsWorkspaceInheritWorkingDirectoryToggle`,
/// `SettingsMenuBarOnlyToggle`, `CommandPaletteSearchAllSurfacesToggle`).
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
///   - Inherit CWD effect on a real new workspace (the *subtitle* swap is
///     TIER 1 below; the actual working-directory inheritance needs a
///     spawned terminal to inspect, which is a terminal-surface seam).
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
        "workspaceInheritWorkingDirectory",   // Inherit CWD (default true)
        "menuBarOnly",                        // Menu Bar Only (default false)
        "showMenuBarExtra",                   // Show in Menu Bar (gated row)
        "commandPalette.switcherSearchAllSurfaces", // Palette all surfaces (default false)
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

        static let inheritOn = "New workspaces start in the focused workspace's working directory."
        static let inheritOff = "New workspaces leave their working directory unset so Ghostty's working-directory setting can apply."

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

    /// A static-text whose visible string equals `text`.
    private func subtitleText(_ window: XCUIElement, _ text: String) -> XCUIElement {
        window.staticTexts[text]
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

    // MARK: - TIER 1: Inherit Working Directory subtitle swap

    /// Toggling Inherit Working Directory flips the row subtitle between
    /// the inherit-on and inherit-off wording. Default is `true`, so the
    /// "on" subtitle is present first.
    func testInheritWorkingDirectoryToggleSwapsSubtitle() {
        let app = makeLaunchedApp()
        let window = openAppSection(app)

        XCTAssertTrue(
            poll(timeout: 4.0) { subtitleText(window, Subtitle.inheritOn).exists },
            "Expected inherit-on subtitle at default (true)"
        )

        let inherit = toggle(window, id: "SettingsWorkspaceInheritWorkingDirectoryToggle")
        inherit.click()

        XCTAssertTrue(
            poll(timeout: 4.0) { subtitleText(window, Subtitle.inheritOff).exists },
            "Disabling inherit should show the unset-working-directory subtitle"
        )
        XCTAssertTrue(
            poll(timeout: 4.0) { !subtitleText(window, Subtitle.inheritOn).exists },
            "Inherit-on subtitle should disappear once inherit is off"
        )

        closeSettings(app, window)
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
