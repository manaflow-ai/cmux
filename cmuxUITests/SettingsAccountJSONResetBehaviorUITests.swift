import XCTest

/// Behavioral UI tests for the Settings sections that make up the
/// "Account + cmux.json + Reset" group: the Account identity row, the
/// cmux.json config-file/docs card, and the Reset All Settings button.
///
/// These three sidebar sections (`Account`, `cmux.json`, `Reset`) are
/// almost entirely *action* rows: their controls fire a host action
/// (open a file in an external editor, launch a browser auth flow, open
/// a docs URL) rather than persist a defaults-backed value. The only
/// control whose effect is observable purely inside the cmux app surface
/// is **Reset All Settings**, which clears every catalog key — provable
/// by flipping a defaults-backed Settings toggle, resetting, and watching
/// the toggle snap back to its default.
///
/// Tier classification (see the structured output and the TIER comments
/// throughout this file):
/// - TIER 1: Reset All Settings (effect verified by a reverted toggle).
/// - TIER 2: cmux.json "Open" button (opens the config file in an
///   external editor — leaves the cmux process, no in-app element).
/// - TIER 3: Account Sign In / Sign Out (browser auth round trip),
///   cmux.json "Open Docs" link (external browser).
///
/// The Account identity row and the cmux.json card *layout* are still
/// asserted for presence, because those elements are real accessibility
/// elements in the main app surface (the identity row's signed-out title
/// + button; the `SettingsJSONOpenButton` / `SettingsJSONDocsLink` ids).
/// Presence is a weaker claim than an effect, so those are not counted as
/// TIER-1 behavioral coverage — they only guard against the section
/// failing to render at all.
final class SettingsAccountJSONResetBehaviorUITests: SettingsUITestCase {

    /// `userDefaultsKey` for the App-section "Inherit Workspace Working
    /// Directory" toggle (catalog id `app.workspaceInheritWorkingDirectory`,
    /// default `true`). Used as the Reset probe: it is benign (only affects
    /// the working directory new workspaces inherit, never the test surface)
    /// and surfaces as `SettingsWorkspaceInheritWorkingDirectoryToggle`.
    private let inheritDirKey = "workspaceInheritWorkingDirectory"
    private let inheritDirToggleID = "SettingsWorkspaceInheritWorkingDirectoryToggle"

    override func setUp() {
        super.setUp()
        // Start every test from the catalog default for the probe key so the
        // initial toggle state is deterministic (default `true` => ON).
        resetDefaults([inheritDirKey])
    }

    override func tearDown() {
        resetDefaults([inheritDirKey])
        super.tearDown()
    }

    // MARK: - TIER 1: Reset All Settings

    /// Reset All Settings must clear a previously-changed defaults-backed
    /// setting back to its catalog default. We flip the "Inherit Workspace
    /// Working Directory" toggle OFF (default is ON), click Reset, and
    /// assert the same toggle reads ON again. This verifies the *effect* of
    /// the reset (the persisted value was cleared and the control reflects
    /// the default), not merely that the Reset button is clickable.
    func testResetAllSettingsRevertsChangedToggleToDefault() {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }

        // Navigate to the App section where the probe toggle lives.
        navigate(window, to: "App")
        let probeToggle = toggle(window, id: inheritDirToggleID)

        // Default is ON. Confirm the starting state, then flip OFF.
        XCTAssertTrue(
            poll(timeout: 4.0) { isToggleOn(probeToggle) },
            "Inherit Working Directory should start ON (catalog default true)"
        )
        probeToggle.click()
        XCTAssertTrue(
            poll(timeout: 4.0) { !isToggleOn(probeToggle) },
            "Toggle should read OFF after the user clicks it"
        )

        // Trigger the reset from the Reset section.
        navigate(window, to: "Reset")
        let resetButton = requireElement(
            candidates: [
                window.buttons["Reset All Settings"],
                window.descendants(matching: .button)["Reset All Settings"],
            ],
            timeout: 4.0,
            description: "Reset All Settings button"
        )
        resetButton.click()

        // The reset clears the key; the toggle must snap back to its default
        // (ON). Re-resolve the toggle after navigating back so we read the
        // live control rather than a stale snapshot.
        navigate(window, to: "App")
        let toggleAfter = toggle(window, id: inheritDirToggleID)
        XCTAssertTrue(
            poll(timeout: 6.0) { isToggleOn(toggleAfter) },
            "Reset All Settings should restore Inherit Working Directory to its default (ON)"
        )
    }

    // MARK: - Presence guards (not TIER-1 effects)

    /// The Account identity row renders its AccountFlow-driven identity
    /// title and the trailing action button. The button label is auth-state
    /// dependent ("Sign In…" when signed out, "Sign Out" when signed in), and
    /// the harness launch args do not pin a session, so we assert the row
    /// surfaces *one* of those action buttons rather than hard-coding a single
    /// label (which would flake on a machine with a cached session). This is a
    /// presence guard for the row, not a behavioral effect test: clicking the
    /// button launches an external browser auth flow / backend round trip
    /// (TIER 3 below), which XCUITest cannot observe inside cmux.
    func testAccountSectionRendersIdentityRowActionButton() {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }

        navigate(window, to: "Account")

        let actionButton = requireElement(
            candidates: [
                window.buttons["Sign In…"],
                window.buttons["Sign Out"],
                window.descendants(matching: .button)["Sign In…"],
                window.descendants(matching: .button)["Sign Out"],
            ],
            timeout: 5.0,
            description: "Account identity-row action button (Sign In… / Sign Out)"
        )
        XCTAssertTrue(
            actionButton.exists,
            "Account section should render the identity-row sign-in/sign-out button"
        )
    }

    /// The cmux.json card renders its two action rows: the User config file
    /// row with an "Open" button (`SettingsJSONOpenButton`) and the
    /// Documentation row with an "Open Docs" link (`SettingsJSONDocsLink`).
    /// Presence guard only — both controls leave the cmux process when
    /// clicked (TIER 2 / TIER 3 below), so their effects are not asserted.
    func testSettingsJSONCardRendersOpenAndDocsControls() {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }

        navigate(window, to: "cmux.json")

        let openButton = requireElement(
            candidates: [
                window.buttons["SettingsJSONOpenButton"],
                window.descendants(matching: .button)["SettingsJSONOpenButton"],
            ],
            timeout: 5.0,
            description: "cmux.json Open button"
        )
        XCTAssertTrue(openButton.isEnabled, "Open config-file button should be enabled")

        let docsLink = requireElement(
            candidates: [
                window.links["SettingsJSONDocsLink"],
                window.buttons["SettingsJSONDocsLink"],
                window.descendants(matching: .any)["SettingsJSONDocsLink"],
            ],
            timeout: 4.0,
            description: "cmux.json Open Docs link"
        )
        XCTAssertTrue(docsLink.exists, "Documentation row should expose the Open Docs link")
    }

    // MARK: - Helpers

    /// Reads a SwiftUI `Toggle`'s on/off state across the control kinds it
    /// can surface as in XCUITest. Switches report `"1"` / `"0"` in
    /// `.value`; checkboxes report `isSelected`.
    private func isToggleOn(_ element: XCUIElement) -> Bool {
        if let value = element.value as? String {
            return value == "1"
        }
        if let value = element.value as? Bool {
            return value
        }
        return element.isSelected
    }

    // MARK: - Tier documentation (controls without an in-app observable effect)

    // TIER 2 (needs runtime seam): cmux.json "Open" button (SettingsJSONOpenButton)
    //   — calls SettingsHostActions.openConfigInExternalEditor(), implemented in
    //   the host as `NSWorkspace.shared.open(configFileURL)`. This launches the
    //   user's default editor for ~/.config/cmux/cmux.json in a *separate*
    //   application. cmux opens no in-app window and changes no in-app element,
    //   so XCUITest (scoped to the cmux process) cannot observe the effect.
    //   Verifying it would require a runtime seam (e.g. a host action spy /
    //   injectable opener that records the opened URL); per task constraints we
    //   do not add app seams. Asserted for presence only above.

    // TIER 3 (not e2e): Account "Sign In…" / "Sign Out" button (AccountIdentityCard)
    //   — `startSignIn()` routes to HostBrowserSignInFlow.beginSignIn(), which opens the
    //   cmux sign-in page in the system browser for an OAuth-style round trip;
    //   `signOut()` performs a backend network call. Neither produces an in-app
    //   window or element XCUITest can drive without real credentials and an
    //   external browser. The signed-out identity *display* state is asserted
    //   for presence above; the click effect is out of scope for e2e.

    // TIER 3 (not e2e): cmux.json "Open Docs" link (SettingsJSONDocsLink)
    //   — a SwiftUI `Link` to https://cmux.com/docs/configuration#cmux-json that
    //   opens in the system browser. Cross-app navigation with no cmux-side
    //   observable effect. Presence asserted above; the navigation itself is
    //   out of scope for e2e.
}
