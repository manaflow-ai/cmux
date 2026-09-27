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
/// What *is* reachable: each of these controls is wired through a live
/// `@AppStorage` / `@Setting` binding, and the control reads its value
/// back from that binding. Each row shows one fixed subtitle, so the tests
/// assert the control value round-trips through the store and the fixed
/// subtitle stays in every state. The subtitle strings are surfaced as
/// `staticText` in the Settings window and are unique, so they are stable
/// to query.
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

    // Fixed subtitle strings (exact defaultValue copy from SidebarSection
    // and BetaFeaturesSection).
    private let branchLayoutSubtitle = "Choose whether branches share one line or each get their own line."
    private let feedSubtitle = "Adds Feed to the right sidebar for answering agent requests."
    private let dockSubtitle = "Adds Dock to the right sidebar for custom terminal controls."

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
    /// updates the picker value read back from the
    /// `sidebarBranchVerticalLayout` binding, and the row keeps its fixed
    /// subtitle.
    func testBranchLayoutPickerKeepsFixedSubtitle() {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }

        navigate(window, to: "Sidebar")

        let subtitle = window.staticTexts[branchLayoutSubtitle]
        XCTAssertTrue(
            poll(timeout: 5.0) { subtitle.exists },
            "Expected the branch-layout subtitle to be shown"
        )

        // The branch-layout picker renders as a .menu Picker, a popUpButton
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

        let inlineByTitle = window.popUpButtons["Inline"]
        let inlineByValue = window.popUpButtons.matching(NSPredicate(format: "value == %@", "Inline")).firstMatch
        XCTAssertTrue(
            poll(timeout: 5.0) { inlineByTitle.exists || inlineByValue.exists },
            "Expected the branch-layout picker to show Inline after selecting it"
        )
        XCTAssertTrue(subtitle.exists, "The same subtitle should be shown once Inline is selected")
    }

    // MARK: - TIER 1: Beta Feed toggle

    /// The **Beta Features > Feed** switch reads its value back from the
    /// `rightSidebarFeed` binding and keeps its fixed subtitle.
    func testBetaFeedToggleKeepsFixedSubtitle() {
        assertBetaToggleRoundTrips(id: "SettingsBetaFeedToggle", subtitle: feedSubtitle)
    }

    // MARK: - TIER 1: Beta Dock toggle

    /// The **Beta Features > Dock** switch reads its value back from the
    /// `rightSidebarDockEnabled` binding and keeps its fixed subtitle.
    func testBetaDockToggleKeepsFixedSubtitle() {
        assertBetaToggleRoundTrips(id: "SettingsBetaDockToggle", subtitle: dockSubtitle)
    }

    /// Shared driver: the toggle starts off, turns on after one click, turns
    /// off after a second click, and the row shows the same subtitle in
    /// every state.
    private func assertBetaToggleRoundTrips(id: String, subtitle text: String) {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }

        navigate(window, to: "Beta Features")

        let subtitle = window.staticTexts[text]
        XCTAssertTrue(
            poll(timeout: 5.0) { subtitle.exists },
            "\(id): expected the subtitle at the default (off) value"
        )
        let control = toggle(window, id: id)
        XCTAssertFalse(isOn(control), "\(id): toggle should start off")

        control.click()
        XCTAssertTrue(
            poll(timeout: 5.0) { self.isOn(control) },
            "\(id): toggle should be on after one click"
        )
        XCTAssertTrue(subtitle.exists, "\(id): the same subtitle should be shown while on")

        // Toggle back off to prove the binding is reversible (full round-trip).
        control.click()
        XCTAssertTrue(
            poll(timeout: 5.0) { !self.isOn(control) },
            "\(id): toggle should be off after a second click"
        )
        XCTAssertTrue(subtitle.exists, "\(id): the same subtitle should be shown while off")
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
