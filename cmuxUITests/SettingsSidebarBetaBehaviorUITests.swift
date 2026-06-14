import XCTest

/// Behavioral UI tests for the Settings **Sidebar** + **Beta Features**
/// section, scoped to the controls called out for this section:
/// the *Sidebar Branch Layout* picker (vertical vs inline), the active-tab
/// *indicator style*, and the *beta Feed* / *beta Dock* toggles.
///
/// What is actually assertable through XCUITest here, and why:
///
/// The real runtime consumers of these settings render *inside the
/// workspace sidebar rows and the right-sidebar mode bar* — surfaces that
/// only exist once a workspace has been materialized. The shared
/// `SettingsUITestCase` harness launches the app with `makeLaunchedApp()`
/// (no `CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP` / `_SHOW_RIGHT_SIDEBAR`
/// launch env), so the app comes up with an empty main window: no
/// workspace rows, and the right sidebar mode bar is not populated. That
/// means the *downstream* render effects (branch text stacked vs inline in
/// a workspace row; the `RightSidebarModeButton.dock` button appearing in
/// the mode bar) are NOT reachable without modifying the harness or adding
/// a launch-time setup seam, which this task forbids.
///
/// What *is* reachable and genuinely behavioral: each of these controls is
/// wired through a live `@AppStorage` / `@Setting` binding whose value
/// drives a *derived, reactive subtitle* in the same Settings window. The
/// subtitle text is computed from the current setting value
/// (`sidebarBranchVerticalLayout ? "Vertical: …" : "Inline: …"`,
/// `dockEnabled ? "Shows Dock …" : "Hides Dock …"`). Asserting that the
/// subtitle label flips when the control changes verifies the full
/// binding → store → dependent-view path, not merely that the control's
/// own state toggled. These subtitle strings are surfaced as `staticText`
/// in the Settings window and are unique, so they are stable to query.
///
/// Tiering for this section is recorded in the structured output. The
/// downstream consumer effects are documented in the TIER 2 block below.
final class SettingsSidebarBetaBehaviorUITests: SettingsUITestCase {

    // userDefaultsKeys for the in-scope settings, reset before/after each
    // test so the run starts from the shipped default.
    //  - sidebarBranchVerticalLayout: SidebarCatalogSection.branchVerticalLayout (default true / "Vertical")
    //  - sidebarActiveTabIndicatorStyle: indicator style key (default "leftRail")
    //  - rightSidebar.beta.feed.enabled: BetaFeaturesCatalogSection.rightSidebarFeed (default false)
    //  - rightSidebar.beta.dock.enabled: BetaFeaturesCatalogSection.rightSidebarDock (default false)
    private let inScopeDefaultsKeys = [
        "sidebarBranchVerticalLayout",
        "sidebarActiveTabIndicatorStyle",
        "rightSidebar.beta.feed.enabled",
        "rightSidebar.beta.dock.enabled",
    ]

    // Branch-layout subtitle strings (exact defaultValue copy from
    // SettingsPickerRow at cmuxApp.swift / SidebarSection.swift).
    private let branchVerticalSubtitle = "Vertical: each branch appears on its own line."
    private let branchInlineSubtitle = "Inline: all branches share one line."

    // Beta Feed subtitle strings (exact defaultValue copy from
    // BetaFeaturesSection.feedRow).
    private let feedOffSubtitle = "Hides Feed from the right sidebar until you enable it here."
    private let feedOnSubtitle = "Shows Feed in the right sidebar mode switcher for inline agent decisions."

    // Beta Dock subtitle strings (exact defaultValue copy from
    // BetaFeaturesSection.dockRow).
    private let dockOffSubtitle = "Hides Dock from the right sidebar until you enable it here."
    private let dockOnSubtitle = "Shows Dock in the right sidebar mode switcher for custom terminal controls."

    override func setUp() {
        super.setUp()
        resetDefaults(inScopeDefaultsKeys)
    }

    override func tearDown() {
        resetDefaults(inScopeDefaultsKeys)
        super.tearDown()
    }

    // MARK: - TIER 1: Sidebar Branch Layout picker

    /// Changing the **Sidebar Branch Layout** picker from Vertical to Inline
    /// flips the row's derived subtitle. The subtitle is computed from the
    /// `sidebarBranchVerticalLayout` binding, so a change in the rendered
    /// subtitle proves the picker selection propagated through the live
    /// settings store into a dependent view (not just that the popUpButton
    /// value changed).
    func testBranchLayoutPickerDrivesDerivedSubtitle() {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }

        navigate(window, to: "Sidebar")

        // Default is Vertical → the Vertical subtitle must be present and the
        // Inline subtitle absent.
        let verticalSubtitle = window.staticTexts[branchVerticalSubtitle]
        let inlineSubtitle = window.staticTexts[branchInlineSubtitle]
        XCTAssertTrue(
            poll(timeout: 5.0) { verticalSubtitle.exists },
            "Expected the default Vertical branch-layout subtitle to be shown"
        )
        XCTAssertFalse(inlineSubtitle.exists, "Inline subtitle should not be shown while Vertical is selected")

        // The branch-layout picker renders as a .menu Picker → a popUpButton
        // whose displayed value is the selected tag title ("Vertical").
        let layoutPopUp = requireElement(
            candidates: [
                window.popUpButtons["Vertical"],
                window.popUpButtons.matching(NSPredicate(format: "value == %@", "Vertical")).firstMatch,
            ],
            timeout: 5.0,
            description: "branch layout picker showing Vertical"
        )
        layoutPopUp.click()

        // Select "Inline" from the opened menu.
        let inlineItem = requireElement(
            candidates: [
                app.menuItems["Inline"],
                window.menuItems["Inline"],
            ],
            timeout: 4.0,
            description: "Inline menu item"
        )
        inlineItem.click()

        // Effect: derived subtitle flips to the Inline string and the Vertical
        // string disappears.
        XCTAssertTrue(
            poll(timeout: 5.0) { inlineSubtitle.exists },
            "Expected the Inline branch-layout subtitle after selecting Inline"
        )
        XCTAssertFalse(
            verticalSubtitle.exists,
            "Vertical subtitle should be gone once Inline is selected"
        )
    }

    // MARK: - TIER 1: Beta Feed toggle

    /// Toggling the **Beta Features → Feed** switch flips the row's derived
    /// subtitle between the "Hides Feed …" (off) and "Shows Feed …" (on)
    /// copy. The subtitle is computed from the `rightSidebarFeed` binding,
    /// so the label change verifies the toggle drove the live settings store
    /// and the dependent view re-rendered.
    func testBetaFeedToggleDrivesDerivedSubtitle() {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }

        navigate(window, to: "Beta Features")

        let offSubtitle = window.staticTexts[feedOffSubtitle]
        let onSubtitle = window.staticTexts[feedOnSubtitle]

        // Default is off → "Hides Feed …" present, "Shows Feed …" absent.
        XCTAssertTrue(
            poll(timeout: 5.0) { offSubtitle.exists },
            "Expected the default (off) Feed subtitle"
        )
        XCTAssertFalse(onSubtitle.exists, "On subtitle should not be shown while Feed is disabled")

        let feedToggle = toggle(window, id: "SettingsBetaFeedToggle")
        feedToggle.click()

        // Effect: subtitle flips to the "on" copy.
        XCTAssertTrue(
            poll(timeout: 5.0) { onSubtitle.exists },
            "Expected the (on) Feed subtitle after enabling Feed"
        )
        XCTAssertFalse(offSubtitle.exists, "Off subtitle should be gone once Feed is enabled")

        // Toggle back off to prove the binding is reversible (full round-trip).
        feedToggle.click()
        XCTAssertTrue(
            poll(timeout: 5.0) { offSubtitle.exists },
            "Expected the (off) Feed subtitle after disabling Feed again"
        )
        XCTAssertFalse(onSubtitle.exists, "On subtitle should be gone once Feed is disabled again")
    }

    // MARK: - TIER 1: Beta Dock toggle

    /// Toggling the **Beta Features → Dock** switch flips the row's derived
    /// subtitle between the "Hides Dock …" (off) and "Shows Dock …" (on)
    /// copy. The subtitle is computed from the `rightSidebarDockEnabled`
    /// binding, so the label change verifies the toggle drove the live
    /// settings store and the dependent view re-rendered.
    func testBetaDockToggleDrivesDerivedSubtitle() {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }

        navigate(window, to: "Beta Features")

        let offSubtitle = window.staticTexts[dockOffSubtitle]
        let onSubtitle = window.staticTexts[dockOnSubtitle]

        // Default is off → "Hides Dock …" present, "Shows Dock …" absent.
        XCTAssertTrue(
            poll(timeout: 5.0) { offSubtitle.exists },
            "Expected the default (off) Dock subtitle"
        )
        XCTAssertFalse(onSubtitle.exists, "On subtitle should not be shown while Dock is disabled")

        let dockToggle = toggle(window, id: "SettingsBetaDockToggle")
        dockToggle.click()

        // Effect: subtitle flips to the "on" copy.
        XCTAssertTrue(
            poll(timeout: 5.0) { onSubtitle.exists },
            "Expected the (on) Dock subtitle after enabling Dock"
        )
        XCTAssertFalse(offSubtitle.exists, "Off subtitle should be gone once Dock is enabled")

        // Toggle back off to prove the binding is reversible (full round-trip).
        dockToggle.click()
        XCTAssertTrue(
            poll(timeout: 5.0) { offSubtitle.exists },
            "Expected the (off) Dock subtitle after disabling Dock again"
        )
        XCTAssertFalse(onSubtitle.exists, "On subtitle should be gone once Dock is disabled again")
    }

    // MARK: - Tiering documentation for this section
    //
    // TIER 2 (needs runtime seam): Sidebar Branch Layout downstream render —
    //   the vertical-vs-inline arrangement only affects the branch/directory
    //   text *inside a workspace sidebar row* (ContentView workspace row,
    //   `usesVerticalBranchLayout`). The harness `makeLaunchedApp()` launches
    //   with no workspaces (no CMUX_UI_TEST_BONSPLIT setup env), so no
    //   workspace row exists to inspect, and the two layouts carry no
    //   distinguishing accessibilityIdentifier. Verifying the rendered layout
    //   would require the bonsplit/workspace setup launch env the fixed
    //   harness does not provide. The picker binding itself is covered above.
    //
    // TIER 2 (needs runtime seam): Active-tab indicator style — the control
    //   that edits `sidebarActiveTabIndicatorStyle` lives in the *Workspace
    //   Colors* section, not in Sidebar/Beta, so it is out of this section's
    //   UI. Its runtime effect is purely visual chrome on the active
    //   workspace row in the sidebar (left rail / dot / stripe drawn in
    //   SidebarAppearanceSupport + ContentView). With no workspace rows at
    //   harness launch there is nothing to render the indicator on, and the
    //   distinction is pixel-level appearance with no accessibility element.
    //   This would need a workspace-setup launch seam plus screenshot
    //   sampling (cf. RightSidebarChromeHeightUITests) to verify.
    //
    // TIER 2 (needs runtime seam): Beta Dock downstream effect — enabling the
    //   Dock toggle adds the `RightSidebarModeButton.dock` button to the
    //   right-sidebar mode bar (RightSidebarPanelView `availableModes`). That
    //   button only exists when the right sidebar is open over a workspace,
    //   which requires CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR=1 plus the
    //   bonsplit workspace setup at launch — env the shared harness does not
    //   set. The reactive binding is covered above; the mode-bar button would
    //   need the right-sidebar setup launch env (cf.
    //   RightSidebarChromeHeightUITests) to assert directly.
}
