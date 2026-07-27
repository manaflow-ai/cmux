import XCTest

/// Behavioral UI tests for the Settings → **Browser** section
/// (`Packages/macOS/CmuxSettingsUI/.../Sections/BrowserSection.swift`).
///
/// The goal of each test here is behavioral: change a setting or press a
/// control, then drive the surface it affects and assert the *effect*
/// actually happened, not merely that the control flipped.
///
/// Most of the Browser section's settings change state that only the
/// embedded WebKit/Ghostty browser surface reads (search engine, theme,
/// memory saver, HTTP allowlist, react-grab injection). Those are not
/// observable through XCUITest without a runtime seam and are documented
/// in the tier comments below rather than fake-tested.
///
/// The one effect that crosses into an XCUITest-observable AppKit surface
/// is the **Import Browser Data → Choose…** button: it routes through
/// `HostSettingsActions.openBrowserImportFlow()` →
/// `BrowserDataImportCoordinator.shared.presentImportDialog()`, which
/// opens the import wizard window. That wizard is the same surface the
/// existing `BrowserImportProfilesUITests` drives, and it honors the
/// `CMUX_UI_TEST_BROWSER_IMPORT_FIXTURE` env seam, so we can launch with a
/// fake installed browser and assert the wizard appears after pressing the
/// Settings button.
final class SettingsBrowserBehaviorUITests: SettingsUITestCase {

    // Catalog `userDefaultsKey`s touched by this section. Cleared before
    // each test so a stale value from a prior run can't mask the effect.
    private static let browserDefaultsKeys = [
        "browserDisabled",
        "browserSearchEngine",
        "browserThemeMode",
        "browserHiddenWebViewDiscardEnabled",
        "browserHiddenWebViewDiscardDelaySeconds",
        "browserInsecureHTTPAllowlist",
        "browserImportHintShowOnBlankTabs",
        "reactGrabVersion",
        "browserDisabledOverride",
    ]

    override func setUp() {
        super.setUp()
        resetDefaults(Self.browserDefaultsKeys)
    }

    override func tearDown() {
        resetDefaults(Self.browserDefaultsKeys)
        super.tearDown()
    }

    // MARK: - TIER 1 (behavioral)

    /// Import Browser Data → **Choose…** opens the import wizard.
    ///
    /// Launches with a fixture installed browser so the coordinator has
    /// something to import from (otherwise it would show the "No importable
    /// browsers found" alert). Opens Settings, scrolls to the Browser
    /// section, presses the Choose… button (`SettingsBrowserImportChooseButton`,
    /// which exists in `BrowserSection.swift`), then asserts the import
    /// wizard surface appears. The wizard's first-step `Next` button and the
    /// "Import Browser Data" window are the same elements
    /// `BrowserImportProfilesUITests` asserts on, so they are known to exist.
    func testImportChooseButtonOpensImportWizard() {
        let app = makeLaunchedAppWithImportFixture()
        let window = openSettings(app)
        navigate(window, to: "Browser")

        let chooseButton = requireElement(
            candidates: [
                window.buttons["SettingsBrowserImportChooseButton"],
                app.buttons["SettingsBrowserImportChooseButton"],
            ],
            timeout: 6.0,
            description: "Import Browser Data Choose… button"
        )
        chooseButton.click()

        // Effect: the import wizard surface opens. The wizard is presented
        // as its own AppKit window (titled "Import Browser Data") whose
        // first step exposes a `Next` button.
        let wizardAppeared = poll(timeout: 6.0) {
            app.buttons["Next"].exists || app.windows["Import Browser Data"].exists
        }
        XCTAssertTrue(
            wizardAppeared,
            "Expected the browser import wizard to open after pressing Choose…"
        )
    }

    // MARK: - Launch helpers

    /// Launches the app in UI-test mode with a fixture installed browser so
    /// the import coordinator opens the wizard instead of the
    /// "No importable browsers found" alert. Mirrors the env seam used by
    /// `BrowserImportProfilesUITests`.
    private func makeLaunchedAppWithImportFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += settingsLaunchArguments
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BROWSER_IMPORT_FIXTURE"] =
            #"{"browserName":"Helium","profiles":["You","austin"]}"#
        app.launchEnvironment["CMUX_UI_TEST_BROWSER_IMPORT_DESTINATIONS"] = #"["Default"]"#
        app.launchEnvironment["CMUX_UI_TEST_BROWSER_IMPORT_MODE"] = "capture-only"
        launchAndActivate(app)
        XCTAssertTrue(
            waitForWindowCount(atLeast: 1, app: app, timeout: 8.0),
            "main window did not appear"
        )
        return app
    }

    // MARK: - TIER 2 (needs runtime seam): effects live in the browser/WebKit surface or in a key mismatch

    // TIER 2 (needs runtime seam): Enable cmux Browser (BrowserEnabledToggle) —
    //   The SPM `BrowserSection` toggle writes only the catalog key
    //   `browserDisabled`. The runtime gate that decides browser
    //   availability — `BrowserAvailabilitySettings.isDisabled()`, which
    //   drives the `palette.enableBrowser` / `palette.disableBrowser`
    //   command-palette context key and WebView creation — reads a
    //   *different* key, `browserDisabledOverride`, which the SPM section
    //   never writes (only the legacy `cmuxApp.browserEnabledBinding`
    //   mirrors both keys). So toggling Enable cmux Browser in the new
    //   Settings UI produces no XCUITest-observable change (the command
    //   palette still shows "Disable cmux Browser"). Verifying this
    //   behaviorally requires the host to bind both keys (a real product
    //   fix) before a palette-flip assertion would pass; asserting it now
    //   would be a test against a known seam gap, not against intended
    //   behavior.
    //
    // TIER 2 (needs runtime seam): Default Search Engine (browser.defaultSearchEngine) —
    //   Consumed by `BrowserPanel.currentSearchEngine` / `currentConfiguration`
    //   to build the omnibar search URL inside the embedded WebKit browser.
    //   The effect (a query resolving to that engine's URL) only manifests
    //   inside the browser web content, which XCUITest cannot inspect
    //   without a navigation-capture seam.
    //
    // TIER 2 (needs runtime seam): Browser Theme (browser.theme) —
    //   `BrowserThemeSettings.mode` is applied via
    //   `BrowserPopupWindowController.setBrowserThemeMode` to the WebKit
    //   content's preferred color scheme. The forced light/dark rendering
    //   happens inside web content, not in any AppKit accessibility element.
    //
    // TIER 2 (needs runtime seam): Browser Memory Saver enable
    //   (SettingsBrowserHiddenWebViewDiscardToggle) and Memory Saver Delay
    //   (SettingsBrowserHiddenWebViewDiscardDelayStepper / browser.hiddenWebViewDiscardDelaySeconds) —
    //   These feed `BrowserHiddenWebViewDiscardPolicy`, which discards a
    //   hidden WebView's page memory after the delay and restores it when
    //   shown. The observable effect is a WebView being torn down/restored
    //   after a timer; it is both inside the browser surface and
    //   time-based, so it needs a deterministic discard-event seam to test.
    //
    // TIER 2 (needs runtime seam): HTTP Hosts Allowlist
    //   (SettingsBrowserHTTPAllowlistField + SettingsBrowserHTTPAllowlistSaveButton /
    //   browser.insecureHttpHostsAllowedInEmbeddedBrowser) —
    //   `BrowserInsecureHTTPSettings` gates whether an http:// host opens in
    //   cmux without a warning prompt. The effect (warning prompt shown or
    //   suppressed on navigation) requires navigating the embedded browser
    //   to an http host, which is a WebKit-surface interaction not reachable
    //   from Settings alone in XCUITest. The Save button's draft-sync logic
    //   is unit-testable against the store, not e2e.
    //
    // TIER 2 (needs runtime seam): Show import hint on blank browser tabs
    //   (SettingsBrowserImportHintToggle / browser.showImportHintOnBlankTabs) —
    //   Controls whether the import hint (BrowserImportHintImportButton) is
    //   rendered on a blank embedded-browser tab. Asserting the effect
    //   requires opening a blank browser tab and inspecting WebView-hosted
    //   chrome; `BrowserImportProfilesUITests` exercises that hint surface
    //   only via dedicated CMUX_UI_TEST_BROWSER_IMPORT_HINT_* launch seams,
    //   not by flipping this Settings toggle at runtime.
    //
    // TIER 2 (needs runtime seam): React Grab Version
    //   (SettingsReactGrabVersionField / browser.reactGrabVersion) —
    //   The pinned version is injected by the toolbar React Grab button
    //   (Cmd+Shift+G) into the active embedded WebView. The effect (which
    //   npm version of react-grab loads) is entirely inside browser web
    //   content; verifying it needs an injection/version-capture seam.

    // MARK: - TIER 3 (not e2e)

    // TIER 3 (not e2e): Browsing History → Clear History…
    //   (settings.browser.history.clearButton) —
    //   The Clear button is disabled when the history count is 0, and in
    //   UI-test mode `BrowserHistoryStore.shared` has no seeded entries, so
    //   the button is disabled and the destructive confirmation dialog
    //   cannot be reached. The observable effect (omnibar suggestions
    //   shrinking) lives in the embedded browser omnibar. There is no
    //   practical end-to-end path to seed history and then observe cleared
    //   suggestions purely through Settings in XCUITest; this is better
    //   covered by a `BrowserHistoryStore` unit test (clear → count == 0).
    //
    // TIER 3 (not e2e): Import Browser Data → Refresh
    //   (inside SettingsBrowserImportActions) —
    //   The Refresh button is hard-disabled (`.disabled(true)`) in
    //   `BrowserSection.swift`; it is a placeholder with no action wired,
    //   so there is no runtime effect to observe.
}
