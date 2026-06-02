import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class BareShortcutNotificationCounter: @unchecked Sendable {
    var count = 0
}

@MainActor
final class AppDelegateBareSpaceShortcutRoutingTests: XCTestCase {
    private var savedShortcutsByAction: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    private var actionsWithPersistedShortcut: Set<KeyboardShortcutSettings.Action> = []
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!

    override func setUp() {
        super.setUp()
        executionTimeAllowance = 30
        actionsWithPersistedShortcut = Set(
            KeyboardShortcutSettings.Action.allCases.filter {
                UserDefaults.standard.object(forKey: $0.defaultsKey) != nil
            }
        )
        savedShortcutsByAction = Dictionary(
            uniqueKeysWithValues: actionsWithPersistedShortcut.map { action in
                (action, KeyboardShortcutSettings.shortcut(for: action))
            }
        )
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.resetAll()
    }

    override func tearDown() {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        for action in KeyboardShortcutSettings.Action.allCases {
            if actionsWithPersistedShortcut.contains(action),
               let savedShortcut = savedShortcutsByAction[action] {
                KeyboardShortcutSettings.setShortcut(savedShortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
        }
        super.tearDown()
    }

    func testBareSpaceShortcutDispatchesConfiguredAction() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let shortcut = StoredShortcut(key: "space", command: false, shift: false, option: false, control: false)
        let paletteRequests = BareShortcutNotificationCounter()
        let paletteToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRequested,
            object: nil,
            queue: nil
        ) { _ in
            paletteRequests.count += 1
        }
        defer { NotificationCenter.default.removeObserver(paletteToken) }

        withTemporaryShortcut(action: .commandPalette, shortcut: shortcut) {
            guard let event = makeKeyDownEvent(key: " ", keyCode: 49) else {
                XCTFail("Failed to construct Space event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        XCTAssertEqual(paletteRequests.count, 1, "Bare Space should dispatch when explicitly configured")
    }

    func testBareSpaceChordPrefixArmsConfiguredShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let shortcut = StoredShortcut(
            key: "space",
            command: false,
            shift: false,
            option: false,
            control: false,
            chordKey: "n"
        )
        let paletteRequests = BareShortcutNotificationCounter()
        let paletteToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRequested,
            object: nil,
            queue: nil
        ) { _ in
            paletteRequests.count += 1
        }
        defer { NotificationCenter.default.removeObserver(paletteToken) }

        withTemporaryShortcut(action: .commandPalette, shortcut: shortcut) {
            guard let prefixEvent = makeKeyDownEvent(key: " ", keyCode: 49),
                  let actionEvent = makeKeyDownEvent(key: "n", keyCode: 45) else {
                XCTFail("Failed to construct Space chord events")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
            XCTAssertEqual(paletteRequests.count, 0, "Bare Space prefix must not fire the action early")

            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: actionEvent))
            XCTAssertEqual(paletteRequests.count, 1, "Bare Space chord should dispatch on the second stroke")
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
    }

    func testCreateMainWindowUsesPersistedGeometryWhenNoSourceWindow() {
        let styleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView
        ]
        let savedFrame = CGRect(x: 160, y: 120, width: 980, height: 700)

        let initialGeometry = AppDelegate.resolvedMainWindowInitialGeometry(
            styleMask: styleMask,
            restoredFrame: nil,
            sourceFrame: nil,
            persistedGeometryFrame: savedFrame
        )

        guard let explicitFrame = initialGeometry.explicitFrame else {
            XCTFail("Expected persisted geometry to be applied as the explicit initial frame")
            return
        }
        XCTAssertEqual(explicitFrame.minX, savedFrame.minX, accuracy: 0.001)
        XCTAssertEqual(explicitFrame.minY, savedFrame.minY, accuracy: 0.001)
        XCTAssertEqual(explicitFrame.width, savedFrame.width, accuracy: 0.001)
        XCTAssertEqual(explicitFrame.height, savedFrame.height, accuracy: 0.001)

        let expectedContentRect = NSWindow.contentRect(forFrameRect: savedFrame, styleMask: styleMask)
        XCTAssertEqual(initialGeometry.contentRect.minX, expectedContentRect.minX, accuracy: 0.001)
        XCTAssertEqual(initialGeometry.contentRect.minY, expectedContentRect.minY, accuracy: 0.001)
        XCTAssertEqual(initialGeometry.contentRect.width, expectedContentRect.width, accuracy: 0.001)
        XCTAssertEqual(initialGeometry.contentRect.height, expectedContentRect.height, accuracy: 0.001)
    }

    private func makeKeyDownEvent(
        key: String,
        keyCode: UInt16,
        windowNumber: Int = 0
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func withTemporaryShortcut(
        action: KeyboardShortcutSettings.Action,
        shortcut: StoredShortcut,
        _ body: () -> Void
    ) {
        let hadPersistedShortcut = UserDefaults.standard.object(forKey: action.defaultsKey) != nil
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer {
            if hadPersistedShortcut {
                KeyboardShortcutSettings.setShortcut(originalShortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
        }
        KeyboardShortcutSettings.setShortcut(shortcut, for: action)
        body()
    }

}
