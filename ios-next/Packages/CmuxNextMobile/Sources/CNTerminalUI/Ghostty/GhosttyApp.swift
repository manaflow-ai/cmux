#if os(iOS)
import Foundation
import GhosttyNextKit
import UIKit

/// The process-wide libghostty app (ghostty-next), adapted from the cmux
/// iOS wrapper (ios/CmuxiOS/Sources/CmuxiOSTerminal/Ghostty/GhosttyNextApp.swift).
/// One per process: it owns the configs and the app mailbox; every surface
/// belongs to it. Wakeups from Ghostty's threads drain the mailbox on the
/// main actor (no timers).
///
/// The phone has no Ghostty config files and no theme resources, so the
/// cmux-next default theme pair, "Apple System Colors" (dark) and "Apple
/// System Colors Light", is written out here and loaded as two configs.
/// A surface switches between them with `ghostty_surface_update_config`
/// when the trait collection's interface style changes.
@MainActor
final class GhosttyApp {
    enum Failure: Error { case initFailed(Int32), appCreationFailed }

    let app: ghostty_app_t
    private let lightConfig: ghostty_config_t
    private let darkConfig: ghostty_config_t
    /// Surfaces to draw after the next mailbox drain.
    private var dirty: [ObjectIdentifier: () -> Void] = [:]

    private static var current: GhosttyApp?

    /// Local scrollback cap (ghostty-next `scrollback-limit-bytes`).
    static let scrollbackLimitBytes = 8 * 1024 * 1024

    /// Config problems (0 when both configs applied cleanly).
    private(set) var configDiagnostics: UInt32 = 0

    /// The shared app, created on first use.
    static func shared() throws -> GhosttyApp {
        if let current { return current }
        let made = try GhosttyApp()
        current = made
        return made
    }

    private init() throws {
        let status = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard status == GHOSTTY_SUCCESS else { throw Failure.initFailed(status) }
        guard let light = Self.makeConfig(TerminalTheme.light), let dark = Self.makeConfig(TerminalTheme.dark) else {
            throw Failure.appCreationFailed
        }
        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { _ in
            Task { @MainActor in GhosttyApp.current?.tick() }
        }
        runtime.action_cb = { _, _, _ in false }
        runtime.read_clipboard_cb = { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        runtime.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtime.write_clipboard_cb = { _, _, content, count, _ in
            guard let content, count > 0, let data = content.pointee.data else { return }
            let bytes = UnsafeRawBufferPointer(start: data, count: content.pointee.len)
            let text = String(decoding: bytes, as: UTF8.self)
            Task { @MainActor in UIPasteboard.general.string = text }
        }
        runtime.close_surface_cb = { _, _ in }
        guard let app = ghostty_app_new(&runtime, dark) else {
            ghostty_config_free(light)
            ghostty_config_free(dark)
            throw Failure.appCreationFailed
        }
        self.app = app
        lightConfig = light
        darkConfig = dark
        configDiagnostics = ghostty_config_diagnostics_count(light) + ghostty_config_diagnostics_count(dark)
    }

    /// The config for an interface style.
    func config(for style: UIUserInterfaceStyle) -> ghostty_config_t {
        style == .light ? lightConfig : darkConfig
    }

    /// Writes one theme's product config to a private file and loads it
    /// (libghostty loads config from files).
    private static func makeConfig(_ theme: TerminalTheme) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-next-ghostty-\(theme.name).conf")
        let text = theme.configText + """
        scrollback-limit-bytes = \(scrollbackLimitBytes)
        font-size = \(TerminalFontSize.defaultSize)
        window-padding-x = 6
        window-padding-y = 4
        window-padding-balance = false
        cursor-style-blink = false
        mouse-hide-while-typing = false

        """
        if (try? Data(text.utf8).write(to: url, options: .atomic)) != nil {
            url.path.withCString { ghostty_config_load_file(config, $0) }
        }
        ghostty_config_finalize(config)
        return config
    }

    /// Drains the app mailbox, then draws every surface that asked for a frame.
    func tick() {
        ghostty_app_tick(app)
        let draws = dirty
        dirty.removeAll()
        for draw in draws.values { draw() }
    }

    /// Coalesces draw requests to one per mailbox drain.
    func requestDraw(_ owner: AnyObject, _ draw: @escaping () -> Void) {
        let first = dirty.isEmpty
        dirty[ObjectIdentifier(owner)] = draw
        if first { Task { @MainActor in self.tick() } }
    }
}

/// Ghostty's "Apple System Colors" theme pair, the cmux-next default
/// (the same files ship in the Mac app's Resources).
struct TerminalTheme: Sendable {
    let name: String
    let configText: String

    private static let sharedPalette = """
    palette = 0=#1a1a1a
    palette = 1=#cc372e
    palette = 2=#26a439
    palette = 3=#cdac08
    palette = 4=#0869cb
    palette = 5=#9647bf
    palette = 6=#479ec2
    palette = 7=#98989d
    palette = 8=#464646
    palette = 9=#ff453a
    palette = 10=#32d74b
    palette = 12=#0a84ff
    palette = 13=#bf5af2
    palette = 15=#ffffff

    """

    static let dark = TerminalTheme(name: "dark", configText: sharedPalette + """
    palette = 11=#ffd60a
    palette = 14=#76d6ff
    background = #1e1e1e
    foreground = #ffffff
    cursor-color = #98989d
    cursor-text = #ffffff
    selection-background = #3f638b
    selection-foreground = #ffffff

    """)

    static let light = TerminalTheme(name: "light", configText: sharedPalette + """
    palette = 11=#e5bc00
    palette = 14=#69c9f2
    background = #feffff
    foreground = #000000
    cursor-color = #98989d
    cursor-text = #ffffff
    selection-background = #abd8ff
    selection-foreground = #000000

    """)
}
#endif
