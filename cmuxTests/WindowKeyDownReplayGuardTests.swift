import AppKit
import Carbon.HIToolbox
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5887.
///
/// `NSWindow.cmux_performKeyEquivalent(with:)` force-dispatches certain key
/// events straight into the focused responder's `keyDown(with:)`. When the
/// responder does not consume the key, AppKit can route the very same event
/// back into `performKeyEquivalent` while the first dispatch is still on the
/// stack (WebKit replays unhandled keys through the responder chain, and on
/// macOS 26 `-[NSWindow keyDown:]` re-enters `performKeyEquivalent`). Without
/// a replay guard at the dispatch chokepoint the event ping-pongs forever and
/// overflows the main-thread stack.
@MainActor
@Suite(.serialized)
struct WindowKeyDownReplayGuardTests {

    /// First responder stub that models the re-entrant AppKit behavior: an
    /// unhandled keyDown flows back into `NSWindow.performKeyEquivalent` with
    /// the exact same event while the original dispatch is still on the stack.
    /// Bounded so the pre-fix failure mode is a clean assertion failure
    /// instead of a stack overflow.
    private final class ReplayingKeyDownView: NSView {
        private(set) var keyDownEvents: [NSEvent] = []
        var replaysRemaining = 5

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            keyDownEvents.append(event)
            guard replaysRemaining > 0 else { return }
            replaysRemaining -= 1
            _ = window?.performKeyEquivalent(with: event)
        }
    }

    private final class TerminalCommandEquivalentProbeView: GhosttyNSView {
        private(set) var afterMenuMissEvents: [NSEvent] = []
        private(set) var keyDownEvents: [NSEvent] = []
        var performAfterMenuMissResult = true

        override func performKeyEquivalentAfterMenuMiss(with event: NSEvent) -> Bool {
            afterMenuMissEvents.append(event)
            return performAfterMenuMissResult
        }

        override func keyDown(with event: NSEvent) {
            keyDownEvents.append(event)
        }
    }

    private final class EditableUndoProbeTextView: NSTextView {
        private(set) var undoCallCount = 0

        @objc func undo(_ sender: Any?) {
            undoCallCount += 1
        }
    }

    private final class MenuActionProbe: NSObject {
        private(set) var callCount = 0

        @objc func perform(_ sender: Any?) {
            callCount += 1
        }
    }

    private func makeWindowWithReplayingResponder() -> (NSWindow, ReplayingKeyDownView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let responder = ReplayingKeyDownView(frame: NSRect(x: 0, y: 0, width: 64, height: 32))
        container.addSubview(responder)
        #expect(window.makeFirstResponder(responder))
        return (window, responder)
    }

    private func makeWindowWithTerminalResponder() -> (NSWindow, TerminalCommandEquivalentProbeView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let terminal = TerminalCommandEquivalentProbeView(frame: NSRect(x: 0, y: 0, width: 64, height: 32))
        container.addSubview(terminal)
        #expect(window.makeFirstResponder(terminal))
        return (window, terminal)
    }

    private func makeWindowWithTerminalHostedEditableResponder()
        -> (NSWindow, TerminalCommandEquivalentProbeView, EditableUndoProbeTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let terminal = TerminalCommandEquivalentProbeView(frame: NSRect(x: 0, y: 0, width: 128, height: 64))
        let textView = EditableUndoProbeTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        textView.isEditable = true
        terminal.addSubview(textView)
        container.addSubview(terminal)
        #expect(window.makeFirstResponder(textView))
        return (window, terminal, textView)
    }

    private func makeCommandZKeyDownEvent(
        modifiers: NSEvent.ModifierFlags,
        windowNumber: Int
    ) -> NSEvent? {
        let characters = modifiers.contains(.shift) ? "Z" : "z"
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: "z",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_Z)
        )
    }

    private func installUndoMenu(probe: MenuActionProbe) -> NSMenu? {
        let previousMenu = NSApp.mainMenu
        let menu = NSMenu(title: "Main")
        let undoItem = NSMenuItem(
            title: "Undo",
            action: #selector(MenuActionProbe.perform(_:)),
            keyEquivalent: "z"
        )
        undoItem.keyEquivalentModifierMask = [.command]
        undoItem.target = probe
        menu.addItem(undoItem)

        let redoItem = NSMenuItem(
            title: "Redo",
            action: #selector(MenuActionProbe.perform(_:)),
            keyEquivalent: "Z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        redoItem.target = probe
        menu.addItem(redoItem)

        NSApp.mainMenu = menu
        return previousMenu
    }

    private func installResponderChainUndoMenu() -> NSMenu? {
        let previousMenu = NSApp.mainMenu
        let menu = NSMenu(title: "Main")
        let undoItem = NSMenuItem(
            title: "Undo",
            action: #selector(EditableUndoProbeTextView.undo(_:)),
            keyEquivalent: "z"
        )
        undoItem.keyEquivalentModifierMask = [.command]
        menu.addItem(undoItem)
        NSApp.mainMenu = menu
        return previousMenu
    }

    /// Option+A producing printable text ("å"). The printable-Option-text
    /// bypass in `cmux_performKeyEquivalent` force-dispatches this into the
    /// first responder's `keyDown`, which is the unguarded dispatch the
    /// https://github.com/manaflow-ai/cmux/issues/5887 crash looped through.
    private func makeOptionTextKeyDownEvent(
        windowNumber: Int,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            characters: "å",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )
    }

    @Test
    func printableOptionTextKeyDownIsForceDispatchedExactlyOncePerEvent() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let (window, responder) = makeWindowWithReplayingResponder()
        guard let event = makeOptionTextKeyDownEvent(windowNumber: window.windowNumber) else {
            Issue.record("Failed to construct Option+A key event")
            return
        }

        #expect(window.performKeyEquivalent(with: event))
        #expect(
            responder.keyDownEvents.count == 1,
            Comment(rawValue: "The same in-flight key event must not be force-dispatched into keyDown again while the first dispatch is still on the stack; unbounded re-dispatch is the infinite key-routing loop from https://github.com/manaflow-ai/cmux/issues/5887")
        )
    }

    @Test
    func distinctKeyDownEventsAreEachForceDispatched() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let (window, responder) = makeWindowWithReplayingResponder()
        responder.replaysRemaining = 0

        let baseTimestamp = ProcessInfo.processInfo.systemUptime
        guard
            let first = makeOptionTextKeyDownEvent(
                windowNumber: window.windowNumber,
                timestamp: baseTimestamp
            ),
            let second = makeOptionTextKeyDownEvent(
                windowNumber: window.windowNumber,
                timestamp: baseTimestamp + 0.05
            )
        else {
            Issue.record("Failed to construct Option+A key events")
            return
        }

        // Distinct events (key autorepeat, repeat typing) must each be
        // force-dispatched; the replay guard is per-event, not a throttle.
        #expect(window.performKeyEquivalent(with: first))
        #expect(window.performKeyEquivalent(with: second))
        #expect(responder.keyDownEvents.count == 2)
    }

    @Test
    func sameEventIsForceDispatchedAgainAfterPriorDispatchUnwinds() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let (window, responder) = makeWindowWithReplayingResponder()
        responder.replaysRemaining = 0

        guard let event = makeOptionTextKeyDownEvent(windowNumber: window.windowNumber) else {
            Issue.record("Failed to construct Option+A key event")
            return
        }

        // WebKit legitimately re-sends an unhandled key event through
        // NSApp.sendEvent after the original dispatch has fully unwound. The
        // guard is stack-scoped, so the same event must dispatch again here.
        #expect(window.performKeyEquivalent(with: event))
        #expect(window.performKeyEquivalent(with: event))
        #expect(responder.keyDownEvents.count == 2)
    }

    @Test
    func terminalUndoRedoCommandEquivalentsBypassAppKitUndoMenu() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let probe = MenuActionProbe()
        let previousMenu = installUndoMenu(probe: probe)
        defer { NSApp.mainMenu = previousMenu }

        let (window, terminal) = makeWindowWithTerminalResponder()
        defer {
            window.orderOut(nil)
            window.close()
        }

        for modifiers in [[.command], [.command, .shift]] as [NSEvent.ModifierFlags] {
            guard let event = makeCommandZKeyDownEvent(modifiers: modifiers, windowNumber: window.windowNumber) else {
                Issue.record("Failed to construct Undo/Redo key event")
                return
            }

            #expect(window.performKeyEquivalent(with: event))
        }

        #expect(
            probe.callCount == 0,
            Comment(rawValue: "Terminal-focused Cmd+Z/Cmd+Shift+Z must not invoke AppKit menu Undo/Redo; that path can dispatch a stale NSUndoManager target and crash in _NSUndoStack.popAndInvoke")
        )
        #expect(
            terminal.afterMenuMissEvents.map { $0.charactersIgnoringModifiers } == ["z", "z"],
            "Undo/Redo command equivalents should be routed to the terminal shortcut path instead"
        )
    }

    @Test
    func terminalHostedEditableResponderKeepsLocalUndo() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let previousMenu = installResponderChainUndoMenu()
        defer { NSApp.mainMenu = previousMenu }

        let (window, terminal, textView) = makeWindowWithTerminalHostedEditableResponder()
        defer {
            window.orderOut(nil)
            window.close()
        }

        guard let event = makeCommandZKeyDownEvent(modifiers: [.command], windowNumber: window.windowNumber) else {
            Issue.record("Failed to construct Undo key event")
            return
        }

        #expect(window.performKeyEquivalent(with: event))
        #expect(textView.undoCallCount == 1)
        #expect(terminal.afterMenuMissEvents.isEmpty)
    }

    @Test
    func terminalDeclinedUndoCommandFallsBackToTerminalKeyDownWithoutLocalUndo() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let previousMenu = installResponderChainUndoMenu()
        defer { NSApp.mainMenu = previousMenu }

        let (window, terminal, textView) = makeWindowWithTerminalHostedEditableResponder()
        defer {
            window.orderOut(nil)
            window.close()
        }
        terminal.performAfterMenuMissResult = false
        #expect(window.makeFirstResponder(terminal))

        guard let event = makeCommandZKeyDownEvent(modifiers: [.command], windowNumber: window.windowNumber) else {
            Issue.record("Failed to construct Undo key event")
            return
        }

        #expect(window.performKeyEquivalent(with: event))
        #expect(terminal.afterMenuMissEvents.map { $0.charactersIgnoringModifiers } == ["z"])
        #expect(terminal.keyDownEvents.map { $0.charactersIgnoringModifiers } == ["z"])
        #expect(textView.undoCallCount == 0)
    }
}
