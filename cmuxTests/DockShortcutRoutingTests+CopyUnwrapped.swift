import AppKit
import CmuxBrowser
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension DockShortcutRoutingTests {
    @Test("Copy Unwrapped reaches the focused Dock terminal responder")
    @MainActor
    func copyUnwrappedReachesFocusedDockTerminal() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let contentView = try #require(harness.window.contentView)
                let terminal = CopyUnwrappedRecordingTerminal(frame: contentView.bounds)
                contentView.addSubview(terminal)
                defer { terminal.removeFromSuperview() }
                #expect(harness.window.makeFirstResponder(terminal))
                harness.appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .dock, in: harness.window)
                #expect(Self.dispatch(KeyboardShortcutSettings.Action.copyUnwrapped.defaultShortcut, in: harness))
                #expect(terminal.copyCount == 1)
                // Responder-owned actions must bypass Dock command dispatch.
                #expect(harness.appDelegate.focusedDockStoreForShortcut(
                    action: .copyUnwrapped, preferredWindow: harness.window
                ) == nil)
            }
        }
    }

    @Test("Copy Unwrapped declines browser focus so the page can receive the key")
    @MainActor
    func copyUnwrappedPassesThroughFocusedBrowser() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let panelID = try #require(harness.dock.newSurface(
                    kind: .browser, inPane: harness.rootPane, focus: true
                ))
                let browser = try #require(harness.dock.browserPanel(for: panelID))
                harness.window.contentView?.addSubview(browser.webView)
                defer { browser.webView.removeFromSuperview() }
                #expect(harness.window.makeFirstResponder(browser.webView))
                let event = try #require(Self.event(
                    KeyboardShortcutSettings.Action.copyUnwrapped.defaultShortcut, in: harness
                ))
                #expect(!harness.appDelegate.handleCopyUnwrappedShortcut(event))
                #expect(!Self.dispatch(KeyboardShortcutSettings.Action.copyUnwrapped.defaultShortcut, in: harness))
            }
        }
    }

    @Test("Persisted copy mode keeps Command Shift C in runtime and menu lookup")
    @MainActor
    func explicitCopyModeBindingOutranksCopyUnwrappedInRuntime() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { _ in
                let copy = KeyboardShortcutSettings.Action.copyUnwrapped
                let copyMode = KeyboardShortcutSettings.Action.toggleTerminalCopyMode
                let commandShiftC = copy.defaultShortcut
                #expect(KeyboardShortcutSettings.shortcut(for: copy) == commandShiftC)
                // The preset stored only copy mode before Copy Unwrapped existed.
                UserDefaults.standard.set(try JSONEncoder().encode(commandShiftC), forKey: copyMode.defaultsKey)
                defer { UserDefaults.standard.removeObject(forKey: copyMode.defaultsKey) }
                #expect(KeyboardShortcutSettings.shortcut(for: copyMode) == commandShiftC)
                #expect(KeyboardShortcutSettings.shortcut(for: copy).isUnbound)
                #expect(KeyboardShortcutSettings.menuShortcut(for: copy).isUnbound)
            }
        }
    }
}

@MainActor
private final class CopyUnwrappedRecordingTerminal: GhosttyNSView {
    private(set) var copyCount = 0
    override func copyUnwrapped(_ sender: Any?) { copyCount += 1 }
}
