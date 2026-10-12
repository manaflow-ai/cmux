import Foundation
import GhosttyNextKit
import UIKit

/// One ghostty-next surface in manual-mirror mode: the Mac's daemon owns the
/// PTY; bytes arrive through `feed`, and the grid is locked to the Mac's
/// size with `setGrid`. The view draws only the grid's viewport; the
/// enclosing `TerminalScrollView` moves it for pixel-smooth scrolling.
@MainActor
final class GhosttySurfaceView: UIView {
    private(set) var surface: ghostty_surface_t?
    private var runtime: GhosttyRuntime?
    private let actions = SurfaceActionBox()
    private let outputQueue = DispatchQueue(label: "cmux.native.terminal.output", qos: .userInteractive)
    private var gridGeneration: UInt64 = 0
    private var pendingFeeds: [Data] = []

    /// Ghostty's scrollbar: total rows, top row of the viewport, viewport rows.
    var onScrollbar: ((Int, Int, Int) -> Void)? {
        didSet { actions.onScrollbar = onScrollbar }
    }
    /// The surface exists and its cell metrics are known.
    var onReady: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.terminalBackground
        isOpaque = true
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Terminal")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        guard let surface else { return }
        let ref = SurfaceRef(surface: surface)
        let box = actions
        // Free only after queued output returned (ghostty-next contract).
        outputQueue.async {
            DispatchQueue.main.async {
                ghostty_surface_free(ref.surface)
                _ = box
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, surface == nil else { return }
        createSurface()
    }

    private func createSurface() {
        guard let runtime = try? GhosttyRuntime.shared() else { return }
        self.runtime = runtime
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(actions).toOpaque()
        config.scale_factor = Double(window?.screen.scale ?? 3)
        config.font_size = Float(TerminalPreferences.fontSize)
        config.io_mode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR
        // The phone sends input through the daemon (`send` / `send-key`),
        // so Ghostty-encoded writes are dropped.
        config.io_write_userdata = nil
        config.io_write_cb = { _, _, _ in }
        surface = ghostty_surface_new(runtime.app, &config)
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, true)
        ghostty_surface_set_focus(surface, true)
        syncPixelSize()
        for data in pendingFeeds { feed(data) }
        pendingFeeds.removeAll()
        onReady?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncPixelSize()
    }

    private func syncPixelSize() {
        guard let surface, let window else { return }
        let scale = window.screen.scale
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(max(1, bounds.width * scale)), UInt32(max(1, bounds.height * scale)))
        requestFrame()
    }

    /// Cell size in points (nil before the surface exists).
    var cellSize: CGSize? {
        guard let surface, window != nil else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), metrics.cell_height > 0 else { return nil }
        // Grid metrics are in points (the content scale is already applied).
        return CGSize(width: metrics.cell_width, height: metrics.cell_height)
    }

    /// How many cells fit a size in points.
    func gridFitting(_ size: CGSize) -> (cols: Int, rows: Int)? {
        guard let cell = cellSize, cell.width > 0, cell.height > 0 else { return nil }
        return (max(20, Int(size.width / cell.width)), max(5, Int(size.height / cell.height)))
    }

    // MARK: Output (one serial queue, in stream order)

    func feed(_ data: Data) {
        guard let surface else { pendingFeeds.append(data); return }
        let ref = SurfaceRef(surface: surface)
        outputQueue.async {
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                ghostty_surface_process_output(ref.surface, base, UInt(raw.count))
            }
            Task { @MainActor [weak self] in self?.requestFrame() }
        }
    }

    /// Locks the local grid to the Mac's size, in order with output.
    func setGrid(cols: Int, rows: Int) {
        guard let surface, let c = UInt16(exactly: cols), let r = UInt16(exactly: rows) else { return }
        gridGeneration += 1
        let generation = gridGeneration
        let ref = SurfaceRef(surface: surface)
        outputQueue.async {
            _ = ghostty_surface_set_grid(ref.surface, c, r, generation)
        }
    }

    /// Starts over from a replay (vt-state / resized): full reset, then the
    /// replay bytes.
    func reset(with replay: Data) {
        var bytes = Data([0x1B, 0x63]) // RIS
        bytes.append(replay)
        feed(bytes)
    }

    // MARK: Viewport

    /// Moves Ghostty's viewport so `row` (0 = oldest scrollback row) is on top.
    func scrollViewport(toRow row: Int) {
        guard let surface else { return }
        let action = "scroll_to_row:\(max(0, row))"
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
        requestFrame()
    }

    func scrollViewportToBottom() {
        guard let surface else { return }
        let action = "scroll_to_bottom"
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
        requestFrame()
    }

    /// Text of the whole screen and scrollback (for copy and file references).
    func readAllText() -> String {
        guard let surface else { return "" }
        let action = "select_all"
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
        var text = ghostty_text_s()
        defer { ghostty_surface_free_text(surface, &text) }
        guard ghostty_surface_read_selection(surface, &text), let pointer = text.text else { return "" }
        let result = String(cString: pointer)
        _ = "clear_selection".withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
        return result
    }

    private func requestFrame() {
        guard let runtime, surface != nil else { return }
        runtime.requestDraw(self) { [weak self] in
            guard let self, let surface = self.surface else { return }
            ghostty_surface_refresh(surface)
            ghostty_surface_draw(surface)
        }
    }
}

/// Terminal display settings (Settings > Terminal).
enum TerminalPreferences {
    static var fontSize: Double {
        get { UserDefaults.standard.object(forKey: "terminal.fontSize") as? Double ?? 12 }
        set { UserDefaults.standard.set(newValue, forKey: "terminal.fontSize") }
    }
}
