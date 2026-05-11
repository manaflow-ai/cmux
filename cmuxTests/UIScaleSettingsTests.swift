import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class UIScaleSettingsTests: XCTestCase {
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!
    private var savedUIScale: Any?
    private var savedShortcuts: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    private var actionsWithPersistedShortcuts: Set<KeyboardShortcutSettings.Action> = []

    override func setUp() {
        super.setUp()
        executionTimeAllowance = 30
        savedUIScale = UserDefaults.standard.object(forKey: UIScaleSettings.userDefaultsKey)
        actionsWithPersistedShortcuts = Set(
            [
                KeyboardShortcutSettings.Action.uiScaleZoomIn,
                KeyboardShortcutSettings.Action.uiScaleZoomOut,
                KeyboardShortcutSettings.Action.uiScaleReset,
            ].filter { UserDefaults.standard.object(forKey: $0.defaultsKey) != nil }
        )
        savedShortcuts = Dictionary(
            uniqueKeysWithValues: actionsWithPersistedShortcuts.map { action in
                (action, KeyboardShortcutSettings.shortcut(for: action))
            }
        )
        originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-ui-scale-settings"
        )
        KeyboardShortcutSettings.resetShortcut(for: .uiScaleZoomIn)
        KeyboardShortcutSettings.resetShortcut(for: .uiScaleZoomOut)
        KeyboardShortcutSettings.resetShortcut(for: .uiScaleReset)
        UserDefaults.standard.removeObject(forKey: UIScaleSettings.userDefaultsKey)
    }

    override func tearDown() {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        for action in [
            KeyboardShortcutSettings.Action.uiScaleZoomIn,
            KeyboardShortcutSettings.Action.uiScaleZoomOut,
            KeyboardShortcutSettings.Action.uiScaleReset,
        ] {
            if actionsWithPersistedShortcuts.contains(action), let shortcut = savedShortcuts[action] {
                KeyboardShortcutSettings.setShortcut(shortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
        }
        if let savedUIScale {
            UserDefaults.standard.set(savedUIScale, forKey: UIScaleSettings.userDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: UIScaleSettings.userDefaultsKey)
        }
        super.tearDown()
    }

    func testSettingsFileRoundTripsAppUIScale() throws {
        let settingsFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-scale-\(UUID().uuidString).json", isDirectory: false)
        try #"{"schemaVersion":1,"app":{"appearance":"system"}}"#.write(
            to: settingsFileURL,
            atomically: true,
            encoding: .utf8
        )
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        UIScaleSettings.set(1.23)

        let data = try Data(contentsOf: settingsFileURL)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONCParser.preprocess(data)) as? [String: Any]
        )
        let appSection = try XCTUnwrap(json["app"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(appSection["uiScale"] as? Double), 1.23, accuracy: 0.001)

        UserDefaults.standard.removeObject(forKey: UIScaleSettings.userDefaultsKey)
        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        XCTAssertEqual(UIScaleSettings.resolved(), 1.23, accuracy: 0.001)
    }

    func testSidebarViewReceivesUIScaleThroughEnvironment() throws {
        var capturedFontSize: CGFloat?
        let view = RightSidebarUIScaleProbeView { fontSize in
            capturedFontSize = fontSize
        }
        .environment(\.uiScaleFactor, 1.35)
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        defer { window.close() }

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let scaledFontSize = try XCTUnwrap(capturedFontSize)
        XCTAssertEqual(
            scaledFontSize,
            RightSidebarModeBarMetrics.labelFontSize(uiScaleFactor: 1.35),
            accuracy: 0.001
        )
        XCTAssertGreaterThan(
            scaledFontSize,
            RightSidebarModeBarMetrics.labelFontSize(uiScaleFactor: 1.0)
        )
    }

    func testUIScaleShortcutsClampAndReset() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        UIScaleSettings.set(UIScaleSettings.maximum, persistToSettingsFile: false)
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: keyEvent(characters: "+", ignoring: "=", keyCode: UInt16(kVK_ANSI_Equal))))
        XCTAssertEqual(UIScaleSettings.resolved(), UIScaleSettings.maximum, accuracy: 0.001)

        UIScaleSettings.set(UIScaleSettings.minimum, persistToSettingsFile: false)
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: keyEvent(characters: "_", ignoring: "-", keyCode: UInt16(kVK_ANSI_Minus))))
        XCTAssertEqual(UIScaleSettings.resolved(), UIScaleSettings.minimum, accuracy: 0.001)

        UIScaleSettings.set(1.45, persistToSettingsFile: false)
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: keyEvent(characters: ")", ignoring: "0", keyCode: UInt16(kVK_ANSI_0))))
        XCTAssertEqual(UIScaleSettings.resolved(), UIScaleSettings.defaultValue, accuracy: 0.001)
    }

    private func keyEvent(characters: String, ignoring: String, keyCode: UInt16) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: ignoring,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("Failed to construct key event")
        }
        return event
    }
}
