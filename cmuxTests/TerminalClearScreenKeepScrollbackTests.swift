import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior coverage for the "Clear Screen (Keep Scrollback)" action
/// (`TerminalSurface.clearScreenKeepingScrollback()`, default ⌘⇧K).
///
/// Unlike Ghostty's `clear_screen` (⌘K), which also erases scrollback, this action
/// clears the visible screen while keeping history. It does so by delivering Ctrl-L
/// (form-feed, `0x0c`) to the running program as ordinary keyboard input — never by
/// injecting an erase sequence behind the program's back — so it is safe inside
/// full-screen TUIs and lets the shell + Ghostty's native `^L` handling preserve
/// scrollback. The test drives a real Ghostty surface running a controlled program
/// that captures raw PTY input and asserts the form-feed byte is what reaches it.
@MainActor
@Suite
struct TerminalClearScreenKeepScrollbackTests {
    private struct HostedTerminalWindow {
        let surface: TerminalSurface
        let window: NSWindow
        let hostedView: GhosttySurfaceScrollView
        let surfaceView: GhosttyNSView
    }

    @Test
    func remappedDefaultShortcutDoesNotTriggerStaleMenuSuppression() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let event = try #require(makeKeyDownEvent(
            key: "k",
            modifiers: [.command, .shift],
            keyCode: UInt16(kVK_ANSI_K),
            windowNumber: 0
        ))

        withTemporaryShortcut(action: .clearScreenKeepScrollback, shortcut: .unbound) {
            #expect(!appDelegate.shouldSuppressStaleCmuxMenuShortcut(event: event))
        }
    }

    @Test
    func clearScreenKeepScrollbackDeliversFormFeedToForegroundProgram() throws {
        let readyMarker = "CMUX_CLEAR_READY_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let captureMarker = "CMUX_CLEAR_HEX_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        // A controlled program (not the login shell) that puts the PTY in raw mode and
        // echoes whatever bytes it receives as hex. Ctrl-L must arrive as the single
        // form-feed byte 0x0c, exactly as a real keypress would deliver it.
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-clear-keep-scrollback-\(UUID().uuidString).py")
        let script = """
        import os
        import select
        import sys
        import termios
        import time
        import tty

        fd = 0
        old = termios.tcgetattr(fd)
        try:
            tty.setraw(fd)
            # Announce readiness only after raw mode is active, so the test never
            # races the PTY mode change when it delivers Ctrl-L.
            sys.stdout.write("\\r\\n\(readyMarker)\\r\\n")
            sys.stdout.flush()
            data = bytearray()
            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline and len(data) < 4:
                if select.select([sys.stdin], [], [], 0.05)[0]:
                    data.extend(os.read(fd, 16))
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)

        print("\\r\\n\(captureMarker)=" + data.hex(), flush=True)
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let hosted = try makeHostedTerminalWindow(
            initialCommand: "/usr/bin/python3 \(shellSingleQuoted(scriptURL.path))"
        )
        defer { hosted.window.orderOut(nil) }

        // Headless CI runners can fail to initialize a Metal-backed Ghostty surface.
        // Without a live surface there is nothing to deliver input to, so skip the
        // byte-level assertion there (mirrors GhosttyDECCKMArrowKeyTests).
        guard hosted.surface.hasLiveSurface else { return }

        // The harness prints its marker only after entering raw mode, so seeing it
        // means Ctrl-L will be delivered as a raw byte — no timing delay needed.
        let readyText = try waitForTerminalText(from: hosted) { $0.contains(readyMarker) }
        #expect(readyText.contains(readyMarker), "capture harness should become ready")

        #expect(
            hosted.surface.clearScreenKeepingScrollback(),
            "keep-scrollback clear should deliver the keystroke to the live surface"
        )

        let captureText = try waitForTerminalText(from: hosted, timeout: 5) {
            $0.contains(captureMarker)
        }
        let markerRange = try #require(captureText.range(of: "\(captureMarker)="))
        let hexCharacters = Set("0123456789abcdefABCDEF")
        let capturedHex = String(captureText[markerRange.upperBound...].prefix { hexCharacters.contains($0) })

        #expect(
            capturedHex == "0c",
            "Clear Screen (Keep Scrollback) must deliver a single Ctrl-L form-feed (0x0c), not an erase sequence injected behind the program's back; got \(capturedHex)"
        )
    }

    // MARK: - Harness

    private func makeHostedTerminalWindow(initialCommand: String? = nil) throws -> HostedTerminalWindow {
        _ = NSApplication.shared

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil,
            initialCommand: initialCommand
        )
        let hostedView = surface.hostedView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        let contentView = try #require(window.contentView)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        return HostedTerminalWindow(
            surface: surface,
            window: window,
            hostedView: hostedView,
            surfaceView: try #require(findGhosttyNSView(in: hostedView))
        )
    }

    private func readTerminalText(from terminal: HostedTerminalWindow) throws -> String {
        _ = try #require(terminal.surface.surface)
        return terminal.surface.readTextRawSnapshot(includeScrollback: true)?.history ?? ""
    }

    private func waitForTerminalText(
        from terminal: HostedTerminalWindow,
        timeout: TimeInterval = 5,
        matching predicate: (String) -> Bool
    ) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = try readTerminalText(from: terminal)
        while Date() < deadline {
            if predicate(latest) { return latest }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            latest = try readTerminalText(from: terminal)
        }
        return latest
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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

    private func withTemporaryShortcut(
        action: KeyboardShortcutSettings.Action,
        shortcut: StoredShortcut? = nil,
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
        KeyboardShortcutSettings.setShortcut(shortcut ?? action.defaultShortcut, for: action)
        body()
    }
}
