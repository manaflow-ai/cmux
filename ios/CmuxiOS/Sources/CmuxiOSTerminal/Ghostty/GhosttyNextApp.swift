import Foundation
import GhosttyNextKit
import UIKit

/// The process-wide libghostty app (ghostty-next). One per process: it owns
/// the config and the app mailbox; every surface belongs to it. Wakeups
/// from Ghostty's threads drain the mailbox on the main actor (no timers).
@MainActor
final class GhosttyNextApp {
    enum Failure: Error { case initFailed(Int32), appCreationFailed }

    let app: ghostty_app_t
    private let config: ghostty_config_t
    /// Surfaces to draw after the next mailbox drain.
    private var dirty: [ObjectIdentifier: () -> Void] = [:]

    private static var current: GhosttyNextApp?

    /// `ios.terminal.scrollbackBytes` (ghostty-next section 7): the local
    /// scrollback cap. Every snapshot restore applies it (ios-v5).
    static let scrollbackLimitBytes = 8 * 1024 * 1024

    /// DEBUG diagnostics: config load problems (0 when the product config applied).
    private(set) var configDiagnostics: UInt32 = 0

    /// The shared app, created on first use.
    static func shared() throws -> GhosttyNextApp {
        if let current { return current }
        let made = try GhosttyNextApp()
        current = made
        return made
    }

    /// Ghostty's runtime callbacks, nonisolated: Ghostty calls them from its
    /// renderer and IO threads.
    nonisolated private static func runtimeConfig() -> ghostty_runtime_config_s {
        let writeClipboard: ghostty_runtime_write_clipboard_cb = { _, _, content, count, _ in
            guard count > 0 else { return }
            let item = content.pointee
            let bytes = UnsafeRawBufferPointer(start: item.data, count: item.len)
            let text = String(decoding: bytes, as: UTF8.self)
            Task { @MainActor in UIPasteboard.general.string = text }
        }
        return ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in
                Task { @MainActor in GhosttyNextApp.current?.tick() }
            },
            action_cb: { _, _, _ in false },
            read_clipboard_cb: { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNAVAILABLE },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: writeClipboard,
            close_surface_cb: { _, _ in }
        )
    }

    private init() throws {
        let status = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard status == GHOSTTY_SUCCESS else { throw Failure.initFailed(status) }
        guard let config = ghostty_config_new() else { throw Failure.appCreationFailed }
        // No user config files on the phone yet: product defaults plus the
        // phone's own settings (libghostty loads config from files only).
        Self.loadProductConfig(config)
        ghostty_config_finalize(config)
        // Built outside the main actor: Ghostty calls these from its own
        // threads, and a closure formed in this @MainActor init would carry
        // main-actor isolation (Swift traps when the renderer thread calls it).
        var runtime = Self.runtimeConfig()
        guard let app = ghostty_app_new(&runtime, config) else {
            ghostty_config_free(config)
            throw Failure.appCreationFailed
        }
        self.app = app
        self.config = config
        configDiagnostics = ghostty_config_diagnostics_count(config)
    }

    /// Writes the phone's product settings to a private file and loads it.
    private static func loadProductConfig(_ config: ghostty_config_t) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-next-product.conf")
        let text = "scrollback-limit-bytes = \(scrollbackLimitBytes)\n"
        guard (try? Data(text.utf8).write(to: url, options: .atomic)) != nil else { return }
        url.path.withCString { ghostty_config_load_file(config, $0) }
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
