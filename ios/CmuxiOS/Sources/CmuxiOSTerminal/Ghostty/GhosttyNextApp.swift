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

    /// The shared app, created on first use.
    static func shared() throws -> GhosttyNextApp {
        if let current { return current }
        let made = try GhosttyNextApp()
        current = made
        return made
    }

    private init() throws {
        let status = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard status == GHOSTTY_SUCCESS else { throw Failure.initFailed(status) }
        guard let config = ghostty_config_new() else { throw Failure.appCreationFailed }
        // No user config files on the phone yet: product defaults only.
        ghostty_config_finalize(config)
        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { _ in
            Task { @MainActor in GhosttyNextApp.current?.tick() }
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
        guard let app = ghostty_app_new(&runtime, config) else {
            ghostty_config_free(config)
            throw Failure.appCreationFailed
        }
        self.app = app
        self.config = config
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
