import AppKit
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
/// Unlike Ghostty's `clear_screen` (⌘K), which erases scrollback too, this action
/// feeds ED mode 22 (`ESC [ 22 J`) so the visible screen scrolls into scrollback
/// and the active area is cleared while all history is preserved. The test drives a
/// real Ghostty surface running a controlled program, fills the active screen and
/// the scrollback with unique markers, performs the clear, and asserts the active
/// area was cleared while every marker survives in the full screen + scrollback.
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
    func clearScreenKeepScrollbackClearsActiveScreenButPreservesScrollback() throws {
        let uid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        // Distinct, collision-proof markers: A is scrolled up into scrollback, B is
        // left on the active (visible) screen before the clear.
        let scrollbackMarker = "CMUXSCROLLBACK\(uid)"
        let activeMarker = "CMUXACTIVE\(uid)"

        // Run a controlled program (not the login shell) so the screen contents are
        // deterministic: print A, scroll it well past the active area with blank
        // lines, print B on the active screen, then block on stdin via `cat` so the
        // child stays alive (clearing requires a live, non-exited process).
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-clear-keep-scrollback-\(uid).sh")
        let script = """
        printf '%s\\n' '\(scrollbackMarker)'
        i=0
        while [ $i -lt 80 ]; do printf '\\n'; i=$((i+1)); done
        printf '%s\\n' '\(activeMarker)'
        exec cat
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let hosted = try makeHostedTerminalWindow(
            initialCommand: "/bin/sh \(shellSingleQuoted(scriptURL.path))"
        )
        defer { hosted.window.orderOut(nil) }

        // Headless CI runners can fail to initialize a Metal-backed Ghostty surface.
        // Without a live surface there is nothing to clear or read, so skip the
        // byte-level assertions there (mirrors GhosttyDECCKMArrowKeyTests).
        guard hosted.surface.hasLiveSurface else { return }

        // Wait until the program has printed both markers (B implies the run reached
        // the active screen and scrolled A into history).
        let beforeScreen = try waitForTerminalText(from: hosted, pointTag: GHOSTTY_POINT_SCREEN) {
            $0.contains(scrollbackMarker) && $0.contains(activeMarker)
        }
        try #require(beforeScreen.contains(scrollbackMarker))
        try #require(beforeScreen.contains(activeMarker))

        let beforeActive = try readTerminalText(from: hosted, pointTag: GHOSTTY_POINT_ACTIVE)
        #expect(
            beforeActive.contains(activeMarker),
            "active marker must be on the visible screen before clearing"
        )
        #expect(
            !beforeActive.contains(scrollbackMarker),
            "scrollback marker must already be in history (not the active area) before clearing"
        )

        // Perform the keep-scrollback clear (ED mode 22 via process-output + Ctrl-L).
        #expect(
            hosted.surface.clearScreenKeepingScrollback(),
            "keep-scrollback clear should reach the live surface"
        )

        // ESC[22J is applied synchronously by the PTY-output parser, so read back
        // immediately. The Ctrl-L prompt redraw is delivered to the PTY asynchronously
        // and does not affect scrollback, so it cannot perturb these assertions.
        let afterActive = try readTerminalText(from: hosted, pointTag: GHOSTTY_POINT_ACTIVE)
        let afterScreen = try readTerminalText(from: hosted, pointTag: GHOSTTY_POINT_SCREEN)

        #expect(
            !afterActive.contains(activeMarker),
            "the active screen must be cleared by the keep-scrollback clear"
        )
        #expect(
            afterScreen.contains(activeMarker),
            "the just-cleared screen contents must be scrolled into scrollback, not erased"
        )
        #expect(
            afterScreen.contains(scrollbackMarker),
            "pre-existing scrollback must be preserved by the keep-scrollback clear"
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
        pointTag: ghostty_point_tag_e
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
        pointTag: ghostty_point_tag_e,
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
}
