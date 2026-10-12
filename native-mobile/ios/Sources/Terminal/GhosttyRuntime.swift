import Foundation
import GhosttyNextKit
import UIKit

/// The process-wide libghostty app. Wakeups from Ghostty threads drain the
/// mailbox on the main actor; surface actions (scrollbar, cell size) are
/// routed to the owning `GhosttySurfaceView` through the surface userdata.
@MainActor
final class GhosttyRuntime {
    enum Failure: Error { case initFailed(Int32), appCreationFailed }

    let app: ghostty_app_t
    private let config: ghostty_config_t
    private var dirty: [ObjectIdentifier: () -> Void] = [:]
    private static var current: GhosttyRuntime?

    static let scrollbackLimitBytes = 16 * 1024 * 1024

    static func shared() throws -> GhosttyRuntime {
        if let current { return current }
        let made = try GhosttyRuntime()
        current = made
        return made
    }

    private init() throws {
        let status = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard status == GHOSTTY_SUCCESS else { throw Failure.initFailed(status) }
        guard let config = ghostty_config_new() else { throw Failure.appCreationFailed }
        Self.loadProductConfig(config)
        ghostty_config_finalize(config)
        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { _ in
            Task { @MainActor in GhosttyRuntime.current?.tick() }
        }
        runtime.action_cb = { _, target, action in
            guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface,
                  let userdata = ghostty_surface_userdata(surface) else { return false }
            let view = Unmanaged<SurfaceActionBox>.fromOpaque(userdata).takeUnretainedValue()
            switch action.tag {
            case GHOSTTY_ACTION_SCROLLBAR:
                let bar = action.action.scrollbar
                let value = (Int(bar.total), Int(bar.offset), Int(bar.len))
                Task { @MainActor in view.onScrollbar?(value.0, value.1, value.2) }
                return true
            case GHOSTTY_ACTION_CELL_SIZE:
                let size = action.action.cell_size
                let value = (Double(size.width), Double(size.height))
                Task { @MainActor in view.onCellSize?(value.0, value.1) }
                return true
            case GHOSTTY_ACTION_RING_BELL:
                Task { @MainActor in Haptics.soft() }
                return true
            default:
                return false
            }
        }
        runtime.read_clipboard_cb = { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        runtime.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtime.write_clipboard_cb = { _, _, content, count, _ in
            guard let content, count > 0, let data = content.pointee.data else { return }
            let text = String(decoding: UnsafeRawBufferPointer(start: data, count: content.pointee.len), as: UTF8.self)
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

    private static func loadProductConfig(_ config: ghostty_config_t) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-native-ghostty.conf")
        let text = """
        scrollback-limit-bytes = \(scrollbackLimitBytes)
        window-padding-x = 0
        window-padding-y = 0
        window-padding-balance = false
        font-feature = -calt
        cursor-style-blink = false
        background = #131415
        foreground = #d8d9da

        """
        guard (try? Data(text.utf8).write(to: url, options: .atomic)) != nil else { return }
        url.path.withCString { ghostty_config_load_file(config, $0) }
    }

    func tick() {
        ghostty_app_tick(app)
        let draws = dirty
        dirty.removeAll()
        for draw in draws.values { draw() }
    }

    func requestDraw(_ owner: AnyObject, _ draw: @escaping () -> Void) {
        let first = dirty.isEmpty
        dirty[ObjectIdentifier(owner)] = draw
        if first { Task { @MainActor in self.tick() } }
    }
}

/// Holds a surface's action handlers for the C trampoline (userdata).
@MainActor
final class SurfaceActionBox {
    var onScrollbar: ((Int, Int, Int) -> Void)?
    var onCellSize: ((Double, Double) -> Void)?
    var deliverInput: ((Data) -> Void)?
}

/// A surface handle sent to the output queue.
struct SurfaceRef: @unchecked Sendable {
    let surface: ghostty_surface_t
}
