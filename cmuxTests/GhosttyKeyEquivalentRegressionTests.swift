import XCTest
import AppKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class GhosttyKeyEquivalentRegressionTests: XCTestCase {
    private struct PasteboardItemSnapshot {
        let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private struct HostedTerminalWindow {
        let surface: TerminalSurface
        let window: NSWindow
        let hostedView: GhosttySurfaceScrollView
        let surfaceView: GhosttyNSView
    }

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

        let contentView = try XCTUnwrap(window.contentView)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let surfaceView = try XCTUnwrap(findGhosttyNSView(in: hostedView))
        return HostedTerminalWindow(
            surface: surface,
            window: window,
            hostedView: hostedView,
            surfaceView: surfaceView
        )
    }

    private func readTerminalText(from terminal: HostedTerminalWindow) throws -> String {
        let runtimeSurface = try XCTUnwrap(terminal.surface.surface)
        let topLeft = ghostty_point_s(
            tag: GHOSTTY_POINT_SURFACE,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: GHOSTTY_POINT_SURFACE,
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

    private func cmuxZshTerminalKeyboardResetSequence() throws -> Data {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let integrationPath = repoRoot
            .appendingPathComponent("Resources/shell-integration/cmux-zsh-integration.zsh")
            .path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-f",
            "-c",
            """
            source \(shellSingleQuoted(integrationPath)) >/dev/null 2>&1 || true
            if (( $+functions[_cmux_reset_terminal_keyboard_protocols] )); then
              _cmux_reset_terminal_keyboard_protocols
            fi
            """
        ]
        process.environment = [
            "CMUX_TEST_FORCE_KEYBOARD_RESET": "1"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()
        return output.fileHandleForReading.readDataToEndOfFile()
    }

    private func processTerminalOutput(_ data: Data, in terminal: HostedTerminalWindow) throws {
        guard !data.isEmpty else { return }
        let runtimeSurface = try XCTUnwrap(terminal.surface.surface)
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_process_output(runtimeSurface, baseAddress, UInt(rawBuffer.count))
        }
    }

    private func snapshotPasteboardItems(_ pasteboard: NSPasteboard) -> [PasteboardItemSnapshot] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            let representations = item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
            return PasteboardItemSnapshot(representations: representations)
        }
    }

    private func restorePasteboardItems(
        _ snapshots: [PasteboardItemSnapshot],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        guard !snapshots.isEmpty else { return }
        let items = snapshots.compactMap { snapshot -> NSPasteboardItem? in
            let item = NSPasteboardItem()
            guard !snapshot.representations.isEmpty else { return nil }
            for representation in snapshot.representations {
                item.setData(representation.data, forType: representation.type)
            }
            return item
        }
        if !items.isEmpty {
            _ = pasteboard.writeObjects(items)
        }
    }

    private func installUnrelatedMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let item = NSMenuItem(title: "New", action: nil, keyEquivalent: "n")
        item.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(item)
        mainMenu.addItem(fileItem)
        mainMenu.setSubmenu(fileMenu, for: fileItem)
        return mainMenu
    }

    func testShiftSlashPrintableKeyEquivalentBypassesShortcutPath() throws {
        let hostedTerminal = try makeHostedTerminalWindow()
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        defer { window.orderOut(nil) }

        window.makeFirstResponder(surfaceView)
        XCTAssertNotNil(surfaceView.terminalSurface)

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "/",
            charactersIgnoringModifiers: "/",
            isARepeat: false,
            keyCode: 26 // ABC-QWERTZ Shift+7
        ) else {
            XCTFail("Failed to construct Shift+/ event")
            return
        }

        withExtendedLifetime(hostedTerminal.surface) {
            XCTAssertFalse(
                window.performKeyEquivalent(with: event),
                "Printable Shift+/ should continue through keyDown instead of being consumed as a key equivalent"
            )
        }
    }

    func testShiftQuestionMarkPrintableKeyEquivalentBypassesShortcutPath() throws {
        let hostedTerminal = try makeHostedTerminalWindow()
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        defer { window.orderOut(nil) }

        window.makeFirstResponder(surfaceView)
        XCTAssertNotNil(surfaceView.terminalSurface)

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "?",
            charactersIgnoringModifiers: "?",
            isARepeat: false,
            keyCode: 27 // ABC-QWERTZ Shift+-
        ) else {
            XCTFail("Failed to construct Shift+? event")
            return
        }

        withExtendedLifetime(hostedTerminal.surface) {
            XCTAssertFalse(
                window.performKeyEquivalent(with: event),
                "Printable Shift+? should continue through keyDown instead of being consumed as a key equivalent"
            )
        }
    }

    func testStaleKittyKeyboardAfterClearHistoryDoesNotEncodePlainLetterAsCSIU() throws {
        let captureReadyMarker = "CMUX_KBD_READY_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let captureMarker = "CMUX_KBD_HEX_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-kbd-capture-\(UUID().uuidString).py")
        let script = """
        import os
        import select
        import sys
        import termios
        import time
        import tty

        fd = 0
        sys.stdout.write("\\x1b[>3u\(captureReadyMarker)\\n")
        sys.stdout.flush()
        old = termios.tcgetattr(fd)
        try:
            tty.setraw(fd)
            data = bytearray()
            if select.select([sys.stdin], [], [], 2.0)[0]:
                data.extend(os.read(fd, 1))
                deadline = time.monotonic() + 1.0
                idle_deadline = time.monotonic() + 0.35
                while time.monotonic() < deadline and time.monotonic() < idle_deadline:
                    if select.select([sys.stdin], [], [], 0.05)[0]:
                        data.extend(os.read(fd, 64))
                        idle_deadline = time.monotonic() + 0.35
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)

        print("\\r\\n\(captureMarker)=" + data.hex(), flush=True)
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let hostedTerminal = try makeHostedTerminalWindow(
            initialCommand: "/usr/bin/python3 \(shellSingleQuoted(scriptURL.path))"
        )
        let window = hostedTerminal.window
        defer { window.orderOut(nil) }

        let readyText = try waitForTerminalText(from: hostedTerminal) {
            $0.contains(captureReadyMarker)
        }
        XCTAssertTrue(readyText.contains(captureReadyMarker), "Expected Kitty enable marker before clear-history")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let keyboardResetData = try cmuxZshTerminalKeyboardResetSequence()
        XCTAssertEqual(
            keyboardResetData,
            Data("\u{1B}[>m\u{1B}[<8u".utf8),
            "cmuxZshTerminalKeyboardResetSequence must reset modifyOtherKeys and Kitty keyboard state"
        )
        try processTerminalOutput(keyboardResetData, in: hostedTerminal)

        // Mirrors the surface.clear_history socket handler path: clear_screen binding, then refresh.
        XCTAssertTrue(hostedTerminal.surface.performBindingAction("clear_screen"))
        hostedTerminal.surface.forceRefresh(reason: "unit.clearHistory")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let sent = hostedTerminal.hostedView.debugSendSyntheticKeyPressAndReleaseForUITest(
            characters: "c",
            charactersIgnoringModifiers: "c",
            keyCode: 8
        )
        XCTAssertTrue(sent, "Expected ordinary c keyDown to be dispatched through ghostty_surface_key")

        let captureText = try waitForTerminalText(from: hostedTerminal, timeout: 5) {
            $0.contains(captureMarker)
        }
        guard let markerRange = captureText.range(of: "\(captureMarker)=") else {
            XCTFail("Expected raw PTY byte capture marker in terminal output: \(captureText)")
            return
        }
        let hexCharacters = Set("0123456789abcdefABCDEF")
        let capturedHex = captureText[markerRange.upperBound...]
            .prefix { hexCharacters.contains($0) }

        XCTAssertEqual(
            String(capturedHex),
            "63",
            "A plain c at the shell prompt must write one ASCII byte to PTY input, not a Kitty CSI-u sequence"
        )
        XCTAssertFalse(
            captureText.contains("c9;1:3u") || captureText.contains("99;1:3u"),
            "CSI-u response bodies must not land in terminal output as printable text"
        )
    }

    // MARK: - Terminal Paste Fallback

    func testCommandVPasteStillInvokesTerminalPasteWhenMainMenuMisses() throws {
        installGhosttyPasteActionSwizzle()

        let hostedTerminal = try makeHostedTerminalWindow()
        let terminalSurface = hostedTerminal.surface
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        defer { window.orderOut(nil) }

        window.makeFirstResponder(surfaceView)
        XCTAssertNotNil(surfaceView.terminalSurface)

        let previousMainMenu = NSApp.mainMenu
        NSApp.mainMenu = installUnrelatedMainMenu()
        defer { NSApp.mainMenu = previousMainMenu }

        let pasteboard = NSPasteboard.general
        let pasteboardSnapshot = snapshotPasteboardItems(pasteboard)
        defer { restorePasteboardItems(pasteboardSnapshot, to: pasteboard) }
        pasteboard.clearContents()
        pasteboard.setString("opencode paste", forType: .string)

        var pasteInvocationCount = 0
        let previousPasteHook = ghosttyPasteActionHook
        ghosttyPasteActionHook = { candidateView, sender in
            previousPasteHook?(candidateView, sender)
            guard candidateView === surfaceView else { return }
            pasteInvocationCount += 1
        }
        defer { ghosttyPasteActionHook = previousPasteHook }

        var forwardedCommandVCount = 0
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS, keyEvent.keycode == 9 else { return }
            forwardedCommandVCount += 1
        }
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
        }

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ) else {
            XCTFail("Failed to construct Cmd+V event")
            return
        }

        withExtendedLifetime(terminalSurface) {
            XCTAssertTrue(window.performKeyEquivalent(with: event))
            XCTAssertEqual(
                pasteInvocationCount,
                1,
                "Cmd+V should still invoke the terminal paste action even if the window main-menu fast path misses"
            )
            XCTAssertEqual(
                forwardedCommandVCount,
                0,
                "Cmd+V should not fall back to Ghostty keyDown when the terminal paste action is available"
            )
        }
    }

    func testCommandShiftVPasteAsPlainTextStillInvokesTerminalFallbackWhenMainMenuMisses() throws {
        installGhosttyPasteActionSwizzle()

        let hostedTerminal = try makeHostedTerminalWindow()
        let terminalSurface = hostedTerminal.surface
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        defer { window.orderOut(nil) }

        window.makeFirstResponder(surfaceView)
        XCTAssertNotNil(surfaceView.terminalSurface)

        let previousMainMenu = NSApp.mainMenu
        NSApp.mainMenu = installUnrelatedMainMenu()
        defer { NSApp.mainMenu = previousMainMenu }

        let pasteboard = NSPasteboard.general
        let pasteboardSnapshot = snapshotPasteboardItems(pasteboard)
        defer { restorePasteboardItems(pasteboardSnapshot, to: pasteboard) }
        pasteboard.clearContents()
        pasteboard.setString("opencode paste plain text", forType: .string)

        var pasteInvocationCount = 0
        let previousPasteHook = ghosttyPasteActionHook
        ghosttyPasteActionHook = { candidateView, sender in
            previousPasteHook?(candidateView, sender)
            guard candidateView === surfaceView else { return }
            pasteInvocationCount += 1
        }
        defer { ghosttyPasteActionHook = previousPasteHook }

        var pasteAsPlainTextInvocationCount = 0
        let previousPasteAsPlainTextHook = ghosttyPasteAsPlainTextActionHook
        ghosttyPasteAsPlainTextActionHook = { candidateView, sender in
            previousPasteAsPlainTextHook?(candidateView, sender)
            guard candidateView === surfaceView else { return }
            pasteAsPlainTextInvocationCount += 1
        }
        defer { ghosttyPasteAsPlainTextActionHook = previousPasteAsPlainTextHook }

        var forwardedCommandVCount = 0
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS, keyEvent.keycode == 9 else { return }
            forwardedCommandVCount += 1
        }
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
        }

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "V",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ) else {
            XCTFail("Failed to construct Cmd+Shift+V event")
            return
        }

        withExtendedLifetime(terminalSurface) {
            XCTAssertTrue(window.performKeyEquivalent(with: event))
            XCTAssertEqual(
                pasteInvocationCount,
                0,
                "Cmd+Shift+V should route through pasteAsPlainText instead of the regular terminal paste action"
            )
            XCTAssertEqual(
                pasteAsPlainTextInvocationCount,
                1,
                "Cmd+Shift+V should still invoke the terminal pasteAsPlainText action even if the window main-menu fast path misses"
            )
            XCTAssertEqual(
                forwardedCommandVCount,
                0,
                "Cmd+Shift+V should not fall back to Ghostty keyDown when the terminal plain-text paste action is available"
            )
        }
    }

    func testCommandVPasteRecreatesReleasedSurfaceBeforeConsumption() throws {
        installGhosttyPasteActionSwizzle()

        let hostedTerminal = try makeHostedTerminalWindow()
        let terminalSurface = hostedTerminal.surface
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        defer { window.orderOut(nil) }

        window.makeFirstResponder(surfaceView)
        XCTAssertNotNil(surfaceView.terminalSurface)
        XCTAssertNotNil(terminalSurface.surface)

        let previousMainMenu = NSApp.mainMenu
        NSApp.mainMenu = installUnrelatedMainMenu()
        defer { NSApp.mainMenu = previousMainMenu }

        let pasteboard = NSPasteboard.general
        let pasteboardSnapshot = snapshotPasteboardItems(pasteboard)
        defer { restorePasteboardItems(pasteboardSnapshot, to: pasteboard) }
        pasteboard.clearContents()
        pasteboard.setString("surface recovery paste", forType: .string)

        var pasteInvocationCount = 0
        let previousPasteHook = ghosttyPasteActionHook
        ghosttyPasteActionHook = { candidateView, sender in
            previousPasteHook?(candidateView, sender)
            guard candidateView === surfaceView else { return }
            pasteInvocationCount += 1
        }
        defer { ghosttyPasteActionHook = previousPasteHook }

        var forwardedCommandVCount = 0
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS, keyEvent.keycode == 9 else { return }
            forwardedCommandVCount += 1
        }
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
        }

        terminalSurface.releaseSurfaceForTesting()
        XCTAssertNil(
            terminalSurface.surface,
            "Expected the runtime Ghostty surface to be released before simulating Cmd+V"
        )

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ) else {
            XCTFail("Failed to construct Cmd+V event")
            return
        }

        withExtendedLifetime(terminalSurface) {
            XCTAssertTrue(window.performKeyEquivalent(with: event))
            XCTAssertEqual(
                pasteInvocationCount,
                1,
                "Cmd+V should still invoke the terminal paste action after a transient surface release"
            )
            XCTAssertEqual(
                forwardedCommandVCount,
                0,
                "Cmd+V should recover the Ghostty surface without falling back to keyDown"
            )
            XCTAssertNotNil(
                terminalSurface.surface,
                "Cmd+V should recreate the Ghostty surface before the direct terminal paste fallback consumes the shortcut"
            )
        }
    }
}

