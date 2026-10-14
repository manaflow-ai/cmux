import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class KeyboardNavigationModeTests: XCTestCase {
    func testParsesBareBindingsAndMatchesTheirEvents() throws {
        let mode = try XCTUnwrap(
            KeyboardNavigationMode.parse(
                id: "navigate",
                value: [
                    "enter": "ctrl+space",
                    "bindings": [
                        "h": "focusLeft",
                        "shift+h": "resize-pane-left",
                        "z": "toggleSplitZoom",
                    ],
                    "swallowUnboundKeys": true,
                ] as [String: Any]
            )
        )

        XCTAssertEqual(mode.id, "navigate")
        XCTAssertTrue(mode.swallowUnboundKeys)
        XCTAssertEqual(mode.bindings.count, 3)

        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "h",
                charactersIgnoringModifiers: "h",
                isARepeat: false,
                keyCode: 4
            )
        )
        let matcher = ConfiguredShortcutMatcher(layoutCharacterProvider: { _, _ in nil })
        XCTAssertEqual(mode.action(for: event, matcher: matcher), .focusLeft)
    }

    func testRejectsChordAndUnknownActionBindings() {
        XCTAssertNil(
            KeyboardNavigationMode.parse(
                id: "navigate",
                value: ["enter": "ctrl+space", "bindings": ["h": "unknownAction"]] as [String: Any]
            )
        )
        XCTAssertNil(
            KeyboardNavigationMode.parse(
                id: "navigate",
                value: ["enter": "ctrl+space", "bindings": ["ctrl+h c": "focusLeft"]] as [String: Any]
            )
        )
    }

    func testRejectsActionsOutsideNavigationAllowlist() {
        XCTAssertNil(
            KeyboardNavigationMode.parse(
                id: "navigate",
                value: ["enter": "ctrl+space", "bindings": ["q": "closeWindow"]] as [String: Any]
            )
        )
    }

    func testSettingsFileStoreLoadsNavigationModesAndSkipsInvalidSiblings() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-navigation-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "modes": {
              "navigate": {
                "enter": "ctrl+space",
                "bindings": { "h": "focusLeft" }
              },
              "invalid": {
                "enter": ["ctrl+b", "c"],
                "bindings": { "h": "focusLeft" }
              }
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

        XCTAssertEqual(Set(store.keyboardNavigationModes().keys), Set(["navigate"]))
        XCTAssertEqual(store.keyboardNavigationModes()["navigate"]?.bindings.count, 1)
    }
}
