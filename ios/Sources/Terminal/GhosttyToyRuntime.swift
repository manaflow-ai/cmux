import Foundation
import UIKit

@MainActor
final class GhosttyToyRuntime: ObservableObject {
    enum RuntimeError: LocalizedError {
        case backendInitFailed(code: Int32)
        case appCreationFailed

        var errorDescription: String? {
            switch self {
            case .backendInitFailed(let code):
                return "libghostty initialization failed (\(code))"
            case .appCreationFailed:
                return "libghostty app creation failed"
            }
        }
    }

    private static var backendInitialized = false

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    init() throws {
        try Self.initializeBackendIfNeeded()

        let config = ghostty_config_new()
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)

        var runtimeConfig = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in
                GhosttyToyRuntime.handleWakeup(userdata)
            },
            action_cb: { app, target, action in
                GhosttyToyRuntime.handleAction(app, target: target, action: action)
            },
            read_clipboard_cb: { userdata, location, state in
                GhosttyToyRuntime.handleReadClipboard(userdata, location: location, state: state)
            },
            confirm_read_clipboard_cb: { _, _, _, _ in
                // iOS toy runtime doesn't currently support clipboard confirmation prompts.
            },
            write_clipboard_cb: { userdata, location, content, len, confirm in
                GhosttyToyRuntime.handleWriteClipboard(
                    userdata,
                    location: location,
                    content: content,
                    len: len,
                    confirm: confirm
                )
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyToyRuntime.handleCloseSurface(userdata, processAlive: processAlive)
            }
        )

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            ghostty_config_free(config)
            throw RuntimeError.appCreationFailed
        }

        self.config = config
        self.app = app
    }

    deinit {
        if let app {
            ghostty_app_free(app)
        }
        if let config {
            ghostty_config_free(config)
        }
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    private static func initializeBackendIfNeeded() throws {
        guard !backendInitialized else { return }
        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard result == GHOSTTY_SUCCESS else {
            throw RuntimeError.backendInitFailed(code: result)
        }
        backendInitialized = true
    }

    nonisolated private static func handleWakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let runtime = Unmanaged<GhosttyToyRuntime>.fromOpaque(userdata).takeUnretainedValue()
        Task { @MainActor in
            runtime.tick()
        }
    }

    nonisolated private static func handleAction(
        _ app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        // For the toy runtime we only implement URL opens; all other action
        // routing will be layered in later milestones.
        if action.tag == GHOSTTY_ACTION_OPEN_URL {
            let payload = action.action.open_url
            guard let urlPtr = payload.url else { return false }
            let data = Data(bytes: urlPtr, count: Int(payload.len))
            guard let urlString = String(data: data, encoding: .utf8),
                  let url = URL(string: urlString) else { return false }

            Task { @MainActor in
                UIApplication.shared.open(url)
            }
            return true
        }

        return false
    }

    nonisolated private static func handleReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) {
        let value = UIPasteboard.general.string ?? ""

        Task { @MainActor in
            guard let surfaceView = surfaceView(from: userdata),
                  let surface = surfaceView.surface else { return }

            value.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }
        }
    }

    nonisolated private static func handleWriteClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let content, len > 0 else { return }

        for index in 0..<len {
            let item = content[index]
            guard let mimePtr = item.mime,
                  let dataPtr = item.data else { continue }
            let mime = String(cString: mimePtr)
            guard mime == "text/plain" else { continue }
            UIPasteboard.general.string = String(cString: dataPtr)
            return
        }
    }

    nonisolated private static func handleCloseSurface(
        _ userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        guard let surfaceView = surfaceView(from: userdata) else { return }
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .ghosttyToySurfaceDidRequestClose,
                object: surfaceView,
                userInfo: ["process_alive": processAlive]
            )
        }
    }

    nonisolated private static func surfaceView(from userdata: UnsafeMutableRawPointer?) -> GhosttyToySurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyToySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }
}

extension Optional where Wrapped == String {
    func withCString<T>(_ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
        if let value = self {
            return try value.withCString(body)
        }
        return try body(nil)
    }
}

extension Notification.Name {
    static let ghosttyToySurfaceDidRequestClose = Notification.Name("ghosttyToySurfaceDidRequestClose")
}
