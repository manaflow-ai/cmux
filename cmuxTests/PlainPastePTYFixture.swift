import AppKit
import CmuxTerminal
import CmuxTerminalCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Owns the terminal, raw receiver and counting launch wrappers for one benchmark.
@MainActor
final class PlainPastePTYFixture {
    let root: URL
    let launches: URL
    let surface: TerminalSurface
    let window: NSWindow
    private let previousMenu: NSMenu?
    var view: GhosttyNSView { surface.hostedView.surfaceView }

    init(optimized: Bool, workerStartupDelay: Double = 0) throws {
        previousMenu = NSApp.mainMenu
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-paste-pty-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        launches = root.appendingPathComponent("launches.txt")
        try Data().write(to: launches)
        let app = try #require(Bundle.main.executableURL)
        let helper = try #require(Bundle.main.url(forResource: "cmux-paste-text-worker", withExtension: nil, subdirectory: "bin"))
        let fullWrapper = root.appendingPathComponent("full")
        let textWrapper = root.appendingPathComponent("text")
        for (url, executable, label) in [(fullWrapper, app, "full"), (textWrapper, helper, "text")] {
            let script = "#!/bin/sh\nprintf '%s\\n' '\(label)' >> \(launches.path.terminalShellEscaped)\nsleep \(workerStartupDelay)\nexec \(executable.path.terminalShellEscaped) \"$@\"\n"
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let owner = GhosttyApp.terminalPasteboard
        let client = TerminalPastePreparationWorkerClient(
            executableURL: fullWrapper, pasteboardService: owner,
            plainTextExecutableURL: optimized ? textWrapper : nil
        )
        let service = TerminalImageTransferPreparationService(
            operation: { try await client.prepare($0) },
            cleanup: { $0.cleanupTransferredTemporaryFiles(using: owner) }
        )
        let live = GhosttyApp.terminalSurfaceRuntimeDependencies
        let dependencies = TerminalSurfaceRuntimeDependencies(
            registry: live.registry, engine: live.engine,
            viewProvider: TerminalSurfaceViewFactory(imageTransferPreparation: service),
            spawnPolicy: live.spawnPolicy, byteTee: live.byteTee,
            rendererRealization: live.rendererRealization, hibernationRecorder: live.hibernationRecorder,
            runtimeTeardown: live.runtimeTeardown, restoreSpawnScheduler: live.restoreSpawnScheduler,
            runtimeFilesystem: live.runtimeFilesystem, sessionPortBase: live.sessionPortBase,
            sessionPortRangeSize: live.sessionPortRangeSize,
            scrollbackReplayEnvironmentKey: live.scrollbackReplayEnvironmentKey
        )
        let receiver = root.appendingPathComponent("receiver.py")
        try """
        import json, os, pathlib, select, sys, termios, time, tty
        root = pathlib.Path(sys.argv[1])
        old = termios.tcgetattr(0)
        try:
            tty.setraw(0)
            os.write(1, b'\\x1b[?2004hPASTE_READY\\r\\n')
            pending = b''
            for trial in range(6):
                deadline = time.monotonic() + 20
                while b'\\x1b[201~' not in pending and time.monotonic() < deadline:
                    if select.select([0], [], [], 0.1)[0]:
                        pending += os.read(0, 65536)
                received_at = time.time()
                end = pending.index(b'\\x1b[201~') + 6 if b'\\x1b[201~' in pending else len(pending)
                data, pending = pending[:end], pending[end:]
                temp = root / ('receipt-%d.tmp' % trial)
                temp.write_text(json.dumps({'hex': data.hex(), 'received_at': received_at}))
                temp.rename(root / ('receipt-%d.json' % trial))
        finally:
            termios.tcsetattr(0, termios.TCSADRAIN, old)
        """.write(to: receiver, atomically: true, encoding: .utf8)
        surface = TerminalSurface(
            tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT, configTemplate: nil,
            initialCommand: "/usr/bin/python3 \(receiver.path.terminalShellEscaped) \(root.path.terminalShellEscaped)",
            dependencies: dependencies
        )
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        let hosted = surface.hostedView
        hosted.frame = content.bounds
        hosted.autoresizingMask = [.width, .height]
        content.addSubview(hosted)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        content.layoutSubtreeIfNeeded()
        hosted.setVisibleInUI(true)
        hosted.setActive(true)
        try #require(window.makeFirstResponder(hosted.surfaceView))
        // The app-host's normal menu targets its workspace window, not this
        // isolated terminal. Keep AppKit menu dispatch, with an explicit target.
        let menu = NSMenu()
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Edit")
        let paste = NSMenuItem(title: "Paste", action: #selector(GhosttyNSView.paste(_:)), keyEquivalent: "v")
        paste.target = hosted.surfaceView
        submenu.addItem(paste)
        edit.submenu = submenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }

    func waitUntilReady() async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while surface.readText(region: .screen)?.contains("PASTE_READY") != true,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(surface.readText(region: .screen)?.contains("PASTE_READY") == true)
    }

    func receipt(trial: Int) async throws -> [String: Any] {
        let url = root.appendingPathComponent("receipt-\(trial).json")
        let deadline = ContinuousClock.now + .seconds(20)
        while !FileManager.default.fileExists(atPath: url.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: url.path), Comment(rawValue:
            "No PTY receipt; launches=\(String(describing: try? String(contentsOf: launches, encoding: .utf8))) " +
            "screen=\(surface.readText(region: .screen) ?? "unavailable")"
        ))
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func close() {
        NSApp.mainMenu = previousMenu
        surface.teardownSurface()
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: root)
    }
}
