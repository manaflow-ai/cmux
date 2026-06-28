import XCTest
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Verifies that the app-target settings file store parses the optional
/// `shortcuts.commands` sub-map into per-command ``StoredShortcut`` overrides,
/// accepting the single-stroke string, nested-object, and `null` (unbound)
/// value forms. Custom command shortcuts are single-stroke only, so chord
/// forms (string-array of two, or object with a `second` stroke) are rejected.
final class CommandShortcutFileStoreTests: XCTestCase {
    func testParsesStringAndArrayAndNullCommandBindings() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-command-shortcuts-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "commands": {
              "palette.triggerFlash": "cmd+shift+1",
              "palette.openFolder": ["ctrl+b", "o"],
              "palette.chordObject": {"first": {"key": "j", "command": true}, "second": {"key": "k"}},
              "palette.foo": {"first": {"key": "k", "command": true}},
              "palette.closeTab": null
            }
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        let overrides = store.commandShortcutOverrides()

        // Single-stroke string form parses.
        XCTAssertEqual(overrides["palette.triggerFlash"]?.key, "1")
        XCTAssertEqual(overrides["palette.triggerFlash"]?.command, true)
        // Chord array form is rejected (single-stroke only).
        XCTAssertNil(overrides["palette.openFolder"])
        // Object form with a `second` stroke is a chord — also rejected.
        XCTAssertNil(overrides["palette.chordObject"])
        // Nested-object form (the shape the UI writes) round-trips.
        XCTAssertEqual(overrides["palette.foo"]?.key, "k")
        XCTAssertEqual(overrides["palette.foo"]?.command, true)
        XCTAssertEqual(overrides["palette.foo"]?.hasChord, false)
        // Explicit null is unbound.
        XCTAssertEqual(overrides["palette.closeTab"]?.isUnbound, true)
    }
}
