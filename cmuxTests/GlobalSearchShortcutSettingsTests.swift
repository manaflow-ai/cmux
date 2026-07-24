import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
final class GlobalSearchShortcutSettingsTests {
    private let originalSettingsFileStore: KeyboardShortcutSettingsFileStore

    init() {
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-global-search-shortcuts-\(UUID().uuidString).json")
                .path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()
    }

    deinit {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        KeyboardShortcutSettings.resetAll()
    }

    @Test func globalSearchDefaultShortcutIsRemappableAndForegroundScoped() {
        let defaultShortcut = KeyboardShortcutSettings.shortcut(for: .globalSearch)

        #expect(
            defaultShortcut ==
                StoredShortcut(key: "f", command: true, shift: false, option: true, control: false)
        )
        #expect(KeyboardShortcutSettings.publicShortcutActions.contains(.globalSearch))
        #expect(KeyboardShortcutSettings.settingsVisibleActions.contains(.globalSearch))
        #expect(KeyboardShortcutSettings.shortcut(for: .sendFeedback) == .unbound)
        #expect(
            KeyboardShortcutSettings.Action.globalSearch.normalizedRecordedShortcutResult(defaultShortcut) ==
                .accepted(defaultShortcut)
        )
    }

    @Test func globalSearchUsesApplicationBareKeyPolicy() {
        #expect(!KeyboardShortcutSettings.Action.globalSearch.allowsBareFirstStroke)
    }

    @Test func optionOnlyGlobalSearchRoutesBeforePrintableOptionTextBypass() throws {
        let shortcut = StoredShortcut(
            key: "q",
            command: false,
            shift: false,
            option: true,
            control: false
        )
        KeyboardShortcutSettings.setShortcut(shortcut, for: .globalSearch)

        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "@",
                charactersIgnoringModifiers: "q",
                isARepeat: false,
                keyCode: 12
            )
        )
        let appDelegate = AppDelegate.shared ?? AppDelegate()

        #expect(shortcutRoutingShouldBypassForPrintableOptionText(event: event))
        #expect(!shortcut.matches(event: event))
        #expect(appDelegate.matchCachedGlobalSearchShortcut(event: event))
    }

    @Test func ordinaryTypingDoesNotResolveGlobalSearchBinding() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            )
        )
        appDelegate.debugResetShortcutRoutingStateForTesting()
        var globalSearchLookupCount = 0
        KeyboardShortcutSettings.shortcutLookupObserver = { action in
            if action == .globalSearch {
                globalSearchLookupCount += 1
            }
        }
        defer {
            KeyboardShortcutSettings.shortcutLookupObserver = nil
            appDelegate.debugResetShortcutRoutingStateForTesting()
        }

        #expect(!appDelegate.debugHandleCustomShortcut(event: event))
        #expect(globalSearchLookupCount == 0)
#else
        Issue.record("Shortcut lookup instrumentation requires a DEBUG build")
#endif
    }

    @Test func optionOnlyGlobalSearchChordPrefixRoutesBeforePrintableOptionTextBypass() throws {
#if DEBUG
        let shortcut = StoredShortcut(
            key: "q",
            command: false,
            shift: false,
            option: true,
            control: false,
            chordKey: "f"
        )
        KeyboardShortcutSettings.setShortcut(shortcut, for: .globalSearch)

        let prefixEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "@",
                charactersIgnoringModifiers: "q",
                isARepeat: false,
                keyCode: 12
            )
        )
        let suffixEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "f",
                charactersIgnoringModifiers: "f",
                isARepeat: false,
                keyCode: 3
            )
        )
        let appDelegate = try #require(AppDelegate.shared)
        var didTogglePalette = false
        defer {
            if didTogglePalette {
                appDelegate.toggleGlobalSearchPalette()
            }
            appDelegate.debugResetShortcutRoutingStateForTesting()
        }

        #expect(shortcutRoutingShouldBypassForPrintableOptionText(event: prefixEvent))
        #expect(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
        didTogglePalette = appDelegate.debugHandleCustomShortcut(event: suffixEvent)
        #expect(didTogglePalette)
#else
        Issue.record("Option-only Global Search chord routing requires a DEBUG build")
#endif
    }

    @Test func globalSearchRejectsConfiguredShowHideHotkeyConflict() {
        let reservedShortcut = StoredShortcut(key: "g", command: true, shift: false, option: true, control: true)

        KeyboardShortcutSettings.setShortcut(.unbound, for: .globalSearch)
        SystemWideHotkeySettings.setShortcut(reservedShortcut)

        #expect(
            KeyboardShortcutSettings.Action.globalSearch.normalizedRecordedShortcutResult(reservedShortcut) ==
                .rejected(.conflictsWithAction(.showHideAllWindows))
        )
    }

    @Test func settingsFileStoreParsesGlobalSearchShortcut() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-global-search-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "globalSearch": "cmd+ctrl+g"
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        #expect(
            store.override(for: .globalSearch) ==
                StoredShortcut(key: "g", command: true, shift: false, option: false, control: true)
        )
    }

    @Test func settingsFileStoreParsesPackageObjectFormGlobalSearchShortcut() throws {
        // Regression for #5137: the Settings package writes a nested StoredShortcut object.
        // Both foreground and system-wide routes must read that form rather than fall back.
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-global-search-object-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "bindings": {
              "globalSearch": {
                "first": { "key": "j", "command": true, "shift": false, "option": false, "control": true }
              }
            }
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        #expect(
            store.override(for: .globalSearch) ==
                StoredShortcut(key: "j", command: true, shift: false, option: false, control: true)
        )
    }

    @Test func settingsFileStoreParsesPackageObjectFormChordShortcut() throws {
        // Package object form also encodes chords as {"first": {...}, "second": {...}}.
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-chord-object-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "bindings": {
              "newTab": {
                "first": { "key": "b", "command": false, "shift": false, "option": false, "control": true },
                "second": { "key": "n", "command": false, "shift": false, "option": false, "control": false }
              }
            }
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        #expect(
            store.override(for: .newTab) ==
                StoredShortcut(
                    key: "b",
                    command: false,
                    shift: false,
                    option: false,
                    control: true,
                    chordKey: "n",
                    chordCommand: false,
                    chordShift: false,
                    chordOption: false,
                    chordControl: false
                )
        )
    }

    @Test func settingsFileStoreParsesPackageObjectFormUnboundShortcut() throws {
        // An empty primary key marks an explicit unbound override, not invalid data.
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-unbound-object-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "bindings": {
              "globalSearch": { "first": { "key": "", "command": false, "shift": false, "option": false, "control": false } }
            }
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        #expect(store.override(for: .globalSearch) == .unbound)
    }

    @Test func settingsFileStoreRejectsObjectFormChordWithMalformedSecondStroke() throws {
        // A malformed second stroke invalidates the chord instead of degrading it.
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-bad-chord-object-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "bindings": {
              "newTab": {
                "first": { "key": "b", "command": false, "shift": false, "option": false, "control": true },
                "second": { "command": false }
              }
            }
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        #expect(store.override(for: .newTab) == nil)
    }

    @Test func settingsFileStoreRejectsObjectFormBareKeyForModifierRequiringAction() throws {
        // Object and string parsing apply the same bare-first-stroke rule.
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-bare-object-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "bindings": {
              "newTab": { "first": { "key": "j", "command": false, "shift": false, "option": false, "control": false } }
            }
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        #expect(store.override(for: .newTab) == nil)
    }

    @Test func settingsFileStoreParsesGlobalSearchChordBinding() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-global-search-chord-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "globalSearch": ["cmd+k", "f"]
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        #expect(
            store.override(for: .globalSearch) ==
                StoredShortcut(
                    key: "k",
                    command: true,
                    shift: false,
                    option: false,
                    control: false,
                    chordKey: "f",
                    chordCommand: false,
                    chordShift: false,
                    chordOption: false,
                    chordControl: false
                )
        )
    }
}
