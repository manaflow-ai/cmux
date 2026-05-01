import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class ShortcutUnbindingRoutingTests: XCTestCase {
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!

    override func setUp() {
        super.setUp()
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.resetAll()
    }

    override func tearDown() {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        KeyboardShortcutSettings.resetAll()
        super.tearDown()
    }

    func testEmptySettingsFileShortcutBindingPassesThroughDefaultKeypress() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shortcut-unbinding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "newTab": ""
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let event = makeKeyDownEvent(windowNumber: window.windowNumber) else {
            XCTFail("Expected test window, manager, and Cmd+N event")
            return
        }

        let initialCount = manager.tabs.count

#if DEBUG
        XCTAssertFalse(
            appDelegate.debugHandleCustomShortcut(event: event),
            "An empty shortcut binding should pass the keypress through to the focused surface"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertEqual(manager.tabs.count, initialCount)
    }

    private func makeKeyDownEvent(windowNumber: Int) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 45
        )
    }

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = window(withId: windowId) else { return }
        window.performClose(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}

final class ShortcutUnbindingParsingTests: XCTestCase {
    func testSettingsFileStoreParsesEmptyShortcutBindingAsUnbound() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shortcut-unbinding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "newTab": "",
            "openBrowser": "none",
            "splitRight": null
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(store.override(for: .newTab), StoredShortcut.unbound)
        XCTAssertEqual(store.override(for: .openBrowser), StoredShortcut.unbound)
        XCTAssertEqual(store.override(for: .splitRight), StoredShortcut.unbound)
    }

    func testUnboundShortcutNeverMatchesKeypress() {
        let shortcut = StoredShortcut.unbound

        XCTAssertFalse(
            shortcut.matches(
                keyCode: 45,
                modifierFlags: [.command],
                eventCharacter: "n",
                layoutCharacterProvider: { _, _ in nil }
            )
        )
        XCTAssertNil(shortcut.keyEquivalent)
        XCTAssertNil(shortcut.menuItemKeyEquivalent)
        XCTAssertNil(shortcut.carbonHotKeyRegistration)
    }
}
