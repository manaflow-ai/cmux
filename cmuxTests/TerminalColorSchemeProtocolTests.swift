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
    private static let fixtureReadinessTimeout: TimeInterval = 15

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
        let commandURL: URL
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
        defer { tearDown(first) }
        let second = try makeHostedTerminal()
        defer { tearDown(second) }
        let firstSurface = try #require(first.surface.surface)
        _ = try #require(second.surface.surface)

        ghostty_surface_set_color_scheme(firstSurface, GHOSTTY_COLOR_SCHEME_DARK)
        try sendProbe("first", to: first)
        #expect(try waitForReport("first=1b5b3f3939373b316e", from: first))
        try sendProbe("enable", to: first)
        #expect(try waitForReport("initial=1b5b3f3939373b316e", from: first))
        #expect(try waitForReport("enable-status=ready", from: first))
        try sendProbe("await-transition", to: first)
        #expect(try waitForReport("await-transition=ready", from: first))
        ghostty_surface_set_color_scheme(firstSurface, GHOSTTY_COLOR_SCHEME_LIGHT)
        #expect(try waitForReport("transition=1b5b3f3939373b326e", from: first))
        let secondLines = try String(contentsOf: second.outputURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        #expect(secondLines == ["ready"])
    }

    @Test("Manual-mirror surfaces suppress parser protocol responses")
    func manualMirrorSuppressesParserResponses() throws {
        let normalWrites = ManualWriteCapture()
        let normal = try makeHostedTerminal(
            ioMode: .manual,
            manualInputHandler: { input in normalWrites.append(input) }
        )
        defer { tearDown(normal) }

        let mirrorWrites = ManualWriteCapture()
        let mirror = try makeHostedTerminal(
            ioMode: .manualMirror,
            manualInputHandler: { input in mirrorWrites.append(input) }
        )
        defer { tearDown(mirror) }
        let normalSurface = try #require(normal.surface.surface)
        let mirrorSurface = try #require(mirror.surface.surface)

        ghostty_surface_set_color_scheme(normalSurface, GHOSTTY_COLOR_SCHEME_LIGHT)
        ghostty_surface_set_color_scheme(mirrorSurface, GHOSTTY_COLOR_SCHEME_LIGHT)
        let protocolInput = "\u{1b}[?996n\u{1b}[?2031h"
        processOutput(protocolInput, on: normalSurface)
        processOutput(protocolInput, on: mirrorSurface)

        #expect(
            normalWrites.snapshot.contains { $0 == Data("\u{1b}[?997;2n".utf8) },
            "A normal manual surface must emit parser replies through its embedder callback"
        )
        #expect(
            mirrorWrites.snapshot.isEmpty,
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
        let commandURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-color-scheme-protocol-\(UUID().uuidString).commands")
        let script = """
        import os
        import select
        import sys
        import termios
        import time
        import tty

        output_path = sys.argv[1]
        command_path = sys.argv[2]
        fd = 0
        old = termios.tcgetattr(fd)
        tty.setraw(fd)

        def read_report(timeout):
            data = bytearray()
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if not select.select([fd], [], [], 0.02)[0]:
                    continue
                chunk = os.read(fd, 64)
                if not chunk:
                    return data.hex() if data else 'none'
                data.extend(chunk)
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
                        return False
                    data.extend(chunk)
                    if expected in data:
                        return True
            return False

        command_index = 0

        def read_command():
            global command_index
            while True:
                try:
                    with open(command_path, 'r', encoding='utf-8') as handle:
                        commands = handle.readlines()
                except FileNotFoundError:
                    commands = []
                if command_index < len(commands):
                    command = commands[command_index].strip()
                    command_index += 1
                    return command
                time.sleep(0.02)

        def record(value):
            with open(output_path, 'a', encoding='utf-8') as handle:
                handle.write(value + '\\n')
                handle.flush()
        record('ready')

        try:
            while True:
                command = read_command()
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
        var surfaceForCleanup: TerminalSurface?
        var windowForCleanup: NSWindow?
        var hostedTerminal: HostedTerminal?
        defer {
            if let hostedTerminal {
                tearDown(hostedTerminal)
            } else {
                windowForCleanup?.contentView = nil
                windowForCleanup?.close()
                surfaceForCleanup?.releaseSurfaceForTesting()
                try? FileManager.default.removeItem(at: outputURL)
                try? FileManager.default.removeItem(at: scriptURL)
                try? FileManager.default.removeItem(at: commandURL)
            }
        }

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try Data().write(to: outputURL)
        try Data().write(to: commandURL)

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            initialCommand: ioMode == .exec
                ? "/usr/bin/python3 \(shellSingleQuoted(scriptURL.path)) \(shellSingleQuoted(outputURL.path)) \(shellSingleQuoted(commandURL.path))"
                : nil,
            ioMode: ioMode,
            manualInputHandler: manualInputHandler,
            dependencies: protocolTestRuntimeDependencies()
        )
        surfaceForCleanup = surface
        let hostedView = surface.hostedView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        windowForCleanup = window
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
            scriptURL: scriptURL,
            commandURL: commandURL
        )
        hostedTerminal = terminal
        if ioMode == .exec {
            guard try waitForReport(
                "ready",
                from: terminal,
                timeout: Self.fixtureReadinessTimeout
            ) else {
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
        surfaceForCleanup = nil
        windowForCleanup = nil
        return terminal
    }

    private func sendProbe(_ command: String, to terminal: HostedTerminal) throws {
        let existing = (try? Data(contentsOf: terminal.commandURL)) ?? Data()
        let next = existing + Data("\(command)\n".utf8)
        try next.write(to: terminal.commandURL, options: .atomic)
    }

    private func waitForReport(
        _ report: String,
        from terminal: HostedTerminal,
        timeout: TimeInterval = 3
    ) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let output = try String(contentsOf: terminal.outputURL, encoding: .utf8)
            if output.split(whereSeparator: \.isNewline).contains(Substring(report)) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return false
    }

    private func waitForLiveSurface(
        _ surface: TerminalSurface,
        timeout: TimeInterval = Self.fixtureReadinessTimeout
    ) -> Bool {
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
        try? FileManager.default.removeItem(at: terminal.commandURL)
    }

    private enum ProbeError: Error {
        case notReady
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func protocolTestRuntimeDependencies() -> TerminalSurfaceRuntimeDependencies {
        let live = GhosttyApp.terminalSurfaceRuntimeDependencies
        let filesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimTemporaryDirectory:
                live.runtimeFilesystem.agentCommandShimTemporaryDirectory,
            installAgentCommandShims: { _, _, _ in nil },
            isExecutableFile: live.runtimeFilesystem.isExecutableFile
        )
        return TerminalSurfaceRuntimeDependencies(
            registry: live.registry,
            engine: live.engine,
            viewProvider: live.viewProvider,
            spawnPolicy: live.spawnPolicy,
            byteTee: live.byteTee,
            rendererRealization: live.rendererRealization,
            hibernationRecorder: live.hibernationRecorder,
            runtimeTeardown: live.runtimeTeardown,
            restoreSpawnScheduler: live.restoreSpawnScheduler,
            runtimeFilesystem: filesystem,
            agentCommandShimInstallDeadline: .zero,
            agentCommandShimInstallDeadlineClock:
                live.agentCommandShimInstallDeadlineClock,
            sessionPortBase: live.sessionPortBase,
            sessionPortRangeSize: live.sessionPortRangeSize,
            scrollbackReplayEnvironmentKey:
                live.scrollbackReplayEnvironmentKey,
            globalFontMagnificationPercent:
                live.globalFontMagnificationPercent
        )
    }
}
