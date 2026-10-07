import CmuxTerminalRenderCore
import Foundation
import GhosttyNextKit
import UIKit

/// The process-wide libghostty app (ghostty-next). One per process: it owns
/// the config and the app mailbox; every surface belongs to it. Wakeups
/// from Ghostty's threads drain the mailbox on the main actor (no timers).
/// Surface actions (open a link, set the title) are routed to the view that
/// owns the surface.
@MainActor
final class GhosttyNextApp {
    enum Failure: Error { case initFailed(Int32), appCreationFailed }

    let app: ghostty_app_t
    private let config: ghostty_config_t
    /// Surfaces to draw after the next mailbox drain.
    private var dirty: [ObjectIdentifier: () -> Void] = [:]
    /// The view of each live surface, for action routing.
    private var owners: [UnsafeMutableRawPointer: WeakTerminalView] = [:]

    private static var current: GhosttyNextApp?

    /// DEBUG diagnostics: config load problems (0 when the product config applied).
    private(set) var configDiagnostics: UInt32 = 0

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
        // No user config files on the phone: product defaults plus the
        // phone's settings (TerminalGhosttyConfig, 8 MiB scrollback).
        guard let config = Self.makeConfig(TerminalGhosttyConfig()) else { throw Failure.appCreationFailed }
        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { _ in
            Task { @MainActor in GhosttyNextApp.current?.tick() }
        }
        runtime.action_cb = { _, target, action in GhosttyNextApp.route(target, action) }
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
        configDiagnostics = ghostty_config_diagnostics_count(config)
    }

    /// A finalized Ghostty config from the phone's settings. The caller frees it.
    static func makeConfig(_ settings: TerminalGhosttyConfig) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        // libghostty's proven loader on iOS reads files: write the settings
        // to a private file (one per settings value) and load it.
        let name = "ghostty-next-\(UInt(bitPattern: settings.text.hashValue)).conf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        if (try? Data(settings.text.utf8).write(to: url, options: .atomic)) != nil {
            url.path.withCString { ghostty_config_load_file(config, $0) }
            try? FileManager.default.removeItem(at: url)
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

    func register(_ surface: ghostty_surface_t, view: GhosttyTerminalView) {
        owners[UnsafeMutableRawPointer(surface)] = WeakTerminalView(view: view)
    }

    func unregister(_ surface: ghostty_surface_t) {
        owners[UnsafeMutableRawPointer(surface)] = nil
    }

    // MARK: Actions

    /// Runs on whichever thread Ghostty performs the action from; copies what
    /// it needs and hands it to the main actor.
    private nonisolated static func route(_ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface else { return false }
        let key = SurfaceKey(raw: UnsafeMutableRawPointer(surface))
        let event: GhosttySurfaceAction
        switch action.tag {
        case GHOSTTY_ACTION_OPEN_URL:
            let open = action.action.open_url
            guard let url = open.url, open.len > 0 else { return false }
            event = .openURL(String(decoding: UnsafeRawBufferPointer(start: url, count: Int(open.len)), as: UTF8.self))
        case GHOSTTY_ACTION_SET_TITLE:
            guard let title = action.action.set_title.title else { return false }
            event = .title(String(cString: title))
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            let link = action.action.mouse_over_link
            event = .hoverLink(link.url.flatMap { link.len > 0 ? String(decoding: UnsafeRawBufferPointer(start: $0, count: link.len), as: UTF8.self) : nil })
        default:
            return false
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { current?.deliver(event, to: key) }
        } else {
            Task { @MainActor in current?.deliver(event, to: key) }
        }
        return true
    }

    private func deliver(_ event: GhosttySurfaceAction, to key: SurfaceKey) {
        owners[key.raw]?.view?.handle(event)
    }
}

/// An action Ghostty asked the embedder to perform for one surface.
enum GhosttySurfaceAction: Sendable {
    case openURL(String)
    case title(String)
    case hoverLink(String?)
}

/// A surface pointer used only as a dictionary key across the thread hop.
private struct SurfaceKey: @unchecked Sendable {
    let raw: UnsafeMutableRawPointer
}

@MainActor
private struct WeakTerminalView {
    weak var view: GhosttyTerminalView?
}
