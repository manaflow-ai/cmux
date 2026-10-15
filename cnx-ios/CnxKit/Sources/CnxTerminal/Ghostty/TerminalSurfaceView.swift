#if os(iOS)
import CnxDesign
import CoreImage
import Foundation
import GameController
import GhosttyNextKit
import IOSurface
import UIKit
import UniformTypeIdentifiers

/// One Ghostty surface in mirror mode (adapted from CmuxiOSTerminal's
/// GhosttyTerminalView). The phone owns no PTY: session output arrives through
/// `feed`, and everything typed leaves through `onInput`, encoded by Ghostty.
///
/// The screen owns the viewport: it sizes the surface to a whole number of
/// rows plus a margin, asks Ghostty for a viewport row with `scroll(toRow:)`,
/// and places the surface in a scroll view only when a frame for that row is
/// presented (`onPresent`), so the rows on screen and the surface position
/// always change in the same Core Animation transaction. Ghostty rebuilds
/// cells on its renderer thread, so a frame for a new viewport arrives a few
/// milliseconds after the request; the margin keeps the visible rows covered
/// by the previous frame until then.
@MainActor
final class TerminalSurfaceView: UIView {
    var onInput: ((Data) -> Void)?
    /// The person typed, pressed a key or pasted (before the bytes go out).
    var onUserInput: (() -> Void)?
    var onEvent: ((TerminalSurfaceEvent) -> Void)?
    /// The surface became first responder (direct typing) or resigned.
    var onFocusChange: ((Bool) -> Void)?
    /// The sticky modifier state changed (the key bar shows it).
    var onStickyChange: ((TerminalStickyModifiers) -> Void)?

    private(set) var surface: ghostty_surface_t?
    var input = TerminalInputRouter() {
        didSet { if input.sticky != oldValue.sticky { onStickyChange?(input.sticky) } }
    }
    weak var inputDelegate: (any UITextInputDelegate)?
    var handledPresses: [ObjectIdentifier: [TerminalInputAction]] = [:]
    var keyboardKind: UIKeyboardType = .asciiCapable

    private var app: CnxGhosttyApp?
    private let outputQueue = DispatchQueue(label: "cnx.terminal.output", qos: .userInteractive)
    private var inputBox: InputBox?
    private var pendingOutput: [Data] = []
    private(set) var draws = 0
    /// The last row given to `scroll(toRow:)`.
    private var pinnedRow: Int?
    /// The font size the surface was built with or last set to (Settings → Terminal).
    private var fontSize = CnxPreferences.terminalFontSize()
    private var defaultsObserver: (any NSObjectProtocol)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = CnxGhosttyApp.background
        isOpaque = true
        isAccessibilityElement = true
        accessibilityLabel = "Terminal"
        accessibilityTraits = .allowsDirectInteraction
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        if let commitObserver { CFRunLoopObserverInvalidate(commitObserver) }
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        guard let surface else { return }
        let ref = SurfaceRef(surface)
        let box = inputBox.map(Retained.init)
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
        guard let app = try? CnxGhosttyApp.shared() else { return }
        self.app = app
        let box = InputBox()
        box.deliver = { [weak self] data in self?.onInput?(data) }
        box.view = self
        inputBox = box
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(box).toOpaque()
        config.scale_factor = Double(window?.screen.scale ?? 3)
        fontSize = CnxPreferences.terminalFontSize()
        config.font_size = Float(fontSize)
        config.io_mode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR
        config.io_write_userdata = Unmanaged.passUnretained(box).toOpaque()
        config.io_write_cb = { userdata, bytes, length in
            guard let userdata, let bytes, length > 0 else { return }
            let data = Data(bytes: bytes, count: Int(length))
            let box = Unmanaged<InputBox>.fromOpaque(userdata).takeUnretainedValue()
            if Thread.isMainThread {
                MainActor.assumeIsolated { box.deliver?(data) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { box.deliver?(data) } }
            }
        }
        surface = ghostty_surface_new(app.app, &config)
        guard let surface else { return }
        // Visible: Ghostty's renderer thread rebuilds cells and presents frames.
        ghostty_surface_set_occlusion(surface, true)
        ghostty_surface_set_focus(surface, true)
        syncSize()
        let queued = pendingOutput
        pendingOutput.removeAll()
        for data in queued { feed(data) }
        onEvent?(.cellSize)
        observePresents()
        observeFontSize()
    }

    /// Settings → Terminal → Font size applies to open terminals at once:
    /// Ghostty re-measures its cells and reports the new cell size, and the
    /// screen re-fits the grid from it.
    private func observeFontSize() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyFontSize() }
        }
    }

    private func applyFontSize() {
        let size = CnxPreferences.terminalFontSize()
        guard let surface, size != fontSize else { return }
        fontSize = size
        viewportEpoch += 1
        let action = "set_font_size:\(size)"
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
        ghostty_surface_refresh(surface)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncSize()
        observePresents()
    }

    private var lastPixelSize: (UInt32, UInt32) = (0, 0)

    /// Bumped by everything here that can move Ghostty's viewport (a scroll
    /// binding, a resize, a font size): a frame after a bump may show
    /// another viewport, so its placement is read from its pixels again.
    private(set) var viewportEpoch = 0

    private func syncSize() {
        guard let surface, let window else { return }
        let scale = window.screen.scale
        let size = (UInt32(bounds.width * scale), UInt32(bounds.height * scale))
        guard size.0 > 0, size.1 > 0, size != lastPixelSize else { return }
        lastPixelSize = size
        viewportEpoch += 1
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, size.0, size.1)
        if let pinnedRow { scrollViewport(pinnedRow) }
        drawNow()
    }

    #if DEBUG
    /// DEBUG (termqa round 8): reads one row by each Ghostty point tag, to
    /// pin down which numbering each one uses.
    func debugReadRow(tag: ghostty_point_tag_e, y: Int, rectangle: Bool = false) -> String? {
        guard let surface else { return nil }
        let columns = max(1, grid.columns)
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(max(0, y))),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(columns - 1), y: UInt32(max(0, y))),
            rectangle: rectangle
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    /// DEBUG: the whole screen as a rectangle selection (one line per row?).
    func debugScreenRectangle() -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: true
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }
    #endif

    // MARK: Metrics

    /// Cell size in points (zero before the surface exists).
    var cellSize: CGSize {
        guard let surface else { return .zero }
        var metrics = ghostty_surface_grid_metrics_s()
        if ghostty_surface_grid_metrics(surface, &metrics), metrics.cell_height > 0 {
            return CGSize(width: metrics.cell_width, height: metrics.cell_height)
        }
        let size = ghostty_surface_size(surface)
        let scale = window?.screen.scale ?? 3
        return CGSize(width: CGFloat(size.cell_width_px) / scale, height: CGFloat(size.cell_height_px) / scale)
    }

    /// The whole screen (scrollback and active area) as text. Ghostty joins
    /// the rows it soft-wrapped, so a long path reads as one line. Takes the
    /// surface lock: call it on demand (Files and Links), never per frame.
    func screenText() -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    /// The grid's padding inside the surface (points): where cell (0, 0) starts.
    var gridPadding: CGPoint {
        guard let surface else { return .zero }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics) else { return .zero }
        return CGPoint(x: metrics.padding_left, y: metrics.padding_top)
    }

    /// Plain text from `start` to `end` in viewport rows (0 = the top row of
    /// Ghostty's viewport, the surface's first row), inclusive, for a
    /// selection's Copy. Viewport rows, not screen rows: a screen point's y
    /// does not count the rows the scrollbar's total does (round 7: screen y
    /// 109 was absolute row 305). Takes the surface lock: on demand only.
    func viewportText(from start: TerminalCellPoint, to end: TerminalCellPoint) -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                      x: UInt32(max(0, start.column)), y: UInt32(max(0, start.row))),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                          x: UInt32(max(0, end.column)), y: UInt32(max(0, end.row))),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    /// Blank rows at the top of the screen (absolute rows `0...lastRow`):
    /// the mirror's rows above the remote screen that nothing ever wrote
    /// (`TerminalRowShift` puts the Mac's screen at the bottom of the taller
    /// mirror). Ghostty's plain formatter writes one newline per blank row
    /// before the first row with text, so the count is the number of leading
    /// newlines; an all-blank range reads as empty (returns `lastRow + 1`).
    /// Reads at most `lastRow + 1` rows under the surface lock.
    func leadingBlankRows(through lastRow: Int) -> Int? {
        guard let surface, lastRow >= 0 else { return nil }
        let columns = max(1, grid.columns)
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_EXACT,
                                          x: UInt32(columns - 1), y: UInt32(lastRow)),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return lastRow + 1 }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len))
        return TerminalDocumentLayout.leadingNewlines(in: bytes, limit: lastRow + 1)
    }

    /// Plain text of the active screen's rows `0...lastRow` (the alternate
    /// screen in a TUI). Takes the surface lock: on demand only.
    func screenRowsText(through lastRow: Int) -> String? {
        guard let surface, lastRow >= 0 else { return nil }
        let columns = max(1, grid.columns)
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_EXACT,
                                          x: UInt32(columns - 1), y: UInt32(lastRow)),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    /// The lowest row with text in `top...bottom` (absolute rows), reading one
    /// row at a time from the bottom: rows below the cursor that an inline
    /// TUI draws (hints, status). Nil when all are blank.
    /// Plain text of one absolute row (0 = oldest scrollback row).
    func rowText(_ row: Int) -> String? {
        guard let surface, row >= 0 else { return nil }
        let columns = max(1, grid.columns)
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(row)),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_EXACT,
                                          x: UInt32(columns - 1), y: UInt32(row)),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    func lastNonBlankRow(from top: Int, through bottom: Int) -> Int? {
        guard surface != nil, top <= bottom else { return nil }
        for row in stride(from: bottom, through: top, by: -1) {
            guard let surface else { return nil }
            let columns = max(1, grid.columns)
            let selection = ghostty_selection_s(
                top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(row)),
                bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_EXACT,
                                              x: UInt32(columns - 1), y: UInt32(row)),
                rectangle: false
            )
            var text = ghostty_text_s()
            guard ghostty_surface_read_text(surface, selection, &text) else { continue }
            defer { ghostty_surface_free_text(surface, &text) }
            if let pointer = text.text, text.text_len > 0 {
                let bytes = UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len))
                if bytes.contains(where: { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }) { return row }
            }
        }
        return nil
    }

    /// Columns and rows of the local grid.
    var grid: (columns: Int, rows: Int) {
        guard let surface else { return (0, 0) }
        let size = ghostty_surface_size(surface)
        return (Int(size.columns), Int(size.rows))
    }

    /// The cursor's absolute row (0 = oldest scrollback row) given Ghostty's
    /// total rows, when the cursor is in the viewport; nil otherwise. It no
    /// longer moves the viewport to the active area to look: Ghostty renders
    /// on its own thread and could present a frame of the active area in
    /// between, which the page showed for a frame over the rows being read
    /// (user reports 2026-10-14, frames of another region while scrolling).
    func cursorAbsoluteRow(totalRows: Int) -> Int? {
        guard surface != nil, let row = cursorViewportRow else { return nil }
        let activeTop = max(0, totalRows - grid.rows)
        return min(pinnedRow ?? activeTop, activeTop) + row
    }

    /// The cursor's cell in this view's coordinates, when it is in the viewport.
    var visibleCursorCell: CGRect? {
        guard let surface else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), metrics.cursor_in_viewport, metrics.cell_height > 0 else { return nil }
        return CGRect(x: metrics.padding_left + Double(metrics.cursor_column) * metrics.cell_width,
                      y: metrics.padding_top + Double(metrics.cursor_row) * metrics.cell_height,
                      width: metrics.cell_width * Double(max(1, metrics.cursor_width_cells)),
                      height: metrics.cell_height)
    }

    /// The cursor row relative to the viewport top, when the cursor is in the viewport.
    var cursorViewportRow: Int? {
        guard let surface else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), metrics.cursor_in_viewport else { return nil }
        return Int(metrics.cursor_row)
    }

    // MARK: Output and drawing

    /// Feeds one batch of session output on the output queue (never the
    /// main thread). `transform` (the row shift) runs there first, in feed
    /// order. `completion` runs on the main thread once Ghostty parsed the
    /// batch, after a draw was requested. The screen keeps one batch in
    /// flight (`TerminalViewController`'s output pump).
    func feed(_ data: Data, transform: (@Sendable (Data) -> Data)? = nil, completion: (@MainActor () -> Void)? = nil) {
        guard let surface else {
            pendingOutput.append(transform?(data) ?? data)
            completion?()
            return
        }
        let ref = SurfaceRef(surface)
        let done = completion.map(MainCallback.init)
        outputQueue.async {
            let bytes = transform?(data) ?? data
            bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                ghostty_surface_process_output(ref.surface, base, UInt(raw.count))
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
                // Ghostty also renders on its own after parsing, but later:
                // without this request a keystroke echo waited ~3x longer.
                self?.setNeedsTerminalDraw()
                done?.run()
            } }
        }
    }

    /// Asks Ghostty to move the viewport so `row` (0 = oldest scrollback row)
    /// is its top row. The frame for it is presented asynchronously (`onPresent`).
    func scroll(toRow row: Int) {
        guard let surface else { return }
        pinnedRow = row
        scrollViewport(row)
        ghostty_surface_refresh(surface)
    }

    /// Moves Ghostty's viewport to the active area; it re-renders and
    /// reports its scrollbar (used after leaving the alternate screen).
    func scrollToActiveArea() {
        guard let surface else { return }
        viewportEpoch += 1
        let action = "scroll_to_bottom"
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
        ghostty_surface_refresh(surface)
    }

    private func scrollViewport(_ row: Int) {
        guard let surface else { return }
        viewportEpoch += 1
        let action = "scroll_to_row:\(max(0, row))"
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
    }

    /// Asks the renderer for a frame.
    func setNeedsTerminalDraw() {
        guard let surface else { return }
        ghostty_surface_refresh(surface)
    }

    /// Draws now on the main thread from the current cells (resize, mode changes).
    func drawNow() {
        guard let surface else { return }
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
        draws += 1
    }

    /// Called on the main thread in the transaction that shows a new frame.
    var onPresent: (() -> Void)?

    /// The frame Ghostty presented last, as an image, and where its layer
    /// sits in this view. `drawHierarchy` leaves the Metal surface black in a
    /// snapshot taken while the page is live on screen (the active grid card,
    /// V5-6), so the snapshot draws this instead.
    func presentedImage() -> (image: CGImage, frame: CGRect)? {
        guard let sublayer = layer.sublayers?.first, let contents = sublayer.contents else { return nil }
        let ref = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
        guard CFGetTypeID(ref) == IOSurfaceGetTypeID() else { return nil }
        let ioSurface = unsafeBitCast(ref, to: IOSurface.self)
        let image = CIImage(ioSurface: ioSurface)
        guard !image.extent.isEmpty, let cgImage = Self.snapshotContext.createCGImage(image, from: image.extent) else { return nil }
        return (cgImage, sublayer.frame)
    }

    private static let snapshotContext = CIContext(options: [.cacheIntermediates: false])

    /// One hash per cell row of the frame on screen (`rowHeight` px rows),
    /// sampled from the IOSurface Ghostty presented: two pixel lines through
    /// the glyphs, every third pixel. The screen matches consecutive frames'
    /// rows to learn which viewport a frame shows, whatever order Ghostty's
    /// frames and reports arrive in.
    /// `band`: only these rows are read; the others are
    /// `TerminalPresentMatch.unread` (following reads the rows on screen).
    func presentedRowSignatures(rowHeight: Int, band: Range<Int>? = nil) -> [UInt64]? {
        guard rowHeight > 2, let contents = layer.sublayers?.first?.contents else { return nil }
        let surface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
        guard CFGetTypeID(surface) == IOSurfaceGetTypeID() else { return nil }
        let bytesPerElement = IOSurfaceGetBytesPerElement(surface)
        guard bytesPerElement == 4 || bytesPerElement == 8 else { return nil }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let rows = height / rowHeight
        var result = [UInt64](repeating: TerminalPresentMatch.unread, count: rows)
        let read = band.map { $0.clamped(to: 0..<rows) } ?? 0..<rows
        // Pointer walk, no allocation per row: this runs for every presented
        // frame on the main thread. Same samples and hash as before: green
        // channel high nibble, every third pixel, two lines per row.
        let stride = 3 * bytesPerElement
        let lineBytes = width * bytesPerElement
        func sample(_ y: Int, into hash: inout UInt64) {
            guard y < height else { return }
            var pointer = base + y * bytesPerRow + 1
            let end = pointer + lineBytes
            while pointer < end {
                hash = (hash ^ UInt64(pointer.pointee >> 4)) &* 0x0000_0100_0000_01B3 // a high nibble survives blending noise
                pointer += stride
            }
        }
        result.withUnsafeMutableBufferPointer { out in
            for row in read {
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                sample(row * rowHeight + rowHeight / 2, into: &hash)
                sample(row * rowHeight + rowHeight * 3 / 4, into: &hash)
                out[row] = hash == TerminalPresentMatch.unread ? 1 : hash
            }
        }
        return result
    }
    private(set) var presents = 0
    private var contentsObservation: NSKeyValueObservation?

    /// Ghostty's layer sets `contents` on the main thread for each presented
    /// frame (the probe in verify/terminal.md found no off-main sets).
    private weak var observedLayer: CALayer?

    private func observePresents() {
        guard let layer = layer.sublayers?.first, layer !== observedLayer else { return }
        observedLayer = layer
        contentsObservation = layer.observe(\.contents, options: []) { [weak self] _, _ in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.presents += 1
                self.presentPending = true
                self.observeCommits()
            }
        }
    }

    /// Ghostty can set `contents` more than once in one Core Animation
    /// transaction; only the last is ever displayed. The screen handles the
    /// present once, just before the transaction commits (a run loop
    /// observer ordered before Core Animation's commit), so the surface moves
    /// in the same transaction and the pixels it reads are the frame shown.
    /// (termqa D7: two presents 1 ms apart read a frame never displayed and
    /// then matched nothing; it also halves the reads in a busy stream.)
    private var presentPending = false
    private var commitObserver: CFRunLoopObserver?

    private func observeCommits() {
        guard commitObserver == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
                                                          true, 1_999_000) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.presentPending else { return }
                self.presentPending = false
                self.onPresent?()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        commitObserver = observer
    }

    func requestRedraw() { setNeedsTerminalDraw() }

    func receive(_ event: TerminalSurfaceEvent) {
        onEvent?(event)
    }

    // MARK: Input entry points for the key bar and the composer

    /// Sends the router's actions for a key bar key.
    func sendKey(usage: UInt16, mods: TerminalKeyMods = []) {
        perform(input.key(usage: usage, extra: mods))
    }

    func sendControl(_ letter: Character) {
        perform(input.control(letter))
    }

    func tapSticky(_ modifier: TerminalStickyModifiers.Modifier) {
        input.tapSticky(modifier, at: ProcessInfo.processInfo.systemUptime)
    }

    /// The composer's draft as one paste (bracketed when the program asked
    /// for it), then Return as its own keystroke a moment later
    /// (`ComposerSubmit`, Codex QA F1).
    func sendText(_ text: String, pressReturn: Bool) {
        perform(ComposerSubmit(text: text, pressReturn: pressReturn))
    }

    func perform(_ submit: ComposerSubmit) {
        for step in submit.steps {
            switch step {
            case .paste(let draft):
                perform([.paste(draft)])
            case .enter where submit.delaysEnter:
                Task { @MainActor [weak self] in
                    try? await ContinuousClock().sleep(for: ComposerSubmit.enterDelay)
                    self?.sendKey(usage: TerminalHIDUsage.enter)
                }
            case .enter:
                sendKey(usage: TerminalHIDUsage.enter)
            }
        }
    }

    // MARK: Responder

    override var canBecomeFirstResponder: Bool { true }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            if input.markedText != nil { perform(input.setMarkedText(nil)) }
            onFocusChange?(false)
        }
        return resigned
    }

    override var keyCommands: [UIKeyCommand]? { navigationKeyCommands() }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = beginPresses(presses)
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = endPresses(presses)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = endPresses(presses)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return UIPasteboard.general.hasStrings }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        perform([.paste(text)])
    }

    // MARK: Paste control (Codex QA F14)

    /// What the key bar's system paste control may hand this view: text.
    /// A tap on a `UIPasteControl` is the person's explicit paste, so iOS
    /// asks nothing ("Allow Paste" appeared for every new clipboard when the
    /// key read the pasteboard itself).
    func configurePasteControlTarget() {
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.plainText.identifier, UTType.utf8PlainText.identifier])
    }

    override func paste(itemProviders: [NSItemProvider]) {
        for provider in itemProviders where provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
                guard let text = object as? String, !text.isEmpty else { return }
                DispatchQueue.main.async { self?.perform([.paste(text)]) }
            }
            return
        }
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        itemProviders.contains { $0.canLoadObject(ofClass: NSString.self) }
    }
}

/// A main-thread callback carried through the output queue.
private struct MainCallback: @unchecked Sendable {
    let body: @MainActor () -> Void
    init(_ body: @escaping @MainActor () -> Void) { self.body = body }
    @MainActor func run() { body() }
}

struct SurfaceRef: @unchecked Sendable {
    let surface: ghostty_surface_t
    init(_ surface: ghostty_surface_t) { self.surface = surface }
}

@MainActor
/// The surface's userdata for both callbacks. It outlives the view (it is
/// released only after `ghostty_surface_free`, which runs asynchronously
/// after the view's deinit), so actions Ghostty delivers in between find a
/// nil `view` instead of a dangling pointer.
final class InputBox {
    var deliver: ((Data) -> Void)?
    weak var view: TerminalSurfaceView?
}

private struct Retained: @unchecked Sendable {
    let object: AnyObject
    init(_ object: AnyObject) { self.object = object }
}
#endif
