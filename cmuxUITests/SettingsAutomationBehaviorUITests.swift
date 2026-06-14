import XCTest

/// Behavioral UI tests for the Settings **Automation** section.
///
/// The Automation section (`AutomationSection` in `CmuxSettingsUI`) exposes:
/// Socket Control Mode (menu picker), a conditional Socket Password subrow,
/// Claude Code / Cursor / Gemini integration toggles, Claude binary path,
/// Ripgrep binary path, Suppress Subagent Notifications, and Port Base /
/// Port Range Size fields.
///
/// The genuine *runtime* effects of most of these settings (who may connect
/// to the Unix automation socket, whether `claude`/`cursor`/`gemini` get hook
/// env injection, which `rg` binary Find resolves, the `CMUX_PORT` range a new
/// terminal inherits, whether subagent completions notify) all live in
/// backend/CLI/terminal-env code paths that XCUITest cannot observe from the
/// app surface without adding a runtime seam (see TIER 2/3 notes at the bottom
/// of this file). They are intentionally NOT given fake "the toggle flipped"
/// tests here.
///
/// What XCUITest *can* assert behaviorally is the Settings UI's own reactive
/// surface, which is the contract this section actually owns:
///   * choosing **Password mode** reveals a Socket Password subrow that does
///     not exist in the default `cmux processes only` mode, and choosing a
///     non-password mode hides it again;
///   * choosing **Full open access** raises a destructive confirmation dialog,
///     and cancelling it does not show the open-access warning;
///   * each integration toggle drives a live subtitle that flips between its
///     "on" and "off" sentence — an effect bound to the same model the runtime
///     reads, so the subtitle change proves the stored value actually changed.
///
/// Each test resets the backing `UserDefaults` keys so it starts from the
/// documented default value.
final class SettingsAutomationBehaviorUITests: SettingsUITestCase {

    // Raw `userDefaultsKey`s backing the Automation catalog entries
    // (see `AutomationCatalogSection` / `IntegrationsCatalogSection`).
    private static let automationDefaultsKeys = [
        "socketControlMode",
        "claudeCodeHooksEnabled",
        "claudeCodeCustomClaudePath",
        "ripgrepCustomBinaryPath",
        "suppressSubagentNotifications",
        "cursorHooksEnabled",
        "geminiHooksEnabled",
        "cmuxPortBase",
        "cmuxPortRange",
    ]

    // Display strings ported byte-for-byte from
    // `SocketControlMode+Display.swift` and `AutomationSection.swift`.
    private enum L {
        static let modePassword = "Password mode"
        static let modeOpenAccess = "Full open access"
        static let modeCmuxOnly = "cmux processes only"

        static let passwordRowTitle = "Socket Password"
        static let passwordSubtitleUnset = "No password set. External clients will be blocked until one is configured."
        static let passwordSubtitleSet = "Stored in Application Support."
        static let passwordSaved = "Saved."

        static let openAccessDialogTitle = "Enable full open access?"
        static let openAccessDialogConfirm = "Enable Full Open Access"
        static let openAccessDialogCancel = "Cancel"
        static let openAccessWarningPrefix = "Warning: Full open access makes the control socket"

        // Claude Code Integration subtitles.
        static let claudeOn = "Sidebar shows Claude session status and notifications."
        static let claudeOff = "Claude Code runs without cmux integration."

        // Cursor Integration subtitles.
        static let cursorOn = "Sidebar shows Cursor agent status and notifications."
        static let cursorOff = "Cursor runs without cmux integration."

        // Gemini CLI Integration subtitles.
        static let geminiOn = "Sidebar shows Gemini session status and notifications."
        static let geminiOff = "Gemini runs without cmux integration."

        // Suppress Subagent Notifications subtitles.
        static let suppressOn = "Child agent completions stay in Feed without notifications."
        static let suppressOff = "Child agent completions notify like top-level agents."
    }

    override func setUp() {
        super.setUp()
        resetDefaults(Self.automationDefaultsKeys)
    }

    override func tearDown() {
        resetDefaults(Self.automationDefaultsKeys)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Opens Settings, scrolls to the Automation section, and returns the
    /// Settings window.
    private func openAutomation(_ app: XCUIApplication) -> XCUIElement {
        let window = openSettings(app)
        navigate(window, to: "Automation")
        return window
    }

    /// Resolves the Socket Control Mode picker, which a SwiftUI menu-style
    /// `Picker` surfaces as a pop-up button (or, on some macOS versions, a
    /// generic element with the same identifier).
    private func modePicker(_ window: XCUIElement) -> XCUIElement {
        requireElement(
            candidates: [
                window.popUpButtons["AutomationSocketModePicker"],
                window.menuButtons["AutomationSocketModePicker"],
                window.descendants(matching: .any)["AutomationSocketModePicker"],
            ],
            timeout: 4.0,
            description: "socket control mode picker"
        )
    }

    /// Opens the mode picker menu and selects the row whose label matches
    /// `title`. Returns true on success.
    @discardableResult
    private func selectMode(_ window: XCUIElement, _ app: XCUIApplication, _ title: String) -> Bool {
        let picker = modePicker(window)
        picker.click()
        // The menu items can hang off the app, the window, or the picker
        // depending on macOS. Try each surface.
        let candidates = [
            app.menuItems[title],
            window.menuItems[title],
            picker.menuItems[title],
        ]
        let item = poll(timeout: 4.0) { candidates.contains { $0.exists } }
        guard item else { return false }
        for c in candidates where c.exists {
            c.click()
            return true
        }
        return false
    }

    // MARK: - TIER 1: Socket Control Mode reveals/hides the password subrow

    /// Default mode is `cmux processes only`, so the Socket Password row must
    /// be absent. Selecting `Password mode` must reveal it (title + the
    /// "no password set" subtitle), and selecting `cmux processes only`
    /// again must hide it. This is the section's core conditional-UI contract.
    func testPasswordModeRevealsAndHidesSocketPasswordRow() {
        let app = makeLaunchedApp()
        let window = openAutomation(app)
        defer { closeSettings(app, window) }

        let passwordTitle = window.staticTexts[L.passwordRowTitle]

        // Default (cmuxOnly): no password row.
        XCTAssertFalse(
            passwordTitle.waitForExistence(timeout: 1.0),
            "Socket Password row should be hidden in the default cmux-only mode"
        )

        // Switch to Password mode → row appears with the unset subtitle.
        XCTAssertTrue(selectMode(window, app, L.modePassword), "could not select Password mode")
        XCTAssertTrue(
            poll(timeout: 4.0) { passwordTitle.exists },
            "Socket Password row should appear after choosing Password mode"
        )
        XCTAssertTrue(
            poll(timeout: 2.0) { window.staticTexts[L.passwordSubtitleUnset].exists },
            "Password row should show the unset-password subtitle when no password is configured"
        )

        // Switch back to cmux-only → row disappears again.
        XCTAssertTrue(selectMode(window, app, L.modeCmuxOnly), "could not select cmux-only mode")
        XCTAssertTrue(
            poll(timeout: 4.0) { !passwordTitle.exists },
            "Socket Password row should disappear after leaving Password mode"
        )
    }

    // MARK: - TIER 1: Setting a socket password updates the row state

    /// In Password mode, typing a password and pressing Set must surface the
    /// "Saved." status and flip the row subtitle from the unset sentence to
    /// the "Stored in Application Support." sentence. Both observable changes
    /// are driven by the same `socketPasswordModel` the runtime reads, so the
    /// subtitle change proves the value was actually stored.
    func testSettingSocketPasswordShowsSavedStateAndStoredSubtitle() {
        let app = makeLaunchedApp()
        let window = openAutomation(app)
        defer { closeSettings(app, window) }

        XCTAssertTrue(selectMode(window, app, L.modePassword), "could not select Password mode")
        XCTAssertTrue(
            poll(timeout: 4.0) { window.staticTexts[L.passwordRowTitle].exists },
            "Password row should appear after choosing Password mode"
        )

        // The SecureField has no accessibility id; resolve the only secure
        // text field inside the Settings window.
        let field = requireElement(
            candidates: [window.secureTextFields.firstMatch],
            timeout: 4.0,
            description: "socket password secure field"
        )
        field.click()
        field.typeText("hunter2")

        // The Set button is enabled once the draft is non-empty.
        let setButton = requireElement(
            candidates: [window.buttons["Set"], window.buttons["Change"]],
            timeout: 4.0,
            description: "Set socket password button"
        )
        setButton.click()

        XCTAssertTrue(
            poll(timeout: 4.0) { window.staticTexts[L.passwordSaved].exists },
            "A 'Saved.' status should appear after setting the password"
        )
        XCTAssertTrue(
            poll(timeout: 2.0) { window.staticTexts[L.passwordSubtitleSet].exists },
            "Row subtitle should switch to the 'Stored in Application Support.' sentence once a password is set"
        )
    }

    // MARK: - TIER 1: Full open access raises a confirmation dialog

    /// Choosing `Full open access` must raise the destructive confirmation
    /// dialog before applying the mode. Cancelling must NOT show the
    /// open-access warning (the mode change is gated on confirmation). This
    /// verifies the safety gate, the most important behavior of this control.
    func testFullOpenAccessRaisesConfirmationDialogAndCancelLeavesWarningHidden() {
        let app = makeLaunchedApp()
        let window = openAutomation(app)
        defer { closeSettings(app, window) }

        // The open-access warning must not be present before confirmation.
        XCTAssertFalse(
            window.staticTexts.containing(
                NSPredicate(format: "label BEGINSWITH %@", L.openAccessWarningPrefix)
            ).firstMatch.waitForExistence(timeout: 1.0),
            "Open-access warning should be hidden in the default mode"
        )

        XCTAssertTrue(selectMode(window, app, L.modeOpenAccess), "could not select Full open access")

        // Confirmation dialog appears.
        let confirmButton = requireElement(
            candidates: [
                app.buttons[L.openAccessDialogConfirm],
                window.buttons[L.openAccessDialogConfirm],
                app.sheets.buttons[L.openAccessDialogConfirm],
            ],
            timeout: 4.0,
            description: "open-access confirmation dialog confirm button"
        )
        XCTAssertTrue(confirmButton.exists, "Full open access should raise a confirmation dialog")

        // Cancel and assert the warning never appears (mode stayed gated).
        let cancelButton = requireElement(
            candidates: [
                app.buttons[L.openAccessDialogCancel],
                window.buttons[L.openAccessDialogCancel],
                app.sheets.buttons[L.openAccessDialogCancel],
            ],
            timeout: 4.0,
            description: "open-access confirmation dialog cancel button"
        )
        cancelButton.click()

        let warning = window.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH %@", L.openAccessWarningPrefix)
        ).firstMatch
        XCTAssertFalse(
            warning.waitForExistence(timeout: 1.5),
            "Cancelling the dialog must not apply Full open access, so the warning must stay hidden"
        )
    }

    // MARK: - TIER 1: Confirming full open access shows the warning

    /// Confirming the dialog applies `allowAll` and the open-access warning
    /// text must then render, proving the mode change took effect in the UI.
    func testConfirmingFullOpenAccessShowsWarning() {
        let app = makeLaunchedApp()
        let window = openAutomation(app)
        defer { closeSettings(app, window) }

        XCTAssertTrue(selectMode(window, app, L.modeOpenAccess), "could not select Full open access")

        let confirmButton = requireElement(
            candidates: [
                app.buttons[L.openAccessDialogConfirm],
                window.buttons[L.openAccessDialogConfirm],
                app.sheets.buttons[L.openAccessDialogConfirm],
            ],
            timeout: 4.0,
            description: "open-access confirmation dialog confirm button"
        )
        confirmButton.click()

        let warning = window.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH %@", L.openAccessWarningPrefix)
        ).firstMatch
        XCTAssertTrue(
            poll(timeout: 4.0) { warning.exists },
            "Confirming Full open access should render the open-access warning"
        )
    }

    // MARK: - TIER 1: Integration toggle subtitles reflect the stored value

    /// Each integration toggle drives a live subtitle bound to the same model
    /// the runtime reads. Flipping the toggle must swap the subtitle between
    /// its on/off sentence; the subtitle change is the observable proof the
    /// stored value flipped (the runtime hook-injection effect itself is
    /// TIER 2 — see notes below).
    func testClaudeCodeToggleFlipsSubtitle() {
        assertToggleFlipsSubtitle(
            id: "SettingsClaudeCodeHooksToggle",
            offSubtitle: L.claudeOff,
            onSubtitle: L.claudeOn
        )
    }

    func testCursorToggleFlipsSubtitle() {
        assertToggleFlipsSubtitle(
            id: "SettingsCursorHooksToggle",
            offSubtitle: L.cursorOff,
            onSubtitle: L.cursorOn
        )
    }

    func testGeminiToggleFlipsSubtitle() {
        assertToggleFlipsSubtitle(
            id: "SettingsGeminiHooksToggle",
            offSubtitle: L.geminiOff,
            onSubtitle: L.geminiOn
        )
    }

    func testSuppressSubagentToggleFlipsSubtitle() {
        assertToggleFlipsSubtitle(
            id: "SettingsSuppressSubagentNotificationsToggle",
            offSubtitle: L.suppressOff,
            onSubtitle: L.suppressOn
        )
    }

    /// Shared driver: defaults are all `false`, so the "off" subtitle must be
    /// present initially; clicking the toggle must replace it with the "on"
    /// subtitle.
    private func assertToggleFlipsSubtitle(id: String, offSubtitle: String, onSubtitle: String) {
        let app = makeLaunchedApp()
        let window = openAutomation(app)
        defer { closeSettings(app, window) }

        XCTAssertTrue(
            poll(timeout: 4.0) { window.staticTexts[offSubtitle].exists },
            "\(id): off-state subtitle should be shown at the default (disabled) value"
        )
        XCTAssertFalse(
            window.staticTexts[onSubtitle].exists,
            "\(id): on-state subtitle should not be shown before toggling"
        )

        let control = toggle(window, id: id)
        control.click()

        XCTAssertTrue(
            poll(timeout: 4.0) { window.staticTexts[onSubtitle].exists },
            "\(id): on-state subtitle should appear after enabling the toggle"
        )
        XCTAssertTrue(
            poll(timeout: 2.0) { !window.staticTexts[offSubtitle].exists },
            "\(id): off-state subtitle should be gone after enabling the toggle"
        )
    }

    // MARK: - TIER 2 (needs runtime seam): not e2e-testable from the app surface
    //
    // The settings below store a value the UI faithfully round-trips, but
    // their *behavior* is enacted entirely in backend/CLI/terminal-env code
    // that XCUITest cannot observe without adding a runtime seam. Per the
    // task's no-seam rule, they are documented here rather than given fake
    // "the control changed" assertions.
    //
    // TIER 2 (needs runtime seam): Socket Control Mode (cmuxOnly/automation/
    //   password/allowAll/off) — the mode's real effect is which clients the
    //   Unix automation socket accepts (ancestry check, password check,
    //   world access). That gate is enforced inside the socket-server
    //   connection handler (consumed in AppDelegate/cmuxApp socket setup), not
    //   in any AX-visible app element. The conditional-UI consequences
    //   (password subrow, open-access dialog/warning) ARE covered above as
    //   TIER 1; the access-control enforcement needs a socket-level harness.
    //
    // TIER 2 (needs runtime seam): Socket Password — stored to Application
    //   Support and read by the socket auth path. The UI "Saved." / subtitle
    //   transition is covered TIER 1; whether a client presenting that
    //   password is admitted is only observable through the socket server.
    //
    // TIER 2 (needs runtime seam): Claude Code / Cursor / Gemini integration
    //   toggles — when enabled, cmux injects session-tracking + notification
    //   hook env into newly launched `claude`/`cursor`/`gemini` processes
    //   inside cmux terminals. The observable consequence (sidebar session
    //   status rows / completion notifications) only appears when a real agent
    //   process runs with the injected hooks; there is no AX element that
    //   changes purely from the toggle. The toggle's *stored* value is proven
    //   TIER 1 via the live subtitle; the env-injection behavior needs a
    //   terminal-launch + hook harness.
    //
    // TIER 2 (needs runtime seam): Suppress Subagent Notifications — affects
    //   whether child-agent completions raise a notification vs. only landing
    //   in Feed, decided by process-ancestry logic in the notification path.
    //   Observable only with a real nested-agent completion event. Stored
    //   value proven TIER 1 via the subtitle.
    //
    // TIER 2 (needs runtime seam): Claude Binary Path / Ripgrep Binary Path —
    //   these select which `claude` / `rg` executable cmux resolves
    //   (FileExplorerSearchController for ripgrep, agent launch for claude).
    //   The effect is which on-disk binary runs; there is no app-surface
    //   element reflecting the resolved path. The text fields have no
    //   accessibility identifier and no observable consequence to assert
    //   without a process-launch seam.
    //
    // TIER 2 (needs runtime seam): Port Base / Port Range Size — set the
    //   CMUX_PORT / CMUX_PORT_END environment range a new terminal inherits.
    //   The only true verification is reading the env of a freshly spawned
    //   terminal (e.g. `echo $CMUX_PORT`), which requires driving the Ghostty
    //   terminal surface and scraping its text buffer — not reachable through
    //   XCUITest accessibility without a terminal-content seam. The fields
    //   also carry no accessibility identifier.
}
