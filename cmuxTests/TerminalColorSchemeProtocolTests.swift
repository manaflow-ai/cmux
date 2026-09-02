import AppKit
@testable import CmuxTerminal
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
        let previousAppearanceMode: String?
        let previousApplicationAppearance: NSAppearance?
    }
    @Test("CSI 996 reports the effective dark and light schemes")
    func queryReportsEffectiveColorScheme() throws {
        let terminal = try makeHostedTerminal()
        defer { tearDown(terminal) }
        _ = try #require(terminal.surface.surface)
        try setAppearance(.dark, terminals: [terminal])
        try sendProbe("query-dark", to: terminal)
        #expect(try waitForReport("query-dark=1b5b3f3939373b316e", from: terminal))
        try setAppearance(.light, terminals: [terminal])
        try sendProbe("query-light", to: terminal)
        #expect(try waitForReport("query-light=1b5b3f3939373b326e", from: terminal))
    }
    @Test("Mode 2031 reports appearance transitions and stops after reset")
    func mode2031ReportsOnlyWhileEnabled() throws {
        let terminal = try makeHostedTerminal()
        defer { tearDown(terminal) }
        _ = try #require(terminal.surface.surface)
        try setAppearance(.dark, terminals: [terminal])
        try sendProbe("barrier-dark", to: terminal)
        #expect(try waitForReport("barrier=1b5b3f3939373b316e", from: terminal))
        #expect(try waitForReport("barrier-reports=1b5b3f3939373b316e", from: terminal))
        try sendProbe("enable", to: terminal)
        #expect(try waitForReport("initial=1b5b3f3939373b316e", from: terminal))
        #expect(try waitForReport("enable-status=ready", from: terminal))
        try sendProbe("await-transition", to: terminal)
        #expect(try waitForReport("await-transition=ready", from: terminal))
        try setAppearance(.light, terminals: [terminal])
        #expect(try waitForReport("transition=1b5b3f3939373b326e", from: terminal))
        #expect(try waitForReport("transition-reports=1b5b3f3939373b326e", from: terminal))
        try sendProbe("disable", to: terminal)
        #expect(try waitForReport("disable-status=ready", from: terminal))
        try sendProbe("await-disabled-transition", to: terminal)
        #expect(try waitForReport("await-disabled-transition=ready", from: terminal))
        try setAppearance(.dark, terminals: [terminal])
        #expect(try waitForReport("disabled=none", from: terminal))
        try sendProbe("enable", to: terminal)
        #expect(try waitForReport("initial=1b5b3f3939373b316e", from: terminal))
        #expect(try waitForReport("enable-status=ready", from: terminal))
        try sendProbe("reset", to: terminal)
        #expect(try waitForReport("reset-status=ready", from: terminal))
        try sendProbe("await-reset-transition", to: terminal)
        #expect(try waitForReport("await-reset-transition=ready", from: terminal))
        try setAppearance(.light, terminals: [terminal])
        #expect(try waitForReport("reset-disabled=none", from: terminal))
    }
    @Test("Protocol responses stay on the requesting terminal PTY")
    func responsesDoNotLeakToSiblingTerminal() throws {
        let first = try makeHostedTerminal()
        defer { tearDown(first) }
        let second = try makeHostedTerminal()
        defer { tearDown(second) }
        _ = try #require(first.surface.surface)
        _ = try #require(second.surface.surface)
        try setAppearance(.dark, terminals: [first, second])
        try sendProbe("barrier-dark", to: first)
        #expect(try waitForReport("barrier=1b5b3f3939373b316e", from: first))
        #expect(try waitForReport("barrier-reports=1b5b3f3939373b316e", from: first))
        try sendProbe("first", to: first)
        #expect(try waitForReport("first=1b5b3f3939373b316e", from: first))
        try sendProbe("enable", to: first)
        #expect(try waitForReport("initial=1b5b3f3939373b316e", from: first))
        #expect(try waitForReport("enable-status=ready", from: first))
        try sendProbe("await-transition", to: first)
        #expect(try waitForReport("await-transition=ready", from: first))
        try setAppearance(.light, terminals: [first, second])
        #expect(try waitForReport("transition=1b5b3f3939373b326e", from: first))
        #expect(try waitForReport("transition-reports=1b5b3f3939373b326e", from: first))
        // Drain the sibling PTY so a leaked report would be observed.
        try sendProbe("await-disabled-transition", to: second)
        #expect(try waitForReport("await-disabled-transition=ready", from: second))
        #expect(try waitForReport("disabled=none", from: second))
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
            waitForManualWrite(
                Data("\u{1b}[?997;2n".utf8),
                in: normalWrites
            ),
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
        let application = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousAppearanceMode = defaults.string(forKey: AppearanceSettings.appearanceModeKey)
        let previousApplicationAppearance = application.appearance
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-color-scheme-protocol-\(UUID().uuidString).txt")
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-color-scheme-protocol-\(UUID().uuidString).py")
        let commandURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-color-scheme-protocol-\(UUID().uuidString).commands")
        let script = """
        import os
        import re
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
        pending = bytearray()
        report_pattern = re.compile(b'\\x1b\\[\\?997;[12]n')
        def read_report(timeout):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                match = report_pattern.search(pending)
                if match:
                    report = pending[:match.end()]
                    del pending[:match.end()]
                    return report.hex()
                if not select.select([fd], [], [], 0.02)[0]:
                    continue
                chunk = os.read(fd, 64)
                if not chunk:
                    return 'none'
                pending.extend(chunk)
            return 'none'
        def read_until(expected, timeout):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                index = pending.find(expected)
                if index >= 0:
                    del pending[:index + len(expected)]
                    return True
                if select.select([fd], [], [], 0.02)[0]:
                    chunk = os.read(fd, 64)
                    if not chunk:
                        return False
                    pending.extend(chunk)
            return False
        def read_report_matching(expected, timeout):
            reports = []
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                report = read_report(max(0.0, deadline - time.monotonic()))
                if report == 'none':
                    break
                reports.append(report)
                if report == expected.hex():
                    break
            return reports
        def drain_reports(quiet_timeout):
            reports = []
            deadline = time.monotonic() + 1.0
            quiet_deadline = time.monotonic() + quiet_timeout
            while time.monotonic() < deadline and time.monotonic() < quiet_deadline:
                match = report_pattern.search(pending)
                if match:
                    reports.append(pending[:match.end()].hex())
                    del pending[:match.end()]
                    quiet_deadline = time.monotonic() + quiet_timeout
                    continue
                wait = min(0.02, max(0.0, quiet_deadline - time.monotonic()))
                if wait == 0.0:
                    break
                if select.select([fd], [], [], wait)[0]:
                    chunk = os.read(fd, 64)
                    if not chunk:
                        break
                    pending.extend(chunk)
                    quiet_deadline = time.monotonic() + quiet_timeout
            return reports
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
                    os.write(1, b'\\x1b[?996n')
                    record(command + '=' + read_report(1.0))
                elif command == 'barrier-dark' or command == 'barrier-light':
                    expected = b'\\x1b[?997;1n' if command.endswith('dark') else b'\\x1b[?997;2n'
                    os.write(1, b'\\x1b[?996n')
                    reports = read_report_matching(expected, 1.0)
                    reports.extend(drain_reports(0.1))
                    record('barrier=' + (reports[0] if reports else 'none'))
                    record('barrier-reports=' + ','.join(reports))
                elif command == 'enable':
                    os.write(1, b'\\x1b[?2031h')
                    record('initial=' + read_report(1.0))
                    os.write(1, b'\\x1b[?2031$p')
                    enabled = read_until(b'\\x1b[?2031;1$y', 1.0)
                    record('enable-status=' + ('ready' if enabled else 'none'))
                elif command == 'await-transition':
                    record('await-transition=ready')
                    reports = read_report_matching(b'\\x1b[?997;2n', 8.0)
                    record('transition=' + (reports[-1] if reports else 'none'))
                    record('transition-reports=' + ','.join(reports))
                elif command == 'disable':
                    os.write(1, b'\\x1b[?2031l')
                    os.write(1, b'\\x1b[?2031$p')
                    disabled = read_until(b'\\x1b[?2031;2$y', 1.0)
                    record('disable-status=' + ('ready' if disabled else 'none'))
                elif command == 'await-disabled-transition':
                    record('await-disabled-transition=ready')
                    record('disabled=' + read_report(0.35))
                elif command == 'reset':
                    os.write(1, b'\\x1bc')
                    os.write(1, b'\\x1b[?2031$p')
                    reset = read_until(b'\\x1b[?2031;2$y', 1.0)
                    record('reset-status=' + ('ready' if reset else 'none'))
                elif command == 'await-reset-transition':
                    record('await-reset-transition=ready')
                    record('reset-disabled=' + read_report(0.35))
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
        """
        var surfaceForCleanup: TerminalSurface?
        var windowForCleanup: NSWindow?
        var hostedTerminal: HostedTerminal?
        var ownershipTransferred = false
        defer {
            if !ownershipTransferred {
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
            runtimeSpawnPolicy: .heldForStartupRestoreAdmission
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
        // TerminalSurface's construction-time attachment happened while its
        // bootstrap window was being adopted. Re-attach once the test host is
        // in the real window so the native surface is created on this PTY.
        hostedView.attachSurface(surface)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        surface.cancelAgentCommandShimInstallLifecycle()
        surface.agentCommandShimInstallCompleted = true
        guard surface.admitStartupRestoreRuntime() else {
            Issue.record("Terminal color-scheme fixture could not admit its runtime")
            throw ProbeError.notReady
        }
        let terminal = HostedTerminal(
            surface: surface,
            window: window,
            outputURL: outputURL,
            scriptURL: scriptURL,
            commandURL: commandURL,
            previousAppearanceMode: previousAppearanceMode,
            previousApplicationAppearance: previousApplicationAppearance
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
            guard waitForLiveSurface(surface, timeout: Self.fixtureReadinessTimeout) else {
                Issue.record("Manual-mirror Ghostty surface did not become live")
                throw ProbeError.notReady
            }
        }
        // The caller's defer owns a successful fixture. Keep the construction
        // defer armed only for failures before this handoff.
        ownershipTransferred = true
        return terminal
    }
    private func setAppearance(
        _ mode: AppearanceMode,
        terminals: [HostedTerminal]
    ) throws {
        _ = AppearanceSettings.selectMode(
            mode,
            source: "TerminalColorSchemeProtocolTests.setAppearance"
        )
        let appearanceName: NSAppearance.Name = mode == .dark ? .darkAqua : .aqua
        if let appearance = NSAppearance(named: appearanceName) {
            NSApp.appearance = appearance
            for terminal in terminals {
                terminal.window.appearance = appearance
            }
        }
        let expected = mode == .dark
            ? GhosttyConfig.ColorSchemePreference.dark
            : GhosttyConfig.ColorSchemePreference.light
        let deadline = Date().addingTimeInterval(10)
        repeat {
            let ready = GhosttyApp.shared.effectiveTerminalColorSchemePreference == expected
                && NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == appearanceName
                && terminals.allSatisfy {
                    $0.window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == appearanceName
                }
                && !GhosttyApp.shared.isConfigurationReloadActive
            if ready {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        guard GhosttyApp.shared.effectiveTerminalColorSchemePreference == expected,
              !GhosttyApp.shared.isConfigurationReloadActive else {
            throw ProbeError.notReady
        }
        let scheme = mode == .dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        for terminal in terminals {
            let surface = try #require(terminal.surface.surface)
            ghostty_surface_set_color_scheme(surface, scheme)
        }
    }
    private func sendProbe(_ command: String, to terminal: HostedTerminal) throws {
        let existing = (try? Data(contentsOf: terminal.commandURL)) ?? Data()
        let next = existing + Data("\(command)\n".utf8)
        try next.write(to: terminal.commandURL, options: .atomic)
    }
    private func waitForManualWrite(
        _ expected: Data,
        in capture: ManualWriteCapture,
        timeout: TimeInterval = 3
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if capture.snapshot.contains(expected) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return capture.snapshot.contains(expected)
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
        let finalOutput = (try? String(contentsOf: terminal.outputURL, encoding: .utf8)) ?? "<unreadable>"
        print("color-scheme fixture timeout expected=\(report) actual=\(finalOutput.debugDescription)")
        return false
    }
    private func waitForLiveSurface(
        _ surface: TerminalSurface,
        timeout: TimeInterval
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
        let defaults = UserDefaults.standard
        if let mode = terminal.previousAppearanceMode {
            defaults.set(mode, forKey: AppearanceSettings.appearanceModeKey)
        } else {
            defaults.removeObject(forKey: AppearanceSettings.appearanceModeKey)
        }
        NSApp.appearance = terminal.previousApplicationAppearance
    }
    private enum ProbeError: Error { case notReady }
    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
