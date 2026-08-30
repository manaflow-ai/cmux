import AppKit
import CmuxTerminal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Terminal color-scheme protocol", .serialized)
struct TerminalColorSchemeProtocolTests {
    private final class ManualWriteCapture: @unchecked Sendable {
        // Ghostty invokes the manual-I/O callback off the main actor; this lock
        // guards every access to the shared values before bypassing Sendable checks.
        private let lock = NSLock()
        private var values: [Data] = []

        deinit {}

        func append(_ input: TerminalManualInput) {
            guard case let .bytes(data) = input else { return }
            lock.lock()
            values.append(data)
            lock.unlock()
        }

        var snapshot: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private struct HostedTerminal {
        let surface: TerminalSurface
        let window: NSWindow
        let outputURL: URL
        let scriptURL: URL
    }

    @Test("CSI 996 reports the effective dark and light schemes")
    func queryReportsEffectiveColorScheme() throws {
        let terminal = try makeHostedTerminal()
        defer { tearDown(terminal) }
        let runtimeSurface = try #require(terminal.surface.surface)

        ghostty_surface_set_color_scheme(runtimeSurface, GHOSTTY_COLOR_SCHEME_DARK)
        try sendProbe("query-dark", to: terminal)
        #expect(try waitForReport("query-dark=1b5b3f3939373b316e", from: terminal))

        ghostty_surface_set_color_scheme(runtimeSurface, GHOSTTY_COLOR_SCHEME_LIGHT)
        try sendProbe("query-light", to: terminal)
        #expect(try waitForReport("query-light=1b5b3f3939373b326e", from: terminal))
    }

    @Test("Mode 2031 reports appearance transitions and stops after reset")
    func mode2031ReportsOnlyWhileEnabled() throws {
        let terminal = try makeHostedTerminal()
        defer { tearDown(terminal) }
        let runtimeSurface = try #require(terminal.surface.surface)

        ghostty_surface_set_color_scheme(runtimeSurface, GHOSTTY_COLOR_SCHEME_DARK)
        try sendProbe("enable", to: terminal)
        #expect(try waitForReport("initial=1b5b3f3939373b316e", from: terminal))
        #expect(try waitForReport("enable-status=ready", from: terminal))

        try sendProbe("await-transition", to: terminal)
        #expect(try waitForReport("await-transition=ready", from: terminal))
        ghostty_surface_set_color_scheme(runtimeSurface, GHOSTTY_COLOR_SCHEME_LIGHT)
        #expect(try waitForReport("transition=1b5b3f3939373b326e", from: terminal))

        try sendProbe("disable", to: terminal)
        #expect(try waitForReport("disable-status=ready", from: terminal))
        try sendProbe("await-disabled-transition", to: terminal)
        #expect(try waitForReport("await-disabled-transition=ready", from: terminal))
        ghostty_surface_set_color_scheme(runtimeSurface, GHOSTTY_COLOR_SCHEME_DARK)
        #expect(try waitForReport("disabled=none", from: terminal))
    }

    @Test("Protocol responses stay on the requesting terminal PTY")
    func responsesDoNotLeakToSiblingTerminal() throws {
        let first = try makeHostedTerminal()
        let second = try makeHostedTerminal()
        defer {
            tearDown(first)
            tearDown(second)
        }
        _ = try #require(first.surface.surface)
        _ = try #require(second.surface.surface)

        ghostty_surface_set_color_scheme(try #require(first.surface.surface), GHOSTTY_COLOR_SCHEME_DARK)
        try sendProbe("first", to: first)
        #expect(try waitForReport("first=1b5b3f3939373b316e", from: first))
        try sendProbe("enable", to: first)
        #expect(try waitForReport("initial=1b5b3f3939373b316e", from: first))
        #expect(try waitForReport("enable-status=ready", from: first))
        try sendProbe("await-transition", to: first)
        #expect(try waitForReport("await-transition=ready", from: first))
        ghostty_surface_set_color_scheme(try #require(first.surface.surface), GHOSTTY_COLOR_SCHEME_LIGHT)
        #expect(try waitForReport("transition=1b5b3f3939373b326e", from: first))
        let secondLines = try String(contentsOf: second.outputURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        #expect(secondLines == ["ready"])
    }

    @Test("Manual-mirror surfaces suppress parser protocol responses")
    func manualMirrorSuppressesParserResponses() throws {
        let writes = ManualWriteCapture()
        let terminal = try makeHostedTerminal(
            ioMode: .manualMirror,
            manualInputHandler: { input in writes.append(input) }
        )
        defer { tearDown(terminal) }
        let runtimeSurface = try #require(terminal.surface.surface)

        processOutput("\u{1b}[?996n\u{1b}[?2031h", on: runtimeSurface)
        ghostty_surface_set_color_scheme(runtimeSurface, GHOSTTY_COLOR_SCHEME_LIGHT)
        processOutput("\u{1b}[?2031l", on: runtimeSurface)

        #expect(
            writes.snapshot.isEmpty,
            "A manual-mirror surface must not duplicate parser replies owned by its remote terminal core"
        )
    }

    private func makeHostedTerminal(
        ioMode: TerminalSurfaceIOMode = .exec,
        manualInputHandler: (@Sendable (TerminalManualInput) -> Void)? = nil
    ) throws -> HostedTerminal {
        _ = NSApplication.shared
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-color-scheme-protocol-\(UUID().uuidString).txt")
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-color-scheme-protocol-\(UUID().uuidString).py")
        let script = """
        import os
        import select
        import sys
        import termios
        import time
        import tty

        output_path = sys.argv[1]
        fd = 0
        old = termios.tcgetattr(fd)
        tty.setraw(fd)

        def read_report(timeout):
            data = bytearray()
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if select.select([fd], [], [], 0.02)[0]:
                    data.extend(os.read(fd, 64))
                    if data.endswith(b'n'):
                        break
            return data.hex() if data else 'none'

        def read_until(expected, timeout):
            data = bytearray()
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if select.select([fd], [], [], 0.02)[0]:
                    chunk = os.read(fd, 64)
                    if not chunk:
                        break
                    data.extend(chunk)
                    if expected in data:
                        return True
            return False

        def record(value):
            with open(output_path, 'a', encoding='utf-8') as handle:
                handle.write(value + '\\n')
                handle.flush()
        record('ready')

        try:
            for command in sys.stdin:
                command = command.strip()
                if command.startswith('query-') or command == 'first':
                    os.write(fd, b'\\x1b[?996n')
                    record(command + '=' + read_report(1.0))
                elif command == 'enable':
                    os.write(fd, b'\\x1b[?2031h')
                    record('initial=' + read_report(1.0))
                    os.write(fd, b'\\x1b[?2031$p')
                    enabled = read_until(b'\\x1b[?2031;1$y', 1.0)
                    record('enable-status=' + ('ready' if enabled else 'none'))
                elif command == 'await-transition':
                    record('await-transition=ready')
                    record('transition=' + read_report(2.0))
                elif command == 'disable':
                    os.write(fd, b'\\x1b[?2031l')
                    os.write(fd, b'\\x1b[?2031$p')
                    disabled = read_until(b'\\x1b[?2031;2$y', 1.0)
                    record('disable-status=' + ('ready' if disabled else 'none'))
                elif command == 'await-disabled-transition':
                    record('await-disabled-transition=ready')
                    record('disabled=' + read_report(0.35))
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
        """
        var hostedTerminal: HostedTerminal?
        defer {
            if let hostedTerminal {
                tearDown(hostedTerminal)
            } else {
                try? FileManager.default.removeItem(at: outputURL)
                try? FileManager.default.removeItem(at: scriptURL)
            }
        }

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try Data().write(to: outputURL)

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            initialCommand: ioMode == .exec
                ? "/usr/bin/python3 \(shellSingleQuoted(scriptURL.path)) \(shellSingleQuoted(outputURL.path))"
                : nil,
            ioMode: ioMode,
            manualInputHandler: manualInputHandler
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
        let terminal = HostedTerminal(
            surface: surface,
            window: window,
            outputURL: outputURL,
            scriptURL: scriptURL
        )
        hostedTerminal = terminal
        if ioMode == .exec {
            guard try waitForReport("ready", from: terminal) else {
                Issue.record("Terminal color-scheme probe did not become ready")
                throw ProbeError.notReady
            }
        } else {
            guard waitForLiveSurface(surface) else {
                Issue.record("Manual-mirror Ghostty surface did not become live")
                throw ProbeError.notReady
            }
        }
        hostedTerminal = nil
        return terminal
    }

    private func sendProbe(_ command: String, to terminal: HostedTerminal) throws {
        let runtimeSurface = try #require(terminal.surface.surface)
        "\(command)\n".withCString { bytes in
            ghostty_surface_text(runtimeSurface, bytes, UInt(strlen(bytes)))
        }
    }

    private func waitForReport(_ report: String, from terminal: HostedTerminal) throws -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            let output = try String(contentsOf: terminal.outputURL, encoding: .utf8)
            if output.split(whereSeparator: \.isNewline).contains(Substring(report)) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return false
    }

    private func waitForLiveSurface(_ surface: TerminalSurface, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if surface.hasLiveSurface { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return surface.hasLiveSurface
    }

    private func processOutput(_ value: String, on surface: ghostty_surface_t) {
        Data(value.utf8).withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return
            }
            ghostty_surface_process_output(surface, baseAddress, UInt(rawBuffer.count))
        }
    }

    private func tearDown(_ terminal: HostedTerminal) {
        terminal.window.contentView = nil
        terminal.window.close()
        terminal.surface.releaseSurfaceForTesting()
        try? FileManager.default.removeItem(at: terminal.outputURL)
        try? FileManager.default.removeItem(at: terminal.scriptURL)
    }

    private enum ProbeError: Error {
        case notReady
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
