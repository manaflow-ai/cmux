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
    /// A grid lock that arrived before the surface existed; applied first
    /// when it is created, in order with the queued output.
    private var pendingGrid: (cols: UInt16, rows: UInt16)?
    /// Render state for the debug overlay and the device log.
    private(set) var stats = TerminalSurfaceStats()

    /// Ghostty's scrollbar: total rows, top row of the viewport, viewport rows.
    var onScrollbar: ((Int, Int, Int) -> Void)?
    /// The surface exists and its cell metrics are known.
    var onReady: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.terminalBackground
        isOpaque = true
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Terminal")
        actions.onScrollbar = { [weak self] total, offset, length in
            guard let self else { return }
            self.stats.scrollbar = (total, offset, length)
            self.stats.scrollbarEvents += 1
            if self.stats.scrollbarEvents == 1 { debugLog("cmux-native: first scrollbar total=\(total) offset=\(offset) len=\(length)") }
            self.onScrollbar?(total, offset, length)
        }
        actions.onRendererHealth = { [weak self] healthy in
            guard let self, self.stats.rendererHealthy != healthy else { return }
            self.stats.rendererHealthy = healthy
            debugLog("cmux-native: renderer health \(healthy ? "healthy" : "UNHEALTHY")")
        }
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
        let runtime: GhosttyRuntime
        do { runtime = try GhosttyRuntime.shared() } catch {
            debugLog("cmux-native: ghostty runtime FAILED \(error)")
            stats.createFailure = "runtime: \(error)"
            return
        }
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
        debugLog("cmux-native: ghostty surface \(surface == nil ? "FAILED" : "created") scale=\(config.scale_factor) bounds=\(bounds)")
        stats.scale = config.scale_factor
        guard let surface else {
            stats.createFailure = "ghostty_surface_new returned nil"
            return
        }
        stats.createdAt = Date()
        ghostty_surface_set_occlusion(surface, true)
        ghostty_surface_set_focus(surface, true)
        stats.occluded = false
        stats.focused = true
        syncPixelSize()
        if let grid = pendingGrid {
            pendingGrid = nil
            setGrid(cols: Int(grid.cols), rows: Int(grid.rows))
        }
        let queued = pendingFeeds
        pendingFeeds.removeAll()
        stats.pendingFeeds = 0
        for data in queued { feed(data) }
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
        guard let surface else {
            pendingFeeds.append(data)
            stats.pendingFeeds = pendingFeeds.count
            return
        }
        stats.feeds += 1
        stats.feedBytes += data.count
        stats.lastFeed = Date()
        let feeds = stats.feeds
        if feeds <= 3 || feeds % 50 == 0 { debugLog("cmux-native: feed #\(feeds) \(data.count)B bounds=\(bounds) metrics=\(String(describing: cellSize))") }
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
        guard let c = UInt16(exactly: cols), let r = UInt16(exactly: rows), c > 0, r > 0 else { return }
        guard let surface else {
            // Before the surface exists: remember it (it used to be dropped,
            // leaving the grid unlocked at whatever fit the view).
            pendingGrid = (c, r)
            return
        }
        stats.gridRequests += 1
        gridGeneration += 1
        let generation = gridGeneration
        let ref = SurfaceRef(surface: surface)
        outputQueue.async {
            let accepted = ghostty_surface_set_grid(ref.surface, c, r, generation)
            if !accepted { debugLog("cmux-native: set_grid \(c)x\(r) gen \(generation) REFUSED") }
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

    /// Moves Ghostty's viewport so `row` (0 = oldest scrollback row) is on
    /// top. `now` ticks and draws in this pass instead of the next tick;
    /// the scroll controller times the view's row move to the draw (see
    /// `TerminalScrollSync`).
    func scrollViewport(toRow row: Int, now: Bool) {
        bindingAction("scroll_to_row:\(max(0, row))", now: now)
    }

    func scrollViewportToBottom(now: Bool) {
        bindingAction("scroll_to_bottom", now: now)
    }

    private func bindingAction(_ action: String, now: Bool) {
        guard let surface else { return }
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
        if now { stats.syncDraws += 1 }
        requestFrame(now: now)
    }

    /// VoiceOver reads what is on screen (only computed when VoiceOver asks).
    override var accessibilityValue: String? {
        get {
            let lines = readText(GHOSTTY_POINT_VIEWPORT).split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return lines.isEmpty ? String(localized: "Empty") : lines.joined(separator: "\n")
        }
        set {}
    }

    /// Text of the whole screen and scrollback (for copy and file references).
    func readAllText() -> String { readText(GHOSTTY_POINT_SCREEN) }

    /// Reads a region without touching the selection. (Select-all + read
    /// selection left the whole terminal highlighted whenever VoiceOver or
    /// Copy All Text read it.)
    private func readText(_ tag: ghostty_point_tag_e) -> String {
        guard let surface else { return "" }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    /// Asks for a draw on the next runtime tick, or (`now`) ticks and draws
    /// in this pass.
    private func requestFrame(now: Bool = false) {
        guard let runtime, surface != nil else { return }
        runtime.requestDraw(self, now: now) { [weak self] in
            guard let self, let surface = self.surface else { return }
            ghostty_surface_refresh(surface)
            ghostty_surface_draw(surface)
            self.stats.draws += 1
            self.stats.lastDraw = Date()
            if self.stats.draws == 1 { debugLog("cmux-native: first draw \(self.diagnosticsLines().joined(separator: " | "))") }
        }
    }

    /// Asks Ghostty to draw again (the debug overlay's redraw button and
    /// recovery after the view returns to a window).
    func redraw() { requestFrame() }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if window != nil { requestFrame() }
    }

    // MARK: Diagnostics

    /// The surface's render state, one fact per line.
    func diagnosticsLines() -> [String] {
        var lines: [String] = []
        if let createdAt = stats.createdAt {
            lines.append("surface: created \(createdAt.ago) scale \(stats.scale) window \(window != nil ? "yes" : "NO")")
        } else {
            lines.append("surface: NOT CREATED \(stats.createFailure ?? "(no window yet)") pending feeds \(stats.pendingFeeds)")
        }
        lines.append(String(format: "view: frame %.0f,%.0f %.0fx%.0f hidden %@ alpha %.2f", frame.minX, frame.minY, frame.width, frame.height,
                            isHidden ? "YES" : "no", alpha))
        if let surface {
            let size = ghostty_surface_size(surface)
            let grid = ghostty_surface_grid(surface)
            lines.append("px: \(size.width_px)x\(size.height_px) fit \(size.columns)x\(size.rows) cell px \(size.cell_width_px)x\(size.cell_height_px)")
            lines.append("grid: \(grid.locked ? "locked" : "UNLOCKED") \(grid.columns)x\(grid.rows) gen \(grid.generation) requests \(stats.gridRequests)")
            var metrics = ghostty_surface_grid_metrics_s()
            if ghostty_surface_grid_metrics(surface, &metrics) {
                lines.append(String(format: "cell pt: %.2fx%.2f pad %.1f,%.1f cursor %d,%d %@", metrics.cell_width, metrics.cell_height,
                                    metrics.padding_left, metrics.padding_top, Int(metrics.cursor_column), Int(metrics.cursor_row),
                                    metrics.cursor_in_viewport ? "visible" : "off-viewport"))
            } else {
                lines.append("cell pt: metrics unavailable")
            }
            if let sublayers = layer.sublayers, let hosted = sublayers.first(where: { $0.contents != nil }) ?? sublayers.first {
                lines.append(String(format: "layer: %.0fx%.0f scale %.1f contents %@ sublayers %d", hosted.bounds.width, hosted.bounds.height,
                                    hosted.contentsScale, hosted.contents == nil ? "NONE" : "set", sublayers.count))
            } else {
                lines.append("layer: NO IOSurface sublayer")
            }
        }
        lines.append("feeds \(stats.feeds) \(ByteCountFormatter.string(fromByteCount: Int64(stats.feedBytes), countStyle: .binary))"
                     + " last \(stats.lastFeed?.ago ?? "never")")
        lines.append("draws \(stats.draws) (scroll \(stats.syncDraws)) last \(stats.lastDraw?.ago ?? "never") renderer \(stats.rendererHealthy ? "ok" : "UNHEALTHY")")
        let bar = stats.scrollbar
        lines.append("scrollbar total \(bar.total) offset \(bar.offset) len \(bar.length) events \(stats.scrollbarEvents)")
        return lines
    }
}

/// Terminal display settings (Settings > Terminal).
enum TerminalPreferences {
    static var fontSize: Double {
        get { UserDefaults.standard.object(forKey: "terminal.fontSize") as? Double ?? 12 }
        set { UserDefaults.standard.set(newValue, forKey: "terminal.fontSize") }
    }
}

