import XCTest

/// Behavioral UI tests for the Settings **Terminal** and **TextBox** sections.
///
/// The Terminal section exposes six controls:
/// Show Terminal Scroll Bar, Copy on Selection, Resume Agent Sessions on Reopen,
/// Agent Hibernation (enable), Hibernate After Idle Seconds, and Max Live Agent
/// Terminals. The TextBox section exposes three controls:
/// Show TextBox on New Terminals, Focus TextBox on New Terminals, and TextBox
/// Max Lines.
///
/// Most of these settings only become observable inside the
/// Ghostty/Metal terminal surface, the system clipboard, or across an
/// app relaunch — none of which a single in-process XCUITest can drive
/// deterministically without adding a runtime seam (which this task
/// forbids). What *is* observable through XCUITest is the Settings row
/// itself: six toggle rows report the live setting value through their
/// control while keeping one fixed description (`subtitle`), and the
/// three numeric rows render a value label that updates when the stepper
/// is driven.
///
/// These tests assert that observable state: the toggle value reads back
/// through the same persisted settings model the rest of the app
/// consumes, the fixed subtitle stays in both states, and the value
/// label re-renders to match the changed setting.
///
/// Identifiers asserted here all exist in the live Settings UI
/// (`Sources/cmuxApp.swift`, the `Settings…` window) and in the
/// migrated `CmuxSettingsUI.TerminalSection`:
///   SettingsTerminalScrollBarToggle,
///   SettingsTerminalCopyOnSelectToggle,
///   SettingsTerminalAgentAutoResumeToggle,
///   SettingsTerminalAgentHibernationToggle,
///   SettingsTerminalAgentHibernationIdleSecondsStepper,
///   SettingsTerminalAgentHibernationMaxLiveStepper.
///   SettingsTextBoxShowOnNewTerminalsToggle,
///   SettingsTextBoxFocusOnNewTerminalsToggle,
///   SettingsTextBoxMaxLinesStepper.
///
/// ---------------------------------------------------------------------
/// TIER 2 (needs runtime seam) — deep runtime effects not e2e-observable
/// ---------------------------------------------------------------------
/// TIER 2 (needs runtime seam): Show Terminal Scroll Bar
///   (`terminal.showScrollBar`) — the effect is the visibility of a
///   native `NSScroller` hosted inside the Ghostty terminal scroll view
///   (`Sources/GhosttyTerminalView.swift`, gated on
///   `TerminalScrollBarSettings.isVisible()` and a legacy scroller
///   preference). The scroller only materializes with a live terminal
///   surface that has scrollback, is a Metal/AppKit overlay, and is not
///   exposed as a queryable XCUI accessibility element. Verifying real
///   visibility would require a debug seam that reports scroller frame /
///   alpha. Behaviorally tested here only at the Settings-row level
///   (toggle value, fixed subtitle).
///
/// TIER 2 (needs runtime seam): TextBox Max Lines
///   (`terminal.textBoxMaxLines`) — consumed by
///   `TerminalPanelView` via
///   `TerminalTextBoxInputSettings.resolvedMaxLines(...)` to cap the rich
///   input's growth height. The effect is pure layout geometry of the
///   SwiftUI input editor (no accessibility identifier, height clamps
///   only after enough wrapped lines are typed into a live terminal
///   surface). Not observable without a geometry-reporting seam.
///   Behaviorally tested here only at the Settings-row level (stepper
///   value label updates).
///
/// TIER 2 (needs runtime seam): Copy on Selection
///   (`terminal.copyOnSelect`) — reloads the Ghostty surface config
///   (`reloadConfiguration(source: "settings.terminal.copyOnSelect")`)
///   so a committed selection writes the system pasteboard. Exercising
///   it needs a live terminal surface with selectable content plus
///   pasteboard inspection; XCUITest cannot make a Ghostty selection
///   deterministically. Behaviorally tested here only at the
///   Settings-row level (toggle value, fixed subtitle).
///
/// TIER 2 (needs runtime seam): Hibernate After Idle Seconds
///   (`terminal.agentHibernation.idleSeconds`) and Max Live Agent
///   Terminals (`terminal.agentHibernation.maxLiveTerminals`) — these
///   only change *when* an idle background agent terminal is suspended
///   (`AgentHibernationResumeButton` appears in `TerminalPanelView`).
///   Triggering hibernation requires real agent terminals reporting an
///   idle lifecycle for the configured duration and exceeding the live
///   limit; there is no deterministic way to force that in XCUITest
///   without a lifecycle seam. Behaviorally tested here only at the
///   Settings-row level (stepper value labels update).
///
/// ---------------------------------------------------------------------
/// TIER 3 (not e2e-testable in a single session)
/// ---------------------------------------------------------------------
/// TIER 3 (not e2e): Resume Agent Sessions on Reopen
///   (`terminal.autoResumeAgentSessions`) — its only effect is on the
///   NEXT app launch after quit, when restored agent terminals either
///   auto-run their resume command or stay idle. A single in-process
///   XCUITest cannot quit, relaunch, and restore prior agent terminals
///   deterministically. The closest e2e proof would be a relaunch test
///   with pre-seeded restorable agent sessions, which is out of scope
///   here. Behaviorally tested here only at the Settings-row level
///   (toggle value, fixed subtitle).
final class SettingsTerminalBehaviorUITests: SettingsUITestCase {

    /// UserDefaults keys (debug suite) backing the Terminal section.
    private static let terminalKeys = [
        "terminal.showScrollBar",
        "terminal.copyOnSelect",
        "terminal.autoResumeAgentSessions",
        "terminal.agentHibernation.enabled",
        "terminal.agentHibernation.idleSeconds",
        "terminal.agentHibernation.maxLiveTerminals",
        "terminal.showTextBoxOnNewTerminals",
        "terminal.focusTextBoxOnNewTerminals",
        "terminal.textBoxMaxLines",
    ]

    override func setUp() {
        super.setUp()
        resetDefaults(Self.terminalKeys)
    }

    override func tearDown() {
        resetDefaults(Self.terminalKeys)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Opens Settings and navigates to the Terminal section.
    private func openTerminalSettings(_ app: XCUIApplication) -> XCUIElement {
        let window = openSettings(app)
        navigate(window, to: "Terminal")
        return window
    }

    /// Opens Settings and navigates to the TextBox section.
    private func openTextBoxSettings(_ app: XCUIApplication) -> XCUIElement {
        let window = openSettings(app)
        navigate(window, to: "TextBox")
        return window
    }

    /// Returns true once a descendant static text whose value contains
    /// `fragment` exists in `root`.
    private func staticTextContaining(_ root: XCUIElement, _ fragment: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", fragment)
        return root.staticTexts.containing(predicate).firstMatch
    }

    private func waitForStaticText(_ root: XCUIElement, _ fragment: String, timeout: TimeInterval = 4.0) -> Bool {
        let element = staticTextContaining(root, fragment)
        return poll(timeout: timeout) { element.exists }
    }

    // Distinctive substrings of the fixed description sentences. These
    // mirror the localized defaultValue strings in the live Terminal and
    // TextBox sections.
    private enum Subtitle {
        static let scrollBar = "Shows a scroll bar in terminals"
        static let copy = "Selecting text in a terminal copies it to the clipboard"
        static let resume = "Reopening cmux resumes agent sessions automatically"
        static let hibernate = "Hibernates idle background agent terminals"
        static let showTextBox = "Opening a terminal tab, split, or workspace shows the TextBox"
        static let focusTextBox = "Opening a terminal tab, split, or workspace puts keyboard focus in the TextBox"
    }

    // MARK: - TIER 1: toggle value tracks the setting under a fixed subtitle

    /// Show Terminal Scroll Bar defaults ON.
    func testScrollBarToggleKeepsFixedSubtitle() {
        assertToggleFlipsWithFixedSubtitle(
            id: "SettingsTerminalScrollBarToggle", subtitle: Subtitle.scrollBar,
            defaultOn: true, open: openTerminalSettings
        )
    }

    /// Copy on Selection defaults OFF.
    func testCopyOnSelectToggleKeepsFixedSubtitle() {
        assertToggleFlipsWithFixedSubtitle(
            id: "SettingsTerminalCopyOnSelectToggle", subtitle: Subtitle.copy,
            defaultOn: false, open: openTerminalSettings
        )
    }

    /// Resume Agent Sessions defaults ON. (The actual reopen behavior is
    /// TIER 3; see file header.)
    func testAutoResumeToggleKeepsFixedSubtitle() {
        assertToggleFlipsWithFixedSubtitle(
            id: "SettingsTerminalAgentAutoResumeToggle", subtitle: Subtitle.resume,
            defaultOn: true, open: openTerminalSettings
        )
    }

    /// Agent Hibernation defaults OFF. (Actual hibernation is TIER 2; see
    /// file header.)
    func testAgentHibernationToggleKeepsFixedSubtitle() {
        assertToggleFlipsWithFixedSubtitle(
            id: "SettingsTerminalAgentHibernationToggle", subtitle: Subtitle.hibernate,
            defaultOn: false, open: openTerminalSettings
        )
    }

    /// Show TextBox on New Terminals defaults OFF.
    func testShowTextBoxOnNewTerminalsToggleKeepsFixedSubtitle() {
        assertToggleFlipsWithFixedSubtitle(
            id: "SettingsTextBoxShowOnNewTerminalsToggle", subtitle: Subtitle.showTextBox,
            defaultOn: false, open: openTextBoxSettings
        )
    }

    /// Focus TextBox on New Terminals defaults OFF.
    func testFocusTextBoxOnNewTerminalsToggleKeepsFixedSubtitle() {
        assertToggleFlipsWithFixedSubtitle(
            id: "SettingsTextBoxFocusOnNewTerminalsToggle", subtitle: Subtitle.focusTextBox,
            defaultOn: false, open: openTextBoxSettings
        )
    }

    /// Shared driver: the toggle starts at `defaultOn`, flips after one
    /// click, flips back after a second click, and the row shows the same
    /// subtitle in every state.
    private func assertToggleFlipsWithFixedSubtitle(
        id: String,
        subtitle: String,
        defaultOn: Bool,
        open: (XCUIApplication) -> XCUIElement
    ) {
        let app = makeLaunchedApp()
        let window = open(app)

        XCTAssertTrue(
            waitForStaticText(window, subtitle),
            "\(id): subtitle should be shown at the default value"
        )
        let control = toggle(window, id: id)
        XCTAssertEqual(isOn(control), defaultOn, "\(id): toggle should start at its default")

        control.click()
        XCTAssertTrue(
            poll(timeout: 4.0) { self.isOn(control) != defaultOn },
            "\(id): toggle should flip after one click"
        )
        XCTAssertTrue(
            staticTextContaining(window, subtitle).exists,
            "\(id): the same subtitle should be shown after the toggle flips"
        )

        control.click()
        XCTAssertTrue(
            poll(timeout: 4.0) { self.isOn(control) == defaultOn },
            "\(id): toggle should return to its default after a second click"
        )
        XCTAssertTrue(
            staticTextContaining(window, subtitle).exists,
            "\(id): the same subtitle should be shown after the toggle flips back"
        )

        closeSettings(app, window)
    }

    // MARK: - TIER 1: numeric value label tracks the stepper

    /// TextBox Max Lines defaults to 10. Incrementing the stepper must
    /// update the bound numeric value label shown in the row (proving the
    /// value persisted through the settings model), and decrementing must
    /// bring it back down. The numeric label is rendered with a
    /// monospaced digit `Text` next to the stepper, so the new value
    /// surfaces as a queryable static text.
    func testTextBoxMaxLinesStepperUpdatesValueLabel() {
        let app = makeLaunchedApp()
        let window = openTextBoxSettings(app)

        // Default value 10 should be visible somewhere in the section.
        XCTAssertTrue(
            waitForStaticText(window, "10"),
            "TextBox Max Lines should display its default value of 10"
        )

        let stepper = window.steppers["SettingsTextBoxMaxLinesStepper"]
        XCTAssertTrue(poll(timeout: 4.0) { stepper.exists }, "TextBox Max Lines stepper should exist")

        stepper.incrementArrows.firstMatch.click()
        XCTAssertTrue(
            waitForStaticText(window, "11"),
            "Incrementing TextBox Max Lines should display 11"
        )

        stepper.decrementArrows.firstMatch.click()
        XCTAssertTrue(
            waitForStaticText(window, "10"),
            "Decrementing should return the displayed value to 10"
        )

        closeSettings(app, window)
    }

    /// Max Live Agent Terminals defaults to 12; the stepper value label
    /// must track increment/decrement. (When this number actually gates
    /// hibernation is TIER 2 — see file header.)
    func testMaxLiveTerminalsStepperUpdatesValueLabel() {
        let app = makeLaunchedApp()
        let window = openTerminalSettings(app)

        XCTAssertTrue(
            waitForStaticText(window, "12"),
            "Max Live Agent Terminals should display its default value of 12"
        )

        let stepper = window.steppers["SettingsTerminalAgentHibernationMaxLiveStepper"]
        XCTAssertTrue(poll(timeout: 4.0) { stepper.exists }, "Max Live Terminals stepper should exist")

        stepper.incrementArrows.firstMatch.click()
        XCTAssertTrue(
            waitForStaticText(window, "13"),
            "Incrementing Max Live Agent Terminals should display 13"
        )

        stepper.decrementArrows.firstMatch.click()
        XCTAssertTrue(
            waitForStaticText(window, "12"),
            "Decrementing should return the displayed value to 12"
        )

        closeSettings(app, window)
    }

    /// Hibernate After Idle Seconds defaults to 3600 and steps by 60. The
    /// value label must track the stepper. (When idle-seconds actually
    /// drives a suspend is TIER 2 — see file header.)
    func testIdleSecondsStepperUpdatesValueLabel() {
        let app = makeLaunchedApp()
        let window = openTerminalSettings(app)

        XCTAssertTrue(
            waitForStaticText(window, "3600"),
            "Hibernate After Idle Seconds should display its default value of 3600"
        )

        let stepper = window.steppers["SettingsTerminalAgentHibernationIdleSecondsStepper"]
        XCTAssertTrue(poll(timeout: 4.0) { stepper.exists }, "Idle Seconds stepper should exist")

        stepper.incrementArrows.firstMatch.click()
        XCTAssertTrue(
            waitForStaticText(window, "3660"),
            "Incrementing Idle Seconds by one step (60) should display 3660"
        )

        stepper.decrementArrows.firstMatch.click()
        XCTAssertTrue(
            waitForStaticText(window, "3600"),
            "Decrementing should return the displayed value to 3600"
        )

        closeSettings(app, window)
    }
}
