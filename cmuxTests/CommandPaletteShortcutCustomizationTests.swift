import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CommandPaletteShortcutCustomizationTests: XCTestCase {
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!
    private var settingsDirectoryURL: URL!
    private var savedCommandPaletteNext: Any?
    private var savedCommandPalettePrevious: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        executionTimeAllowance = 30
        let defaults = UserDefaults.standard
        savedCommandPaletteNext = defaults.object(forKey: KeyboardShortcutSettings.Action.commandPaletteNext.defaultsKey)
        savedCommandPalettePrevious = defaults.object(forKey: KeyboardShortcutSettings.Action.commandPalettePrevious.defaultsKey)
        defaults.removeObject(forKey: KeyboardShortcutSettings.Action.commandPaletteNext.defaultsKey)
        defaults.removeObject(forKey: KeyboardShortcutSettings.Action.commandPalettePrevious.defaultsKey)
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        settingsDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectoryURL, withIntermediateDirectories: true)
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsDirectoryURL.appendingPathComponent("cmux.json").path,
            fallbackPath: nil,
            startWatching: false
        )
    }

    override func tearDown() {
        restoreDefault(savedCommandPaletteNext, forKey: KeyboardShortcutSettings.Action.commandPaletteNext.defaultsKey)
        restoreDefault(savedCommandPalettePrevious, forKey: KeyboardShortcutSettings.Action.commandPalettePrevious.defaultsKey)
        savedCommandPaletteNext = nil
        savedCommandPalettePrevious = nil
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        if let settingsDirectoryURL {
            try? FileManager.default.removeItem(at: settingsDirectoryURL)
        }
        super.tearDown()
    }

    private func restoreDefault(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func testFieldEditorMoveCommandHonorsClearedCommandPalettePreviousShortcut() {
        guard let controlPEvent = makeKeyDownEvent(
            key: "\u{10}",
            modifiers: [.control],
            keyCode: 35,
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Ctrl+P event")
            return
        }

        XCTAssertNil(
            commandPaletteSelectionDeltaForFieldEditorCommand(
                #selector(NSResponder.moveUp(_:)),
                event: controlPEvent,
                previousShortcut: nil
            ),
            "The field editor must not translate cleared Ctrl+P into palette navigation"
        )
    }

    func testKeyboardNavigationDefaultLookupHonorsClearedCommandPalettePreviousShortcut() {
        withTemporaryCommandPalettePreviousShortcut {
            KeyboardShortcutSettings.unbindShortcut(for: .commandPalettePrevious)
            XCTAssertNil(KeyboardShortcutSettings.shortcutIfBound(for: .commandPalettePrevious))

            XCTAssertNil(
                commandPaletteSelectionDeltaForKeyboardNavigation(
                    flags: [.control],
                    chars: "\u{10}",
                    keyCode: 35
                ),
                "Default keyboard-navigation lookup must not fall back to hardcoded Ctrl+P after unbinding"
            )
        }
    }

    func testKeyboardNavigationDefaultLookupHonorsRemappedCommandPalettePreviousShortcut() {
        withTemporaryCommandPalettePreviousShortcut {
            let remappedPrevious = StoredShortcut(key: "u", command: false, shift: false, option: false, control: true)
            KeyboardShortcutSettings.setShortcut(remappedPrevious, for: .commandPalettePrevious)

            XCTAssertNil(
                commandPaletteSelectionDeltaForKeyboardNavigation(
                    flags: [.control],
                    chars: "\u{10}",
                    keyCode: 35
                )
            )
            XCTAssertEqual(
                commandPaletteSelectionDeltaForKeyboardNavigation(
                    flags: [.control],
                    chars: "\u{15}",
                    keyCode: 32
                ),
                -1
            )
        }
    }

    func testFieldEditorMoveCommandWithoutEventHonorsClearedCommandPalettePreviousShortcut() {
        XCTAssertNil(
            commandPaletteSelectionDeltaForFieldEditorCommand(
                #selector(NSResponder.moveUp(_:)),
                event: nil,
                previousShortcut: nil
            ),
            "The field editor must not use AppKit moveUp fallback after Ctrl+P is cleared"
        )
    }

    func testFieldEditorMoveCommandWithoutEventOnlyUsesDefaultCommandPalettePreviousShortcut() {
        let remappedPrevious = StoredShortcut(key: "u", command: false, shift: false, option: false, control: true)
        XCTAssertNil(
            commandPaletteSelectionDeltaForFieldEditorCommand(
                #selector(NSResponder.moveUp(_:)),
                event: nil,
                previousShortcut: remappedPrevious
            )
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForFieldEditorCommand(
                #selector(NSResponder.moveUp(_:)),
                event: nil
            ),
            -1
        )
    }

    func testFieldEditorMoveCommandHonorsRemappedCommandPalettePreviousShortcut() {
        let remappedPrevious = StoredShortcut(
            key: "u",
            command: false,
            shift: false,
            option: false,
            control: true
        )

        guard let controlPEvent = makeKeyDownEvent(
            key: "\u{10}",
            modifiers: [.control],
            keyCode: 35,
            windowNumber: 0
        ),
        let controlUEvent = makeKeyDownEvent(
            key: "\u{15}",
            modifiers: [.control],
            keyCode: 32,
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct command-palette navigation events")
            return
        }

        XCTAssertNil(
            commandPaletteSelectionDeltaForFieldEditorCommand(
                #selector(NSResponder.moveUp(_:)),
                event: controlPEvent,
                previousShortcut: remappedPrevious
            )
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForFieldEditorCommand(
                #selector(NSResponder.moveUp(_:)),
                event: controlUEvent,
                previousShortcut: remappedPrevious
            ),
            -1
        )
    }

    func testFieldEditorMoveCommandAlwaysKeepsPlainArrowNavigation() {
        guard let upArrowEvent = makeKeyDownEvent(
            key: String(UnicodeScalar(NSUpArrowFunctionKey)!),
            modifiers: [],
            keyCode: 126,
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Up Arrow event")
            return
        }

        XCTAssertEqual(
            commandPaletteSelectionDeltaForFieldEditorCommand(
                #selector(NSResponder.moveUp(_:)),
                event: upArrowEvent,
                previousShortcut: nil
            ),
            -1
        )
    }

    func testRemappedCommandPalettePreviousShortcutDoesNotConsumeControlP() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withCommandPaletteFieldEditor(appDelegate: appDelegate) { window in
            withTemporaryCommandPalettePreviousShortcut {
                let remappedPrevious = StoredShortcut(key: "u", command: false, shift: false, option: false, control: true)
                KeyboardShortcutSettings.setShortcut(remappedPrevious, for: .commandPalettePrevious)
                XCTAssertEqual(KeyboardShortcutSettings.shortcutIfBound(for: .commandPalettePrevious), remappedPrevious)

                let controlPExpectation = expectation(
                    description: "Remapped Ctrl+P should not route command palette move-selection"
                )
                controlPExpectation.isInverted = true
                let controlPToken = NotificationCenter.default.addObserver(
                    forName: .commandPaletteMoveSelection,
                    object: nil,
                    queue: nil
                ) { _ in
                    controlPExpectation.fulfill()
                }
                defer { NotificationCenter.default.removeObserver(controlPToken) }

                guard let controlPEvent = makeKeyDownEvent(
                    key: "\u{10}",
                    modifiers: [.control],
                    keyCode: 35,
                    windowNumber: window.windowNumber
                ) else {
                    XCTFail("Failed to construct Ctrl+P event")
                    return
                }

                #if DEBUG
                XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: controlPEvent))
                #else
                XCTFail("debugHandleCustomShortcut is only available in DEBUG")
                #endif

                wait(for: [controlPExpectation], timeout: 0.15)

                let controlUExpectation = expectation(
                    description: "Remapped Ctrl+U should route command palette previous selection"
                )
                var observedDelta: Int?
                let controlUToken = NotificationCenter.default.addObserver(
                    forName: .commandPaletteMoveSelection,
                    object: nil,
                    queue: nil
                ) { notification in
                    observedDelta = notification.userInfo?["delta"] as? Int
                    controlUExpectation.fulfill()
                }
                defer { NotificationCenter.default.removeObserver(controlUToken) }

                guard let controlUEvent = makeKeyDownEvent(
                    key: "\u{15}",
                    modifiers: [.control],
                    keyCode: 32,
                    windowNumber: window.windowNumber
                ) else {
                    XCTFail("Failed to construct Ctrl+U event")
                    return
                }

                #if DEBUG
                XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: controlUEvent))
                #else
                XCTFail("debugHandleCustomShortcut is only available in DEBUG")
                #endif

                wait(for: [controlUExpectation], timeout: 1.0)
                XCTAssertEqual(observedDelta, -1)
            }
        }
    }

    func testUnboundCommandPalettePreviousShortcutLetsControlPPassThrough() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withCommandPaletteFieldEditor(appDelegate: appDelegate) { window in
            withTemporaryCommandPalettePreviousShortcut {
                KeyboardShortcutSettings.unbindShortcut(for: .commandPalettePrevious)
                XCTAssertNil(KeyboardShortcutSettings.shortcutIfBound(for: .commandPalettePrevious))

                let moveExpectation = expectation(
                    description: "Unbound Ctrl+P should not route command palette move-selection"
                )
                moveExpectation.isInverted = true
                let moveToken = NotificationCenter.default.addObserver(
                    forName: .commandPaletteMoveSelection,
                    object: nil,
                    queue: nil
                ) { _ in
                    moveExpectation.fulfill()
                }
                defer { NotificationCenter.default.removeObserver(moveToken) }

                guard let controlPEvent = makeKeyDownEvent(
                    key: "\u{10}",
                    modifiers: [.control],
                    keyCode: 35,
                    windowNumber: window.windowNumber
                ) else {
                    XCTFail("Failed to construct Ctrl+P event")
                    return
                }

                #if DEBUG
                XCTAssertFalse(
                    appDelegate.debugHandleCustomShortcut(event: controlPEvent),
                    "Unbound Ctrl+P should stay on the normal keyDown path so the terminal can receive ^P"
                )
                #else
                XCTFail("debugHandleCustomShortcut is only available in DEBUG")
                #endif

                wait(for: [moveExpectation], timeout: 0.15)
            }
        }
    }

    func testChordedCommandPaletteNextShortcutMovesSelection() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withCommandPaletteFieldEditor(appDelegate: appDelegate) { window in
            withTemporaryCommandPaletteShortcut(.commandPaletteNext) {
                KeyboardShortcutSettings.setShortcut(
                    StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "n"),
                    for: .commandPaletteNext
                )
                let moveExpectation = expectation(description: "Expected chorded next shortcut to move selection")
                var observedDeltas: [Int] = []
                var observedWindow: NSWindow?
                let moveToken = NotificationCenter.default.addObserver(forName: .commandPaletteMoveSelection, object: nil, queue: nil) { notification in
                    observedWindow = notification.object as? NSWindow
                    if let delta = notification.userInfo?["delta"] as? Int {
                        observedDeltas.append(delta)
                        moveExpectation.fulfill()
                    }
                }
                defer { NotificationCenter.default.removeObserver(moveToken) }

                guard let prefixEvent = makeKeyDownEvent(key: "b", modifiers: [.control], keyCode: 11, windowNumber: window.windowNumber),
                      let actionEvent = makeKeyDownEvent(key: "n", modifiers: [], keyCode: 45, windowNumber: window.windowNumber) else {
                    XCTFail("Failed to construct command-palette chord events")
                    return
                }

                #if DEBUG
                XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
                XCTAssertEqual(observedDeltas, [], "Chord prefix must arm without moving selection")
                XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: actionEvent))
                #else
                XCTFail("debugHandleCustomShortcut is only available in DEBUG")
                #endif

                wait(for: [moveExpectation], timeout: 1.0)
                XCTAssertEqual(observedWindow?.windowNumber, window.windowNumber)
                XCTAssertEqual(observedDeltas, [1])
            }
        }
    }

    private func withCommandPaletteFieldEditor(
        appDelegate: AppDelegate,
        _ body: (NSWindow) -> Void
    ) {
        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView else {
            XCTFail("Expected test window")
            return
        }

        let overlayContainer = NSView(frame: contentView.bounds)
        overlayContainer.identifier = commandPaletteOverlayContainerIdentifier
        overlayContainer.alphaValue = 1
        overlayContainer.isHidden = false
        contentView.addSubview(overlayContainer)

        let fieldEditor = CommandPaletteShortcutFieldEditor(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        fieldEditor.isFieldEditor = true
        overlayContainer.addSubview(fieldEditor)
        XCTAssertTrue(window.makeFirstResponder(fieldEditor))

        appDelegate.setCommandPaletteVisible(false, for: window)
        defer {
            overlayContainer.removeFromSuperview()
            fieldEditor.removeFromSuperview()
        }

        body(window)
    }

    private func withTemporaryCommandPalettePreviousShortcut(_ body: () -> Void) {
        withTemporaryCommandPaletteShortcut(.commandPalettePrevious, body)
    }

    private func withTemporaryCommandPaletteShortcut(
        _ action: KeyboardShortcutSettings.Action,
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
        body()
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
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

private final class CommandPaletteShortcutFieldEditor: NSTextView {
    override func hasMarkedText() -> Bool {
        false
    }
}
