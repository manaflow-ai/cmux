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

    @Test
    func claudeShimClearsPromptMarkedPrimaryScreenBeforeRedraw() throws {
        let oldToken = "CMUX_CLAUDE_CLEAR_OLD_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let newToken = "CMUX_CLAUDE_CLEAR_NEW_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let doneMarker = "CMUX_CLAUDE_CLEAR_DONE_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-clear-\(UUID().uuidString)", isDirectory: true)
        let bundleBin = root
            .appendingPathComponent("cmux.app", isDirectory: true)
            .appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        let tempRoot = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let wrapperURL = bundleBin.appendingPathComponent("cmux-claude-wrapper", isDirectory: false)
        try #"""
        #!/usr/bin/env bash
        set -euo pipefail
        if [[ "${1:-}" == "__cmux-should-prepare-terminal-for-tui" ]]; then
            exit 0
        fi
        # Paint Claude's first TUI frame WITHOUT clearing the screen. The only
        # thing that can erase the stale prompt-marked rows the runner painted is
        # the shim's pre-clear; if that regresses, the OLD rows survive and the
        # oldToken assertion below fails.
        printf 'NEW \#(newToken)\r\n\#(doneMarker)\r\n'
        sleep 1
        """#.write(to: wrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapperURL.path)

        let shim = try #require(
            TerminalSurface.installClaudeCommandShimIfPossible(
                wrapperURL: wrapperURL,
                surfaceId: UUID(),
                temporaryDirectory: tempRoot
            ))

        let runnerURL = root.appendingPathComponent("run-claude-clear-repro.sh", isDirectory: false)
        try #"""
        #!/usr/bin/env bash
        set -euo pipefail
        # The shim's clear path is gated on CMUX_SURFACE_ID. Runtime surface
        # creation exports it in production (TerminalSurface+StartupEnvironment);
        # set it here too so the regression test drives the shim clear
        # deterministically instead of depending on spawn-env details.
        export CMUX_SURFACE_ID='cmux-claude-clear-regression'
        # Paint stale prompt-marked content across the primary screen: the
        # pre-Claude state the shim must clear before the TUI paints. Rows 1-4
        # carry oldToken; the last row adds OSC 133 prompt marks like a real
        # shell prompt with a typed `claude` invocation.
        printf '\033[H'
        printf 'OLD \#(oldToken) row 1\r\n'
        printf 'OLD \#(oldToken) row 2\r\n'
        printf 'OLD \#(oldToken) row 3\r\n'
        printf 'OLD \#(oldToken) row 4\r\n'
        printf '\033]133;A;redraw=last;cl=line\a'
        printf 'OLD \#(oldToken) cmux-test-prompt claude'
        printf '\033]133;B\a'
        printf '\033]133;C\a'
        printf '\r\n'
        exec \#(shellSingleQuoted(shim.executablePath))
        """#.write(to: runnerURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runnerURL.path)

        let hosted = try makeHostedTerminalWindow(
            initialCommand: "/bin/bash \(shellSingleQuoted(runnerURL.path))"
        )
        defer { hosted.window.orderOut(nil) }

        guard hosted.surface.hasLiveSurface else { return }

        let screenText = try waitForTerminalText(
            from: hosted,
            pointTag: GHOSTTY_POINT_SCREEN,
            timeout: 5
        ) { $0.contains(doneMarker) }

        #expect(screenText.contains(newToken), "Claude redraw should produce the new frame")
        #expect(
            !screenText.contains(oldToken),
            "Claude launch must clear prompt-marked primary-screen rows before the TUI paints; otherwise a later clear scrolls the stale frame into the screen buffer"
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

    private func readTerminalText(
        from terminal: HostedTerminalWindow,
        pointTag: ghostty_point_tag_e = GHOSTTY_POINT_SURFACE
    ) throws -> String {
        let runtimeSurface = try #require(terminal.surface.surface)
        let topLeft = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(runtimeSurface, selection, &text) else {
            return ""
        }
        defer { ghostty_surface_free_text(runtimeSurface, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return "" }
        let data = Data(bytes: ptr, count: Int(text.text_len))
        return String(decoding: data, as: UTF8.self)
    }

    private func waitForTerminalText(
        from terminal: HostedTerminalWindow,
        pointTag: ghostty_point_tag_e = GHOSTTY_POINT_SURFACE,
        timeout: TimeInterval = 5,
        matching predicate: (String) -> Bool
    ) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = try readTerminalText(from: terminal, pointTag: pointTag)
        while Date() < deadline {
            if predicate(latest) { return latest }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            latest = try readTerminalText(from: terminal, pointTag: pointTag)
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
