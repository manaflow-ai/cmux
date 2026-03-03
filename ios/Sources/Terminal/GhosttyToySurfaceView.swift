import UIKit

final class GhosttyToySurfaceView: UIView {
    struct LaunchConfig: Sendable {
        var workingDirectory: String?
        var command: String?
        var initialInput: String?
        var fontSize: Float32 = 14
    }

    private weak var runtime: GhosttyToyRuntime?
    private let launchConfig: LaunchConfig

    private(set) var surface: ghostty_surface_t?

    init(runtime: GhosttyToyRuntime, launchConfig: LaunchConfig) {
        self.runtime = runtime
        self.launchConfig = launchConfig
        super.init(frame: CGRect(x: 0, y: 0, width: 900, height: 650))
        backgroundColor = .clear
        isOpaque = false
        initializeSurface()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncSurfaceGeometry()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncSurfaceGeometry()
        setFocus(window != nil)
    }

    private var preferredScreenScale: CGFloat {
        if let screen = window?.windowScene?.screen {
            return screen.scale
        }

        let traitScale = traitCollection.displayScale
        return traitScale > 0 ? traitScale : 2
    }

    func sendText(_ text: String) {
        guard let surface else { return }
        let count = text.utf8CString.count
        guard count > 0 else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(count - 1))
        }
    }

    private func initializeSurface() {
        guard let app = runtime?.app else { return }
        surface = makeSurface(app: app, hostView: self, config: launchConfig)
    }

    private func setFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    private func syncSurfaceGeometry() {
        guard let surface else { return }

        let scale = preferredScreenScale
        ghostty_surface_set_content_scale(surface, scale, scale)

        let width = UInt32(max(1, Int((bounds.width * scale).rounded(.down))))
        let height = UInt32(max(1, Int((bounds.height * scale).rounded(.down))))
        ghostty_surface_set_size(surface, width, height)
    }

    private func makeSurface(
        app: ghostty_app_t,
        hostView: GhosttyToySurfaceView,
        config: LaunchConfig
    ) -> ghostty_surface_t? {
        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.userdata = Unmanaged.passUnretained(hostView).toOpaque()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_IOS
        surfaceConfig.platform = ghostty_platform_u(
            ios: ghostty_platform_ios_s(
                uiview: Unmanaged.passUnretained(hostView).toOpaque()
            )
        )
        surfaceConfig.scale_factor = preferredScreenScale
        surfaceConfig.font_size = config.fontSize
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        return config.workingDirectory.withCString { workingDirectoryPtr in
            surfaceConfig.working_directory = workingDirectoryPtr
            return config.command.withCString { commandPtr in
                surfaceConfig.command = commandPtr
                return config.initialInput.withCString { inputPtr in
                    surfaceConfig.initial_input = inputPtr
                    return ghostty_surface_new(app, &surfaceConfig)
                }
            }
        }
    }
}
