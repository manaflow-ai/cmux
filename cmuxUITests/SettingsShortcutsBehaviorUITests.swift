import XCTest

/// Behavioral UI tests for the Settings **Global Hotkey** and
/// **Keyboard Shortcuts** sections.
///
/// The two sections share one model: both read and write
/// `shortcuts.bindings` in cmux.json (the JSON config store), and the
/// Global Hotkey section additionally owns the `systemWideHotkey.enabled`
/// UserDefaults flag. The controls in scope are:
///
/// Global Hotkey section:
/// - `SettingsGlobalHotkeyToggle` — enable the system-wide hotkey.
/// - `SettingsGlobalHotkeyRecorder` — record the global chord.
/// - `ShortcutRecorderClearRestoreButton` — clear / restore the global chord.
/// - `SettingsGlobalHotkeyNote` — static permissions note.
///
/// Keyboard Shortcuts section:
/// - `SettingsKeyboardShortcutsChordDocsLink` — external chord docs URL.
/// - `SettingsKeyboardShortcutsOpenSettingsFileButton` — open cmux.json.
/// - `SettingsKeyboardShortcutsResetDefaultsButton` — reset all bindings.
/// - per-action `ShortcutRecorderView` + `ShortcutRecorderClearRestoreButton`.
/// - `ShortcutRecorderValidationMessage` — conflict / bare-key banner.
/// - `ShortcutRecordingHint` — static hint text.
///
/// The tests below drive only the effects that are observable through
/// XCUITest from the Settings window surface. The actual runtime effect
/// of binding a hotkey (the OS-level global hotkey registration in
/// `SystemWideHotkeyController`) is not observable here and is documented
/// in the tier-2/tier-3 blocks at the bottom of the file.
final class SettingsShortcutsBehaviorUITests: SettingsUITestCase {

    // The system-wide hotkey enable flag is a real UserDefaults key
    // (`AppCatalogSection.systemWideHotkeyEnabled.userDefaultsKey`).
    // Reset it so the toggle starts from its `false` default.
    private let hotkeyEnabledKey = "systemWideHotkey.enabled"

    // Resting display labels rendered by both sections' recorder /
    // clear-restore controls. These mirror the localized default values
    // in GlobalHotkeySection / KeyboardShortcutsSection.
    private let unboundLabel = "None"           // shortcut.unbound.displayValue
    private let unbindAXLabel = "Unbind"        // shortcut.recorder.clear
    private let restoreAXLabel = "Restore"      // shortcut.recorder.restore

    // The Global Hotkey default chord is `ShortcutStroke(key: ".",
    // command: true, option: true, control: true)` → formatted "⌃⌥⌘."
    // by GlobalHotkeySection.format(_:). The clear button starts as
    // "Unbind" because the default binding is non-unbound.
    private let globalHotkeyDefaultDisplay = "⌃⌥⌘."

    override func setUp() {
        super.setUp()
        resetDefaults([hotkeyEnabledKey])
    }

    override func tearDown() {
        resetDefaults([hotkeyEnabledKey])
        super.tearDown()
    }

    // MARK: - Tier 1: Enable toggle drives the card subtitle copy

    /// TIER 1 — `SettingsGlobalHotkeyToggle`.
    ///
    /// The OS-level hotkey registration is not observable via XCUITest,
    /// but the enable row's *subtitle* is derived from `enabled.current`
    /// inside the same Settings card:
    ///   - off: "Turn this on to show or hide all cmux windows from any app."
    ///   - on:  "Press the shortcut from any app to show or hide all cmux windows."
    /// Flipping the toggle must swap the rendered subtitle. We assert the
    /// effect (the visible subtitle copy), not merely that the switch flipped.
    func testEnableToggleSwapsSubtitleCopy() {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }
        navigate(window, to: "Global Hotkey")

        let offSubtitle = "Turn this on to show or hide all cmux windows from any app."
        let onSubtitle = "Press the shortcut from any app to show or hide all cmux windows."

        // Default is disabled → off subtitle present, on subtitle absent.
        XCTAssertTrue(
            poll(timeout: 5.0) { window.staticTexts[offSubtitle].exists },
            "Disabled hotkey row should show the off subtitle"
        )

        let toggle = toggle(window, id: "SettingsGlobalHotkeyToggle")
        toggle.click()

        // After enabling, the subtitle copy must change to the on variant.
        XCTAssertTrue(
            poll(timeout: 5.0) { window.staticTexts[onSubtitle].exists },
            "Enabling the hotkey should swap the row subtitle to the on variant"
        )
        XCTAssertFalse(
            window.staticTexts[offSubtitle].exists,
            "Off subtitle should disappear once the hotkey is enabled"
        )

        // Disabling restores the off subtitle.
        toggle.click()
        XCTAssertTrue(
            poll(timeout: 5.0) { window.staticTexts[offSubtitle].exists },
            "Disabling the hotkey should restore the off subtitle"
        )
    }

    // MARK: - Tier 1: Global hotkey clear / restore button

    /// TIER 1 — `ShortcutRecorderClearRestoreButton` (Global Hotkey).
    ///
    /// The clear/restore button is fully button-driven (no keystroke
    /// capture needed), so its effect is reliably observable:
    ///   - At the default binding the button's accessibility label is
    ///     "Unbind" and the recorder shows the default chord "⌃⌥⌘.".
    ///   - Clicking it unbinds: recorder shows "None" and the button's
    ///     accessibility label flips to "Restore".
    ///   - Clicking again restores the previous chord: recorder shows
    ///     "⌃⌥⌘." again and the button label flips back to "Unbind".
    ///
    /// This round-trips the `shortcuts.bindings` JSON store back to its
    /// starting state, so the test leaves cmux.json clean.
    func testGlobalHotkeyClearThenRestoreRoundTrips() {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }
        navigate(window, to: "Global Hotkey")

        // The Global Hotkey section contains exactly one clear/restore
        // button; scope the lookup to that section's recorder area by
        // taking the button that lives in this section's card.
        let clearRestore = requireElement(
            candidates: [
                window.buttons["ShortcutRecorderClearRestoreButton"],
                window.descendants(matching: .button)["ShortcutRecorderClearRestoreButton"],
            ],
            timeout: 5.0,
            description: "global hotkey clear/restore button"
        )

        // Default binding is non-unbound → button offers "Unbind".
        XCTAssertTrue(
            poll(timeout: 5.0) { clearRestore.label == unbindAXLabel },
            "At the default binding the button should be labeled Unbind, was \(clearRestore.label)"
        )

        // Recorder should display the default chord at rest.
        let recorder = window.descendants(matching: .any)["SettingsGlobalHotkeyRecorder"]
        if recorder.exists {
            XCTAssertTrue(
                poll(timeout: 3.0) { recorderShows(recorder, globalHotkeyDefaultDisplay) },
                "Recorder should show the default chord \(globalHotkeyDefaultDisplay)"
            )
        }

        // Clear: button flips to "Restore", recorder shows "None".
        clearRestore.click()
        XCTAssertTrue(
            poll(timeout: 5.0) { clearRestore.label == restoreAXLabel },
            "After clearing, the button should flip to Restore, was \(clearRestore.label)"
        )
        if recorder.exists {
            XCTAssertTrue(
                poll(timeout: 3.0) { recorderShows(recorder, unboundLabel) },
                "After clearing, the recorder should show the unbound label \(unboundLabel)"
            )
        }

        // Restore: button flips back to "Unbind", recorder shows the chord.
        clearRestore.click()
        XCTAssertTrue(
            poll(timeout: 5.0) { clearRestore.label == unbindAXLabel },
            "After restoring, the button should flip back to Unbind, was \(clearRestore.label)"
        )
        if recorder.exists {
            XCTAssertTrue(
                poll(timeout: 3.0) { recorderShows(recorder, globalHotkeyDefaultDisplay) },
                "After restoring, the recorder should show \(globalHotkeyDefaultDisplay) again"
            )
        }
    }

    // MARK: - Tier 1: Reset Defaults re-binds a cleared action

    /// TIER 1 — `SettingsKeyboardShortcutsResetDefaultsButton`.
    ///
    /// Reset Defaults writes an empty `shortcuts.bindings` map, so every
    /// per-action recorder returns to its default stroke and the row's
    /// clear/restore button reverts to "Unbind". We make the effect
    /// observable by first clearing the first per-action shortcut (its
    /// row button flips to "Restore"), then pressing Reset Defaults and
    /// asserting that row's button flips back to "Unbind" — proving the
    /// reset actually re-applied the default binding rather than just
    /// flipping a control.
    ///
    /// The button-row state is the observable proxy for the binding
    /// reset; the per-row clear/restore label is driven directly off the
    /// effective binding (`canRestore = isUnbound && restore != nil`).
    func testResetDefaultsRebindsClearedAction() {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }
        navigate(window, to: "Keyboard Shortcuts")

        // There are many clear/restore buttons in this section (one per
        // action row). Use the first one as the subject. It starts as
        // "Unbind" for any action whose default stroke is non-unbound.
        let rowButtons = window.buttons.matching(identifier: "ShortcutRecorderClearRestoreButton")
        XCTAssertTrue(
            poll(timeout: 6.0) { rowButtons.count > 0 },
            "Keyboard Shortcuts section should render per-action clear/restore buttons"
        )

        // Find a row button currently labeled "Unbind" (a bound action).
        let subject = firstButton(in: rowButtons, withLabel: unbindAXLabel, timeout: 6.0)
        XCTAssertNotNil(subject, "Expected at least one bound per-action shortcut to clear")
        guard let subject else { return }

        // Clear it → flips to "Restore".
        subject.click()
        XCTAssertTrue(
            poll(timeout: 5.0) { subject.label == restoreAXLabel },
            "After clearing the action, its button should read Restore, was \(subject.label)"
        )

        // Reset Defaults → cleared action returns to its default binding,
        // so the row button reverts to "Unbind".
        let resetButton = requireElement(
            candidates: [
                window.buttons["SettingsKeyboardShortcutsResetDefaultsButton"],
                window.descendants(matching: .button)["SettingsKeyboardShortcutsResetDefaultsButton"],
            ],
            timeout: 5.0,
            description: "Reset Defaults button"
        )
        resetButton.click()

        XCTAssertTrue(
            poll(timeout: 6.0) { subject.label == unbindAXLabel },
            "Reset Defaults should re-bind the cleared action so its button reads Unbind again, was \(subject.label)"
        )
    }

    // MARK: - Helpers

    /// Returns true when the recorder element's label or value contains
    /// `text`. The recorder is an AppKit `NSButton` hosted via
    /// `NSViewRepresentable`; depending on the accessibility bridge its
    /// title surfaces as either the element label or its value, so we
    /// check both.
    private func recorderShows(_ recorder: XCUIElement, _ text: String) -> Bool {
        if recorder.label.contains(text) { return true }
        if let value = recorder.value as? String, value.contains(text) { return true }
        // Fall back to a descendant button carrying the title.
        return recorder.buttons.element(boundBy: 0).exists
            && (recorder.buttons.element(boundBy: 0).label.contains(text))
    }

    /// Returns the first button in `query` whose accessibility label
    /// equals `label`, polling until one exists or the timeout elapses.
    private func firstButton(
        in query: XCUIElementQuery,
        withLabel label: String,
        timeout: TimeInterval
    ) -> XCUIElement? {
        var result: XCUIElement?
        _ = poll(timeout: timeout) {
            let count = query.count
            for index in 0..<count {
                let candidate = query.element(boundBy: index)
                if candidate.exists, candidate.label == label {
                    result = candidate
                    return true
                }
            }
            return false
        }
        return result
    }
}

// MARK: - Tier 2 (needs runtime seam)

// TIER 2 (needs runtime seam): SettingsGlobalHotkeyRecorder /
//   per-action ShortcutRecorderView keystroke recording — Recording a NEW
//   shortcut requires the AppKit RecorderHostButton to become first
//   responder and capture a raw NSEvent keyDown carrying modifier flags
//   through its local NSEvent monitor. XCUITest's typeKey/typeText does
//   not reliably drive that focused-NSButton + local-monitor capture path
//   (the synthesized events are not guaranteed to reach the recorder's
//   monitor with the expected modifierFlags), so we cannot deterministically
//   assert "press ⌘J → binding becomes ⌘J" e2e. A testable seam would be a
//   debug/UI-test hook that injects a ShortcutStroke directly into the
//   recorder's onStroke/onChord callback, bypassing NSEvent synthesis.
//   We verify the surrounding bind/clear/restore lifecycle behaviorally
//   instead (clear/restore round-trip + reset), which exercises the same
//   shortcuts.bindings write path without depending on synthetic keystrokes.

// TIER 2 (needs runtime seam): ShortcutRecorderValidationMessage
//   (conflict / bare-key rejection banner) — The red validation banner is
//   only driven by conflictRejections / bareKeyRejections, which are set
//   from inside the recorder's keyDown handler (onBareKeyRejected, and the
//   detectConflict path in assign/assignChord). Surfacing the banner
//   therefore requires the same unreliable synthetic-keystroke capture as
//   recording itself. Without a stroke-injection seam there is no
//   deterministic e2e path to a rejected attempt, so the banner's
//   appearance/Undo dismissal cannot be asserted without flakiness.

// TIER 2 (needs runtime seam): SystemWideHotkeyController registration
//   (the real effect of SettingsGlobalHotkeyToggle + the global chord) —
//   Enabling the toggle and binding a chord causes SystemWideHotkeyController
//   to register an OS-level global hotkey (Carbon/AppKit event tap) so the
//   chord shows/hides all cmux windows from any app. That registration and
//   its show/hide behavior live below the XCUITest-observable surface: there
//   is no in-app accessibility element that reflects "the global hotkey is
//   registered", and exercising it would require sending a system-wide
//   keystroke from outside the app under test. A runtime seam exposing the
//   controller's registered state (or a debug command reporting it) would be
//   needed to verify the actual hotkey effect. We assert the observable
//   Settings-side proxy (the enable row subtitle copy) instead.

// MARK: - Tier 3 (not e2e)

// TIER 3 (not e2e): SettingsKeyboardShortcutsOpenSettingsFileButton
//   ("Open cmux.json") — Calls SettingsHostActions.openConfigInExternalEditor(),
//   which runs NSWorkspace.shared.open(configFileURL) to hand the cmux.json
//   file to the user's external editor. The effect is a separate application
//   launching/foregrounding outside the app under test, with no element in
//   the cmux UI surface to assert against. Not e2e-testable from XCUITest;
//   the host action itself can be unit-tested against a fake SettingsHostActions.

// TIER 3 (not e2e): SettingsKeyboardShortcutsChordDocsLink ("Chord docs") —
//   A SwiftUI Link to https://cmux.com/docs/keyboard-shortcuts#shortcut-chords.
//   Clicking it opens the default web browser to an external URL; there is no
//   in-app observable effect, so it is not e2e-testable. The destination URL
//   correctness is better covered by a unit assertion on the section, not a UI test.

// TIER 3 (not e2e): SettingsGlobalHotkeyNote / ShortcutRecordingHint —
//   Static informational text only. They render fixed copy and have no
//   runtime behavior to drive or assert beyond their own presence, so there
//   is no meaningful behavioral test (a presence check would be a source-shape
//   assertion, which the test-quality policy forbids).
