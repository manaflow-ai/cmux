import AppKit
import Foundation
import Testing
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct GhosttyDECCKMArrowKeyTests {
    private struct HostedTerminalWindow {
        let surface: TerminalSurface
        let window: NSWindow
        let hostedView: GhosttySurfaceScrollView
        let surfaceView: GhosttyNSView
    }

    @Test
    func windowKeyEquivalentTerminalArrowsEncodeDECCKMBytes() throws {
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let captureReadyMarker = "CMUX_DECCKM_READY_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let captureMarker = "CMUX_DECCKM_HEX_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-decckm-arrow-capture-\(UUID().uuidString).py")
        let script = """
        import os
        import select
        import sys
        import termios
        import time
        import tty

        fd = 0
        sys.stdout.write("\\x1b[?1h\(captureReadyMarker)\\n")
        sys.stdout.flush()
        old = termios.tcgetattr(fd)
        try:
            tty.setraw(fd)
            data = bytearray()
            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline and len(data) < 12:
                if select.select([sys.stdin], [], [], 0.05)[0]:
                    data.extend(os.read(fd, 64))
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
        let surfaceView = hostedTerminal.surfaceView
        defer { window.orderOut(nil) }

        // Headless CI runners can fail to initialize a Metal-backed Ghostty
        // surface. In that environment the predicate tests below still cover
        // the routing decision; this byte-level integration path needs a live
        // surface to poll terminal text.
        guard hostedTerminal.surface.hasLiveSurface else { return }

        #expect(window.makeFirstResponder(surfaceView), "Expected terminal surface to own first responder")

        let readyText = try waitForTerminalText(from: hostedTerminal) {
            $0.contains(captureReadyMarker)
        }
        #expect(readyText.contains(captureReadyMarker), "Expected DECCKM capture harness to become ready")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let arrows: [(name: String, characters: String, keyCode: UInt16)] = [
            ("up", String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
            ("down", String(UnicodeScalar(NSDownArrowFunctionKey)!), 125),
            ("right", String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
            ("left", String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123),
        ]
        let timestamp = ProcessInfo.processInfo.systemUptime

        try withExtendedLifetime(hostedTerminal.surface) {
            for (index, arrow) in arrows.enumerated() {
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [.numericPad, .function],
                    timestamp: timestamp + (Double(index) * 0.001),
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: arrow.characters,
                    charactersIgnoringModifiers: arrow.characters,
                    isARepeat: false,
                    keyCode: arrow.keyCode
                ))

                #expect(
                    window.performKeyEquivalent(with: event),
                    "Terminal \(arrow.name) arrow should be consumed by direct keyDown routing"
                )
            }
        }

        let captureText = try waitForTerminalText(from: hostedTerminal, timeout: 5) {
            $0.contains(captureMarker)
        }
        let markerRange = try #require(captureText.range(of: "\(captureMarker)="))
        let hexCharacters = Set("0123456789abcdefABCDEF")
        let capturedHex = captureText[markerRange.upperBound...]
            .prefix { hexCharacters.contains($0) }

        #expect(
            String(capturedHex) == "1b4f411b4f421b4f431b4f44",
            "Terminal arrows in DECCKM must reach the PTY as application cursor sequences, not a bare Escape or missing keyDown"
        )
    }

    @Test(arguments: [123, 124, 125, 126] as [UInt16])
    func terminalArrowPredicateAcceptsUnmodifiedTerminalArrows(keyCode: UInt16) {
        #expect(shouldDispatchTerminalArrowViaFirstResponderKeyDown(
            keyCode: keyCode,
            firstResponderIsTerminal: true,
            flags: [.numericPad, .function]
        ))
    }

    @Test
    func terminalArrowPredicateRequiresTerminalContext() {
        #expect(!shouldDispatchTerminalArrowViaFirstResponderKeyDown(
            keyCode: 126,
            firstResponderIsTerminal: false,
            flags: [.numericPad, .function]
        ))
    }

    @Test
    func terminalArrowPredicateLeavesMarkedTextAndCommandArrowsAlone() {
        #expect(!shouldDispatchTerminalArrowViaFirstResponderKeyDown(
            keyCode: 126,
            firstResponderIsTerminal: true,
            firstResponderHasMarkedText: true,
            flags: [.numericPad, .function]
        ))
        #expect(!shouldDispatchTerminalArrowViaFirstResponderKeyDown(
            keyCode: 126,
            firstResponderIsTerminal: true,
            flags: [.command, .numericPad, .function]
        ))
    }

    @Test
    func terminalArrowPredicateRejectsNonArrowKeys() {
        #expect(!shouldDispatchTerminalArrowViaFirstResponderKeyDown(
            keyCode: 36,
            firstResponderIsTerminal: true,
            flags: [.numericPad, .function]
        ))
    }

    @Test(arguments: ["legacy", "kitty", "kitty-events", "kitty-all", "modifyOtherKeys"], [false, true])
    func negotiatedKeyboardBytes(protocolName: String, physicalInput: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let negotiation: String
            let expected: String
            let arrows = "\u{1B}[A\u{1B}[B\u{1B}[D\u{1B}[C"
            switch protocolName {
            case "kitty":
                negotiation = "\u{1B}[>1u"
                expected = arrows + "\r\u{1B}[99;5u"
            case "kitty-events":
                negotiation = "\u{1B}[>3u"
                expected = "\u{1B}[A\u{1B}[1;1:3A\u{1B}[B\u{1B}[1;1:3B"
                    + "\u{1B}[D\u{1B}[1;1:3D\u{1B}[C\u{1B}[1;1:3C\r"
                    + "\u{1B}[99;5u\u{1B}[99;5:3u"
            case "kitty-all":
                negotiation = "\u{1B}[>9u"
                expected = arrows + "\u{1B}[13u\u{1B}[99;5u"
            case "modifyOtherKeys":
                negotiation = "\u{1B}[>4;2m"
                expected = arrows + "\r\u{1B}[27;5;99~"
            default:
                negotiation = ""
                expected = arrows + "\r\u{03}"
            }

            let scriptURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-key-protocol-\(UUID().uuidString).py")
            let readyURL = scriptURL.appendingPathExtension("ready")
            let captureURL = scriptURL.appendingPathExtension("capture")
            defer {
                for url in [scriptURL, readyURL, captureURL, scriptURL.appendingPathExtension("pending")] {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            let script = """
            import os, select, termios, time, tty
            from pathlib import Path
            old = termios.tcgetattr(0)
            try:
                tty.setraw(0)
                Path(__file__ + ".ready").write_text("ready")
                data = bytearray()
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if select.select([0], [], [], 0.2 if data else 0.05)[0]:
                        data.extend(os.read(0, 4096))
                    elif data:
                        break
                pending = Path(__file__ + ".pending")
                pending.write_bytes(data)
                pending.replace(__file__ + ".capture")
            finally:
                termios.tcsetattr(0, termios.TCSADRAIN, old)
            """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let terminal = try makeHostedTerminalWindow(
                initialCommand: "/usr/bin/python3 \(shellSingleQuoted(scriptURL.path))"
            )
            defer { terminal.window.orderOut(nil) }
            let ready = await AppKitTestEventPump().waitUntil(timeout: .seconds(5)) {
                FileManager.default.fileExists(atPath: readyURL.path)
            }
            try #require(ready, "Expected the PTY reader to enter raw mode")
            let runtime = try #require(terminal.surface.surface)
            // Parse negotiation synchronously: a child-ready file alone does not
            // prove Ghostty has consumed terminal output on its IO thread.
            let output = "\u{1B}[?1l\u{1B}[>m\u{1B}[<8u" + negotiation
            output.withCString { ghostty_surface_process_output(runtime, $0, UInt(output.utf8.count)) }

            let keys: [(String, String, String, UInt16, NSEvent.ModifierFlags)] = [
                ("up", String(UnicodeScalar(NSUpArrowFunctionKey)!), String(UnicodeScalar(NSUpArrowFunctionKey)!), 126, []),
                ("down", String(UnicodeScalar(NSDownArrowFunctionKey)!), String(UnicodeScalar(NSDownArrowFunctionKey)!), 125, []),
                ("left", String(UnicodeScalar(NSLeftArrowFunctionKey)!), String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123, []),
                ("right", String(UnicodeScalar(NSRightArrowFunctionKey)!), String(UnicodeScalar(NSRightArrowFunctionKey)!), 124, []),
                ("enter", "\r", "\r", 36, []),
                ("ctrl-c", "\u{03}", "c", 8, [.control]),
            ]
            for (name, characters, unmodified, code, mods) in keys {
                if physicalInput {
                    #expect(terminal.hostedView.debugSendSyntheticKeyPressAndReleaseForUITest(
                        characters: characters,
                        charactersIgnoringModifiers: unmodified,
                        keyCode: code,
                        modifierFlags: mods
                    ))
                } else {
                    #expect(terminal.surface.sendNamedKey(name).accepted)
                }
            }
            let captured = await AppKitTestEventPump().waitUntil(timeout: .seconds(6)) {
                FileManager.default.fileExists(atPath: captureURL.path)
            }
            try #require(captured, "Expected the child to publish captured PTY bytes")
            let bytes = try Data(contentsOf: captureURL)
            #expect(bytes == Data(expected.utf8), "\(protocolName), physical=\(physicalInput): \(bytes as NSData)")
        }
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
        let runtimeSurface = try #require(terminal.surface.surface)
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
}
