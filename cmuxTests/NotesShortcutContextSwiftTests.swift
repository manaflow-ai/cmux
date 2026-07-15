import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// The app target still declares a legacy duplicate of the CmuxSettings stroke
// value type; pin the package type explicitly (same trick as
// cmuxTests/KeyboardShortcutContextTests.swift).
private typealias ShortcutStroke = CmuxSettings.ShortcutStroke

// Extracted from cmuxTests/KeyboardShortcutContextTests.swift so this branch's
// new coverage lives in a Swift Testing suite while the original XCTest file
// stays identical to main.
@MainActor
@Suite(.serialized)
struct NotesShortcutContextSwiftTests {
    @Test func testNewNoteSettingsPackageActionStaysAligned() throws {
        let settingsAction = try #require(
            ShortcutAction(rawValue: KeyboardShortcutSettings.Action.newNote.rawValue),
            "Expected CmuxSettings.ShortcutAction for newNote"
        )
        #expect(settingsAction.defaultStroke == ShortcutStroke(key: "n", command: true, control: true))
        #expect(settingsAction.displayName == KeyboardShortcutSettings.Action.newNote.label)
    }
}
