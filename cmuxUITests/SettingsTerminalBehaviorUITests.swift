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
/// itself: six of the rows render a description (`subtitle`) whose text
/// is bound to the live setting value and flips between an "on" and
/// "off" sentence when the control changes, and the three numeric rows
/// render a value label that updates when the stepper is driven.
///
/// These tests assert that observable EFFECT (the bound description /
/// value re-renders to match the changed setting), not merely that the
/// control reports a new toggle state. The toggle-state assertion alone
/// would not prove the setting propagated; the bound subtitle/value
/// re-render does, because it reads back through the same persisted
/// settings model the rest of the app consumes.
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
///   (subtitle flips on/off).
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
///   Settings-row level (subtitle flips on/off).
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
///   (subtitle flips on/off).
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
        navigate(window, to: "TextBox (Beta)")
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

    // Distinctive substrings of the on/off description sentences. These
    // mirror the localized defaultValue strings in the live Terminal
    // section and are stable enough to disambiguate the two states.
    private enum Subtitle {
        static let scrollBarOn = "Shows the right-edge terminal scroll bar"
        static let scrollBarOff = "Hides the right-edge terminal scroll bar"
        static let copyOn = "Selected terminal text is also copied to the system clipboard"
        static let copyOff = "cmux does not add system-clipboard copy on selection"
        static let resumeOn = "automatically run their resume command"
        static let resumeOff = "stay idle until you resume them manually"
        static let hibernateOn = "Idle background agent terminals can be suspended"
        static let hibernateOff = "Agent terminals stay live until you close them"
        static let showTextBoxOn = "open with the TextBox visible"
        static let showTextBoxOff = "start with the TextBox hidden"
        static let focusTextBoxOn = "put keyboard focus in the TextBox"
        static let focusTextBoxOff = "keep keyboard focus in the terminal surface"
    }

    // MARK: - TIER 1: bound description flips with the setting

    /// Show Terminal Scroll Bar defaults ON, so the description starts in
    /// its "on" sentence; toggling the control flips the bound subtitle
    /// to the "off" sentence and back. This proves the toggle change
    /// propagates through the live settings model that drives the row's
    /// description, not just the control's reported value.
    func testScrollBarToggleFlipsBoundDescription() {
        let app = makeLaunchedApp()
        let window = openTerminalSettings(app)

        XCTAssertTrue(
            waitForStaticText(window, Subtitle.scrollBarOn),
            "Scroll bar row should start with the on-state description (default true)"
        )

        let control = toggle(window, id: "SettingsTerminalScrollBarToggle")
        control.click()
        XCTAssertTrue(
            waitForStaticText(window, Subtitle.scrollBarOff),
            "After turning the scroll bar off the description should switch to the off sentence"
        )

        control.click()
        XCTAssertTrue(
            waitForStaticText(window, Subtitle.scrollBarOn),
            "Turning the scroll bar back on should restore the on sentence"
        )

        closeSettings(app, window)
    }

    /// Copy on Selection defaults OFF; toggling on switches the bound
    /// description to the clipboard-copy sentence and back.
    func testCopyOnSelectToggleFlipsBoundDescription() {
        let app = makeLaunchedApp()
        let window = openTerminalSettings(app)

        XCTAssertTrue(
            waitForStaticText(window, Subtitle.copyOff),
            "Copy-on-select row should start with the off-state description (default false)"
        )

        let control = toggle(window, id: "SettingsTerminalCopyOnSelectToggle")
        control.click()
        XCTAssertTrue(
            waitForStaticText(window, Subtitle.copyOn),
            "Enabling copy-on-select should switch the description to the clipboard-copy sentence"
        )

        control.click()
        XCTAssertTrue(
            waitForStaticText(window, Subtitle.copyOff),
            "Disabling copy-on-select should restore the off sentence"
        )

        closeSettings(app, window)
    }

    /// Resume Agent Sessions defaults ON; toggling flips the bound
    /// description between the auto-resume and stay-idle sentences. (The
    /// actual reopen behavior is TIER 3 — see file header.)
    func testAutoResumeToggleFlipsBoundDescription() {
        let app = makeLaunchedApp()
        let window = openTerminalSettings(app)

        XCTAssertTrue(
            waitForStaticText(window, Subtitle.resumeOn),
            "Auto-resume row should start with the on-state description (default true)"
        )

        let control = toggle(window, id: "SettingsTerminalAgentAutoResumeToggle")
        control.click()
        XCTAssertTrue(
            waitForStaticText(window, Subtitle.resumeOff),
            "Disabling auto-resume should switch the description to the stay-idle sentence"
        )

        control.click()
        XCTAssertTrue(
            waitForStaticText(window, Subtitle.resumeOn),
            "Re-enabling auto-resume should restore the auto-run sentence"
        )

        closeSettings(app, window)
    }

    /// Agent Hibernation defaults OFF; toggling on switches the bound
    /// description to the suspend sentence and back. (Actual hibernation
    /// is TIER 2 — see file header.)
    func testAgentHibernationToggleFlipsBoundDescription() {
        let app = makeLaunchedApp()
        let window = openTerminalSettings(app)

        XCTAssertTrue(
            waitForStaticText(window, Subtitle.hibernateOff),
            "Hibernation row should start with the off-state description (default false)"
        )

        let control = toggle(window, id: "SettingsTerminalAgentHibernationToggle")
        control.click()
        XCTAssertTrue(
            waitForStaticText(window, Subtitle.hibernateOn),
            "Enabling hibernation should switch the description to the suspend sentence"
        )

        control.click()
        XCTAssertTrue(
            waitForStaticText(window, Subtitle.hibernateOff),
            "Disabling hibernation should restore the stay-live sentence"
        )

        closeSettings(app, window)
    }

    /// Show TextBox on New Terminals defaults OFF; toggling on switches
    /// the bound description to the visible-on-new-terminals sentence and back.
    func testShowTextBoxOnNewTerminalsToggleFlipsBoundDescription() {
        let app = makeLaunchedApp()
        let window = openTextBoxSettings(app)

        XCTAssertTrue(
            waitForStaticText(window, Subtitle.showTextBoxOff),
            "Show TextBox row should start with the off-state description (default false)"
        )

        let control = toggle(window, id: "SettingsTextBoxShowOnNewTerminalsToggle")
        control.click()
        XCTAssertTrue(
            waitForStaticText(window, Subtitle.showTextBoxOn),
            "Enabling show TextBox should switch the description to the visible sentence"
        )

        control.click()
        XCTAssertTrue(
            waitForStaticText(window, Subtitle.showTextBoxOff),
            "Disabling show TextBox should restore the hidden sentence"
        )

        closeSettings(app, window)
    }

    /// Focus TextBox on New Terminals defaults OFF; toggling on switches
    /// the bound description to the focus-TextBox sentence and back.
    func testFocusTextBoxOnNewTerminalsToggleFlipsBoundDescription() {
        let app = makeLaunchedApp()
        let window = openTextBoxSettings(app)

        XCTAssertTrue(
            waitForStaticText(window, Subtitle.focusTextBoxOff),
            "Focus TextBox row should start with the off-state description (default false)"
        )

        let control = toggle(window, id: "SettingsTextBoxFocusOnNewTerminalsToggle")
        control.click()
        XCTAssertTrue(
            waitForStaticText(window, Subtitle.focusTextBoxOn),
            "Enabling focus TextBox should switch the description to the focus sentence"
        )

        control.click()
        XCTAssertTrue(
            waitForStaticText(window, Subtitle.focusTextBoxOff),
            "Disabling focus TextBox should restore the terminal-focus sentence"
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
