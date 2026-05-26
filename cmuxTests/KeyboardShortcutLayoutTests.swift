import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Regression coverage for issue #3362 ("Alternative keyboard layouts not
// considered for hotkeys"). The original symptom on a Swedish ISO layout was:
// pressing ⌘+"+" (which sits at the US "-" physical position, keyCode 27)
// fired the .browserZoomOut shortcut instead of .browserZoomIn, because the
// matcher fell back to US-layout keycodes whenever a command symbol shortcut
// failed character-based matching.
final class KeyboardShortcutLayoutTests: XCTestCase {

    private static func swedishLayoutCharacter(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> String? {
        // Subset of the Swedish ISO Mac layout sufficient for these tests.
        // keyCode 27 = US "-" position; on Swedish it produces "+" unshifted
        // and "?" with shift.
        let shifted = modifierFlags.contains(.shift)
        switch keyCode {
        case 24: return shifted ? "`" : "´"        // US "="
        case 27: return shifted ? "?" : "+"        // US "-"
        case 29: return shifted ? "=" : "0"        // US "0"
        case 13: return shifted ? "W" : "w"        // US "w"
        default: return nil
        }
    }

    private static func russianLayoutCharacter(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> String? {
        // Russian PC layout — non-Latin characters at every position.
        switch keyCode {
        case 13: return modifierFlags.contains(.shift) ? "Ц" : "ц"   // US "w"
        case 27: return modifierFlags.contains(.shift) ? "_" : "-"   // US "-"
        case 24: return modifierFlags.contains(.shift) ? "+" : "="   // US "="
        default: return nil
        }
    }

    // MARK: - Issue #3362: Swedish ⌘+ should zoom in, not zoom out

    func testSwedishCommandPlusMatchesBrowserZoomIn() {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .browserZoomIn).firstStroke
        XCTAssertTrue(
            shortcut.matches(
                keyCode: 27,              // physical position of US "-"
                modifierFlags: [.command],
                eventCharacter: "+",      // Swedish layout produces "+" at this key without shift
                layoutCharacterProvider: Self.swedishLayoutCharacter
            ),
            "Swedish ⌘+ should match browserZoomIn (=), not be rejected"
        )
    }

    func testSwedishCommandPlusDoesNotMatchBrowserZoomOut() {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .browserZoomOut).firstStroke
        XCTAssertFalse(
            shortcut.matches(
                keyCode: 27,
                modifierFlags: [.command],
                eventCharacter: "+",
                layoutCharacterProvider: Self.swedishLayoutCharacter
            ),
            "Swedish ⌘+ must NOT match browserZoomOut (-) via US-layout keycode fallback"
        )
    }

    func testSwedishCommandUnderscoreMatchesBrowserZoomOut() {
        // Shift+"+" on Swedish produces "?", not "_". "_" on Swedish ISO requires
        // shift+"-" key. This still exercises the unconditional "_" → "-" mapping.
        let shortcut = KeyboardShortcutSettings.shortcut(for: .browserZoomOut).firstStroke
        XCTAssertTrue(
            shortcut.matches(
                keyCode: 27,
                modifierFlags: [.command],
                eventCharacter: "_",
                layoutCharacterProvider: { _, _ in "_" }
            )
        )
    }

    // MARK: - US-layout baseline still works

    func testUSCommandEqualsMatchesBrowserZoomIn() {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .browserZoomIn).firstStroke
        XCTAssertTrue(
            shortcut.matches(
                keyCode: 24,
                modifierFlags: [.command],
                eventCharacter: "=",
                layoutCharacterProvider: { _, _ in "=" }
            )
        )
    }

    func testUSCommandShiftEqualsRecordedAsPlusMatchesBrowserZoomIn() {
        // Pressing ⌘⇧= on US — charactersIgnoringModifiers reports "+".
        // Stored shortcut is "=" with command-only modifiers, so matching with
        // shift held would fail the modifier check; we instead verify the
        // shortcut variant with both command+shift via the recorded form.
        // This test confirms "+" → "=" normalization remains correct when shift
        // IS held (it always was — this is the baseline that must keep working).
        let stroke = ShortcutStroke(key: "=", command: true, shift: true, option: false, control: false)
        XCTAssertTrue(
            stroke.matches(
                keyCode: 24,
                modifierFlags: [.command, .shift],
                eventCharacter: "+",
                layoutCharacterProvider: { _, _ in "+" }
            )
        )
    }

    func testUSCommandMinusMatchesBrowserZoomOut() {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .browserZoomOut).firstStroke
        XCTAssertTrue(
            shortcut.matches(
                keyCode: 27,
                modifierFlags: [.command],
                eventCharacter: "-",
                layoutCharacterProvider: { _, _ in "-" }
            )
        )
    }

    // MARK: - Non-Latin layouts still fall back to US keycodes

    func testRussianCommandWMatchesCloseTabViaKeycodeFallback() {
        // Non-ASCII typed character must still fall back to US-layout keycode
        // so that ⌘W remains reachable on Cyrillic/Greek/etc. layouts.
        let shortcut = KeyboardShortcutSettings.shortcut(for: .closeTab).firstStroke
        XCTAssertTrue(
            shortcut.matches(
                keyCode: 13,
                modifierFlags: [.command],
                eventCharacter: "ц",
                layoutCharacterProvider: Self.russianLayoutCharacter
            ),
            "Non-Latin layouts must still reach Cmd+W via US-layout keycode fallback"
        )
    }

    func testRussianCommandMinusKeyMatchesBrowserZoomOut() {
        // Russian layout produces "-" at keyCode 27 unshifted — ASCII char matches.
        let shortcut = KeyboardShortcutSettings.shortcut(for: .browserZoomOut).firstStroke
        XCTAssertTrue(
            shortcut.matches(
                keyCode: 27,
                modifierFlags: [.command],
                eventCharacter: "-",
                layoutCharacterProvider: Self.russianLayoutCharacter
            )
        )
    }

    // MARK: - Anti-regression: avoid masking the physical-key mismatch case

    func testCommandSymbolShortcutRejectsPhysicalKeyWhenCharacterIsUnrelatedASCII() {
        // A hypothetical user types an ASCII "k" via keyCode 27. The "-" shortcut
        // must NOT match — neither by character nor by keycode fallback.
        let shortcut = KeyboardShortcutSettings.shortcut(for: .browserZoomOut).firstStroke
        XCTAssertFalse(
            shortcut.matches(
                keyCode: 27,
                modifierFlags: [.command],
                eventCharacter: "k",
                layoutCharacterProvider: { _, _ in "k" }
            )
        )
    }
}
