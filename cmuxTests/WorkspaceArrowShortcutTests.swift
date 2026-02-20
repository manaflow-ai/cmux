import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
@MainActor
final class WorkspaceArrowShortcutTests: XCTestCase {
    private final class TabManagerSpy: TabManager {
        private(set) var didSelectNextTab = false
        private(set) var didSelectPreviousTab = false

        override func selectNextTab() {
            didSelectNextTab = true
        }

        override func selectPreviousTab() {
            didSelectPreviousTab = true
        }
    }

    private var originalNextShortcut: StoredShortcut?
    private var originalPrevShortcut: StoredShortcut?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        originalNextShortcut = KeyboardShortcutSettings.shortcut(for: .nextSidebarTab)
        originalPrevShortcut = KeyboardShortcutSettings.shortcut(for: .prevSidebarTab)
    }

    override func tearDown() {
        if let originalNextShortcut {
            KeyboardShortcutSettings.setShortcut(originalNextShortcut, for: .nextSidebarTab)
        }
        if let originalPrevShortcut {
            KeyboardShortcutSettings.setShortcut(originalPrevShortcut, for: .prevSidebarTab)
        }
        super.tearDown()
    }

    func testNextWorkspaceShortcutMatchesCommandShiftUpArrowFunctionKeyEvent() {
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "↑", command: true, shift: true, option: false, control: false),
            for: .nextSidebarTab
        )

        let tabManager = TabManagerSpy()
        let appDelegate = AppDelegate()
        appDelegate.tabManager = tabManager

        let upArrowFunctionKey = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let event = makeKeyDownEvent(
            characters: upArrowFunctionKey,
            charactersIgnoringModifiers: upArrowFunctionKey,
            modifiers: [.command, .shift, .numericPad, .function],
            keyCode: 126 // kVK_UpArrow
        )

        XCTAssertNotNil(event)
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event!))
        XCTAssertTrue(tabManager.didSelectNextTab)
    }

    func testPreviousWorkspaceShortcutMatchesCommandShiftDownArrowFunctionKeyEvent() {
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "↓", command: true, shift: true, option: false, control: false),
            for: .prevSidebarTab
        )

        let tabManager = TabManagerSpy()
        let appDelegate = AppDelegate()
        appDelegate.tabManager = tabManager

        let downArrowFunctionKey = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let event = makeKeyDownEvent(
            characters: downArrowFunctionKey,
            charactersIgnoringModifiers: downArrowFunctionKey,
            modifiers: [.command, .shift, .numericPad, .function],
            keyCode: 125 // kVK_DownArrow
        )

        XCTAssertNotNil(event)
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event!))
        XCTAssertTrue(tabManager.didSelectPreviousTab)
    }

    private func makeKeyDownEvent(
        characters: String,
        charactersIgnoringModifiers: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
#endif
