import AppKit
import Carbon.HIToolbox
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/11228.
///
/// AppKit performs menu key-equivalent dispatch before the focused terminal's
/// key path. The terminal must get first refusal for standard Edit chords while
/// native editing responders retain the normal menu/responder-chain behavior.
@MainActor
@Suite(.serialized)
struct TerminalCommandEquivalentRoutingTests {
    private final class MenuActionProbe: NSObject {
        private(set) var actions: [String] = []

        @objc func copyAction(_ sender: Any?) {
            _ = sender
            actions.append("copy")
        }

        @objc func pasteAction(_ sender: Any?) {
            _ = sender
            actions.append("paste")
        }

        @objc func cutAction(_ sender: Any?) {
            _ = sender
            actions.append("cut")
        }

        @objc func selectAllAction(_ sender: Any?) {
            _ = sender
            actions.append("selectAll")
        }

    }

    private final class TerminalProbeView: GhosttyNSView {
        private(set) var menuMissEvents: [NSEvent] = []
        private(set) var performKeyEquivalentEvents: [NSEvent] = []
        private(set) var copyActionCount = 0
        var performAfterMenuMissResult = true
        var consumeUnavailableCopyResult = false
        var simulatesCopyableSelection = false

        override func consumeUnavailableCopyMenuAction(_ event: NSEvent) -> Bool {
            _ = event
            return consumeUnavailableCopyResult
        }

        override func performKeyEquivalentAfterMenuMiss(with event: NSEvent) -> Bool {
            menuMissEvents.append(event)
            if simulatesCopyableSelection,
               KeyboardLayout.normalizedCharacters(for: event) == "c" {
                copy(nil)
                return true
            }
            return performAfterMenuMissResult
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            performKeyEquivalentEvents.append(event)
            return NSApp.mainMenu?.performKeyEquivalent(with: event) == true
        }

        override func copy(_ sender: Any?) {
            _ = sender
            copyActionCount += 1
        }
    }

    private final class FocusProbeView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    @Test
    func focusedTerminalRoutesCopyBeforeMenuButPasteUsesMenuTransaction() throws {
        let menuProbe = MenuActionProbe()
        let (window, terminal, previousMenu) = try makeWindowWithTerminal(
            menuProbe: menuProbe,
            menuItems: [
                ("Copy", "c", [.command], #selector(MenuActionProbe.copyAction(_:))),
                ("Paste", "v", [.command], #selector(MenuActionProbe.pasteAction(_:))),
                (
                    "Paste and Match Style",
                    "v",
                    [.command, .shift],
                    #selector(MenuActionProbe.pasteAction(_:))
                ),
            ]
        )
        defer { tearDown(window: window, previousMenu: previousMenu) }

        let copyEvent = try #require(makeKeyDownEvent(
            key: "c",
            keyCode: UInt16(kVK_ANSI_C),
            windowNumber: window.windowNumber
        ))
        let pasteEvent = try #require(makeKeyDownEvent(
            key: "v",
            keyCode: UInt16(kVK_ANSI_V),
            windowNumber: window.windowNumber
        ))
        let shiftedPasteEvent = try #require(makeKeyDownEvent(
            key: "v",
            keyCode: UInt16(kVK_ANSI_V),
            modifierFlags: [.command, .shift],
            windowNumber: window.windowNumber
        ))

        #expect(window.performKeyEquivalent(with: copyEvent))
        #expect(window.performKeyEquivalent(with: pasteEvent))
        #expect(window.performKeyEquivalent(with: shiftedPasteEvent))
        #expect(terminal.menuMissEvents.map { KeyboardLayout.normalizedCharacters(for: $0) } == ["c"])
        #expect(terminal.performKeyEquivalentEvents.map { KeyboardLayout.normalizedCharacters(for: $0) } == ["v", "v"])
        #expect(menuProbe.actions == ["paste", "paste"])
    }

    @Test
    func focusedTerminalCopyWithSelectionStillUsesTerminalCopyAction() throws {
        let menuProbe = MenuActionProbe()
        let (window, terminal, previousMenu) = try makeWindowWithTerminal(
            menuProbe: menuProbe,
            menuItems: [
                ("Copy", "c", [.command], #selector(MenuActionProbe.copyAction(_:))),
            ]
        )
        terminal.simulatesCopyableSelection = true
        defer { tearDown(window: window, previousMenu: previousMenu) }

        let event = try #require(makeKeyDownEvent(
            key: "c",
            keyCode: UInt16(kVK_ANSI_C),
            windowNumber: window.windowNumber
        ))

        #expect(window.performKeyEquivalent(with: event))
        #expect(terminal.copyActionCount == 1)
        #expect(menuProbe.actions.isEmpty)
    }

    @Test
    func terminalDecliningEditEquivalentFallsThroughToMenu() throws {
        let menuProbe = MenuActionProbe()
        let (window, terminal, previousMenu) = try makeWindowWithTerminal(
            menuProbe: menuProbe,
            menuItems: [
                ("Copy", "c", [.command], #selector(MenuActionProbe.copyAction(_:))),
                ("Paste", "v", [.command], #selector(MenuActionProbe.pasteAction(_:))),
            ]
        )
        terminal.performAfterMenuMissResult = false
        defer { tearDown(window: window, previousMenu: previousMenu) }

        let events = try [
            makeKeyDownEvent(key: "c", keyCode: UInt16(kVK_ANSI_C), windowNumber: window.windowNumber),
            makeKeyDownEvent(key: "v", keyCode: UInt16(kVK_ANSI_V), windowNumber: window.windowNumber),
        ].map { try #require($0) }

        for event in events {
            #expect(window.performKeyEquivalent(with: event))
        }

        #expect(terminal.menuMissEvents.map { KeyboardLayout.normalizedCharacters(for: $0) } == ["c"])
        #expect(menuProbe.actions == ["copy", "paste"])
    }

    @Test
    func focusedTerminalGetsOtherEditEquivalentsBeforeMenu() throws {
        let menuProbe = MenuActionProbe()
        let (window, terminal, previousMenu) = try makeWindowWithTerminal(
            menuProbe: menuProbe,
            menuItems: [
                ("Cut", "x", [.command], #selector(MenuActionProbe.cutAction(_:))),
                ("Select All", "a", [.command], #selector(MenuActionProbe.selectAllAction(_:))),
            ]
        )
        defer { tearDown(window: window, previousMenu: previousMenu) }

        let events = try [
            makeKeyDownEvent(key: "x", keyCode: UInt16(kVK_ANSI_X), windowNumber: window.windowNumber),
            makeKeyDownEvent(key: "a", keyCode: UInt16(kVK_ANSI_A), windowNumber: window.windowNumber),
        ].map { try #require($0) }

        for event in events {
            #expect(window.performKeyEquivalent(with: event))
        }

        #expect(terminal.menuMissEvents.map { KeyboardLayout.normalizedCharacters(for: $0) } == ["x", "a"])
        #expect(menuProbe.actions.isEmpty)
    }

    @Test
    func nonTerminalResponderRetainsEditMenuDispatch() throws {
        let menuProbe = MenuActionProbe()
        let (window, _, previousMenu) = try makeWindowWithTerminal(
            menuProbe: menuProbe,
            menuItems: [
                ("Copy", "c", [.command], #selector(MenuActionProbe.copyAction(_:))),
                ("Paste", "v", [.command], #selector(MenuActionProbe.pasteAction(_:))),
            ],
            firstResponder: FocusProbeView(frame: NSRect(x: 0, y: 0, width: 64, height: 32))
        )
        defer { tearDown(window: window, previousMenu: previousMenu) }

        let events = try [
            makeKeyDownEvent(key: "c", keyCode: UInt16(kVK_ANSI_C), windowNumber: window.windowNumber),
            makeKeyDownEvent(key: "v", keyCode: UInt16(kVK_ANSI_V), windowNumber: window.windowNumber),
        ].map { try #require($0) }

        for event in events {
            #expect(window.performKeyEquivalent(with: event))
        }

        #expect(menuProbe.actions == ["copy", "paste"])
    }

    private typealias MenuItemSpec = (title: String, key: String, modifiers: NSEvent.ModifierFlags, action: Selector)

    private func makeWindowWithTerminal(
        menuProbe: MenuActionProbe,
        menuItems: [MenuItemSpec],
        firstResponder: NSView? = nil
    ) throws -> (NSWindow, TerminalProbeView, NSMenu?) {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let terminal = TerminalProbeView(frame: NSRect(x: 0, y: 0, width: 128, height: 64))
        container.addSubview(terminal)
        if let firstResponder {
            container.addSubview(firstResponder)
            #expect(window.makeFirstResponder(firstResponder))
        } else {
            #expect(window.makeFirstResponder(terminal))
        }

        let previousMenu = NSApp.mainMenu
        let mainMenu = NSMenu(title: "Main")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        for spec in menuItems {
            let item = NSMenuItem(title: spec.title, action: spec.action, keyEquivalent: spec.key)
            item.keyEquivalentModifierMask = spec.modifiers
            item.target = menuProbe
            editMenu.addItem(item)
        }
        mainMenu.addItem(editItem)
        mainMenu.setSubmenu(editMenu, for: editItem)
        NSApp.mainMenu = mainMenu

        window.makeKeyAndOrderFront(nil)
        return (window, terminal, previousMenu)
    }

    private func makeKeyDownEvent(
        key: String,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = [.command],
        windowNumber: Int
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func tearDown(window: NSWindow, previousMenu: NSMenu?) {
        NSApp.mainMenu = previousMenu
        window.orderOut(nil)
        window.close()
    }
}
