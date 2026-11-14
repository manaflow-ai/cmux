import GhosttyNextKit
import UIKit

/// The process-wide libghostty app. Surfaces are created per terminal view.
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    private init() {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0 else { return }
        let config = ghostty_config_new()
        let settings = """
        font-size = 13
        window-padding-x = 6
        window-padding-y = 4
        cursor-style = block
        cursor-style-blink = true
        background = #1E1E1E
        foreground = #FFFFFF
        selection-background = #3F638B
        cursor-color = #FFFFFF
        palette = 0=#1A1A1A
        palette = 1=#CC372E
        palette = 2=#26A439
        palette = 3=#CDAC08
        palette = 4=#0869CB
        palette = 5=#9647BF
        palette = 6=#479EC2
        palette = 7=#98989D
        palette = 8=#464646
        palette = 9=#FF453A
        palette = 10=#32D74B
        palette = 11=#FFD60A
        palette = 12=#0A84FF
        palette = 13=#BF5AF2
        palette = 14=#76D6FF
        palette = 15=#FFFFFF
        """
        settings.withCString { pointer in
            ghostty_config_load_string(config, pointer, UInt(strlen(pointer)), "cmux-next-mobile")
        }
        ghostty_config_finalize(config)
        self.config = config

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { _ in
            DispatchQueue.main.async { GhosttyRuntime.shared.tick() }
        }
        runtime.action_cb = { _, target, action in
            GhosttyRuntime.handleAction(target: target, action: action)
        }
        runtime.read_clipboard_cb = { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        runtime.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtime.write_clipboard_cb = { _, _, content, count, _ in
            guard let content, count > 0, let data = content.pointee.data else { return }
            let text = String(decoding: UnsafeRawBufferPointer(start: data, count: content.pointee.len), as: UTF8.self)
            DispatchQueue.main.async { UIPasteboard.general.string = text }
        }
        runtime.close_surface_cb = { _, _ in }
        app = ghostty_app_new(&runtime, config)
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setColorScheme(dark: Bool) {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    nonisolated private static func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface,
              let userdata = ghostty_surface_userdata(surface)
        else { return false }
        let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            if let title = action.action.set_title.title {
                let text = String(cString: title)
                DispatchQueue.main.async { view.onTitle?(text) }
            }
            return true
        case GHOSTTY_ACTION_RENDER:
            return true
        default:
            return false
        }
    }
}
