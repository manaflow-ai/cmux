#if os(iOS)
import CNDesign
import Foundation
import GameController
import GhosttyNextKit
import UIKit

/// One visible terminal drawn by ghostty-next in mirror mode, adapted from
/// the cmux iOS wrapper (CmuxiOSTerminal/Ghostty/GhosttyTerminalView.swift).
/// A plain UIView: Ghostty adds and sizes its own Metal layer; there is no
/// display link on iOS, the renderer draws on change. The phone owns no PTY:
/// host output arrives through `feed`, and everything the user types leaves
/// through `onInput`, encoded by Ghostty with the mirrored terminal modes.
@MainActor
final class GhosttyTerminalView: UIView {
    var onInput: ((Data) -> Void)?
    /// The terminal drew a frame (the cursor or the fitting grid may have changed).
    var onDraw: (() -> Void)?
    /// The surface exists (the view has a window).
    var onReady: (() -> Void)?

    private(set) var surface: ghostty_surface_t?
    /// Keyboard input state (sticky modifiers, marked text); client view state.
    var input = TerminalInputRouter()
    /// UIKit's text input delegate (`UITextInput`).
    weak var inputDelegate: (any UITextInputDelegate)?
    /// Hardware presses the router sent, by press, until their release.
    var handledPresses: [ObjectIdentifier: [TerminalInputAction]] = [:]
    /// The software keyboard (`.asciiCapable`; the default keyboard allows
    /// non-Latin input).
    var keyboardKind: UIKeyboardType = .asciiCapable
    /// The key bar the controller shows above the keyboard; it mirrors the
    /// sticky modifiers. Not an input accessory view: the controller pins it
    /// (and the composer) to the keyboard layout guide so the terminal's
    /// visible bottom is measured against it.
    weak var keyBarView: TerminalKeyBar?
    /// First responder gained (true) or lost (false).
    var onFocusChange: ((Bool) -> Void)?
    private var keyboardObservers: [any NSObjectProtocol] = []
    private var app: GhosttyApp?
    /// The output functions (process_output, set_grid) run here: one serial
    /// queue, never the main thread (ghostty-next threading contract).
    private let outputQueue = DispatchQueue(label: "cmux.next.terminal.output", qos: .userInteractive)
    private var inputBox: InputBox?
    private(set) var draws = 0
    private let framePending = FramePending()
    /// DEBUG: live Ghostty renderers (full terminal views).
    static var liveCount = 0
    private var contentRowComputedAt: CFTimeInterval = 0
    private var contentRowCache: (draws: Int, value: (row: Int, cellHeight: CGFloat, paddingTop: CGFloat)?)?
    private var appliedStyle: UIUserInterfaceStyle?
    /// The drawable size and scale last given to the surface.
    private var appliedSize: (width: UInt32, height: UInt32, scale: CGFloat)?
    /// The text size in points (setting `cmuxNext.terminalFontSize`).
    private(set) var fontSize: Double = TerminalFontSize.stored
    /// A pinch owns the text size until it ends.
    var pinching = false
    /// False while the controller fits the text size to a Mac-owned grid.
    var followsStoredFontSize = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = CNTheme.shared.palette.terminalBackground
        isOpaque = true
        isAccessibilityElement = true
        accessibilityLabel = TerminalText.terminalLabel
        accessibilityIdentifier = "terminal.surface"
        accessibilityTraits = .allowsDirectInteraction
        // The key bar hides while a hardware keyboard is attached (device only).
        for name in [NSNotification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            keyboardObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.reloadInputViews() }
            })
        }
        // The settings screen writes the text size to the same defaults key.
        keyboardObservers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.pinching, self.followsStoredFontSize else { return }
                self.setFontSize(TerminalFontSize.stored)
            }
        })
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: GhosttyTerminalView, _) in
            view.applyTheme()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        for observer in keyboardObservers { NotificationCenter.default.removeObserver(observer) }
        guard let surface else { return }
        Self.liveCount -= 1
        TerminalMemory.log()
        // Free only after every queued process_output returned (contract), and
        // keep the input box alive until free returns (io_write_cb may run).
        let ref = SurfaceRef(surface)
        let box = inputBox.map(Retained.init)
        outputQueue.async {
            DispatchQueue.main.async {
                ghostty_surface_free(ref.surface)
                _ = box
            }
        }
    }

    /// Creates the surface once the view has a window (its scale is known).
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, surface == nil { createSurface() }
        applyOcclusion()
    }

    /// Whether the renderer draws (true) or keeps showing its last frame
    /// (false, for example while a static card stands in for it). A view
    /// out of a window never draws: a kept renderer would otherwise draw a
    /// Metal frame on every output change while nobody sees it.
    var rendering = true {
        didSet { if rendering != oldValue { applyOcclusion() } }
    }

    private var appliedVisible: Bool?

    private func applyOcclusion() {
        guard let surface else { return }
        let visible = rendering && window != nil
        guard visible != appliedVisible else { return }
        appliedVisible = visible
        ghostty_surface_set_occlusion(surface, visible)
        if visible { requestFrame() }
    }

    /// Diagnostics of the surface (app, surface, draws, grid).
    private(set) var diagnostics: [String: String] = [:]

    private func createSurface() {
        let app: GhosttyApp
        do { app = try GhosttyApp.shared() } catch {
            diagnostics["app"] = "failed: \(error)"
            return
        }
        diagnostics["app"] = "ok"
        diagnostics["config_diagnostics"] = String(app.configDiagnostics)
        self.app = app
        let box = InputBox()
        box.deliver = { [weak self] data in self?.onInput?(data) }
        inputBox = box
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(self).toOpaque()))
        config.scale_factor = Double(window?.screen.scale ?? 3)
        config.font_size = Float(fontSize)
        config.io_mode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR
        config.io_write_userdata = Unmanaged.passUnretained(box).toOpaque()
        config.io_write_cb = { userdata, bytes, length in
            guard let userdata, let bytes, length > 0 else { return }
            // Ghostty may call this while it holds the surface's terminal lock
            // (inside ghostty_surface_key / _mouse_scroll / _mouse_pos on the
            // main thread). Nothing here may call back into the surface: the
            // bytes are copied into the box and delivered after the call
            // returns, in order, coalesced per main-queue turn.
            Unmanaged<InputBox>.fromOpaque(userdata).takeUnretainedValue().enqueue(bytes, Int(length))
        }
        surface = ghostty_surface_new(app.app, &config)
        appliedSize = nil
        if surface != nil { Self.liveCount += 1; TerminalMemory.log() }
        diagnostics["surface"] = surface == nil ? "nil" : "ok"
        if let surface {
            // Visible and focused: the renderer draws only for a visible surface.
            appliedVisible = nil
            applyOcclusion()
            ghostty_surface_set_focus(surface, true)
        }
        applyTheme()
        syncSize()
        requestFrame()
        onReady?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncSize()
    }

    private func syncSize() {
        guard let surface, let window else { return }
        let scale = window.screen.scale
        guard let pixels = Self.drawablePixels(bounds.size, scale: scale) else { return }
        // Layout passes that keep the size (the view moving with the tab
        // grid's scroll, a zoom scaling it) need no new drawable and no
        // frame: redrawing on each made the live terminal card render (and
        // allocate surfaces) on every scroll frame.
        if let applied = appliedSize, applied.width == pixels.width, applied.height == pixels.height, applied.scale == scale { return }
        appliedSize = (pixels.width, pixels.height, scale)
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, pixels.width, pixels.height)
        requestFrame()
    }

    /// The largest drawable side in pixels. A Mac-sized grid at a large text
    /// size could otherwise ask Metal for a texture past the device limit.
    static let maxDrawablePixels: CGFloat = 8192

    /// Pixel size for Ghostty, or nil while the size is empty or not finite
    /// (a transient layout during a zoom); never traps on conversion.
    static func drawablePixels(_ size: CGSize, scale: CGFloat) -> (width: UInt32, height: UInt32)? {
        let w = size.width * scale, h = size.height * scale
        guard w.isFinite, h.isFinite, w >= 1, h >= 1 else { return nil }
        return (UInt32(min(w, maxDrawablePixels)), UInt32(min(h, maxDrawablePixels)))
    }

    /// Applies the Apple System Colors config for the current interface style.
    private func applyTheme() {
        backgroundColor = CNTheme.shared.palette.terminalBackground.resolvedColor(with: traitCollection)
        guard let surface, let app else { return }
        let style: UIUserInterfaceStyle = traitCollection.userInterfaceStyle == .light ? .light : .dark
        guard style != appliedStyle else { return }
        appliedStyle = style
        ghostty_surface_set_color_scheme(surface, style == .light ? GHOSTTY_COLOR_SCHEME_LIGHT : GHOSTTY_COLOR_SCHEME_DARK)
        ghostty_surface_update_config(surface, app.config(for: style))
        // A config update may reset the text size to the config's; keep ours.
        applyFontSize(fontSize)
        diagnostics["theme"] = style == .light ? "light" : "dark"
        requestFrame()
    }

    /// Draws again (marked text changed).
    func requestRedraw() { requestFrame() }

    private func requestFrame() {
        guard let app, surface != nil else { return }
        app.requestDraw(self) { [weak self] in
            guard let self, let surface = self.surface else { return }
            ghostty_surface_refresh(surface)
            ghostty_surface_draw(surface)
            self.draws += 1
            let size = ghostty_surface_size(surface)
            self.diagnostics["draws"] = String(self.draws)
            self.diagnostics["grid"] = "\(size.columns)x\(size.rows) px \(size.width_px)x\(size.height_px)"
            self.onDraw?()
        }
    }

    // MARK: Output (host PTY bytes)

    /// Parses host output on the output queue, in call order, then redraws.
    func feed(_ bytes: Data) {
        enqueueOutput { surface in
            bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                ghostty_surface_process_output(surface, base, UInt(raw.count))
            }
        }
    }

    /// Clears the screen, scrollback and modes before a scrollback replay
    /// (RIS, then erase saved lines).
    func resetTerminal() {
        feed(Data("\u{1B}c\u{1B}[3J\u{1B}[H\u{1B}[2J".utf8))
    }

    /// Locks the grid to the host's size, in order with the output.
    func setGrid(cols: Int, rows: Int, generation: UInt64) {
        guard let c = UInt16(exactly: cols), let r = UInt16(exactly: rows), c > 0, r > 0 else { return }
        enqueueOutput { surface in
            _ = ghostty_surface_set_grid(surface, c, r, generation)
        }
    }

    /// Locks a grid and reports, in order with the output, how many rows the
    /// content moved down (Ghostty brings scrollback back when rows grow).
    func setGrid(cols: Int, rows: Int, generation: UInt64, measured: @escaping @MainActor @Sendable (Int, CGFloat) -> Void) {
        guard let c = UInt16(exactly: cols), let r = UInt16(exactly: rows), c > 0, r > 0 else { return }
        enqueueOutput { surface in
            func cursor() -> (Int, Double)? {
                var m = ghostty_surface_grid_metrics_s()
                guard ghostty_surface_grid_metrics(surface, &m), m.cursor_in_viewport else { return nil }
                return (Int(m.cursor_row), m.cell_height)
            }
            let before = cursor()
            _ = ghostty_surface_set_grid(surface, c, r, generation)
            let after = cursor()
            let rows = (before != nil && after != nil) ? max(0, after!.0 - before!.0) : 0
            let cell = CGFloat(after?.1 ?? before?.1 ?? 0)
            DispatchQueue.main.async { MainActor.assumeIsolated { measured(rows, cell) } }
        }
    }

    private func enqueueOutput(_ work: @escaping @Sendable (ghostty_surface_t) -> Void) {
        guard let surface else { return }
        let ref = SurfaceRef(surface)
        let pending = framePending
        outputQueue.async {
            work(ref.surface)
            // One main-actor hop per burst, not per chunk: fast TUI redraws
            // must not queue main-thread work proportional to output.
            guard pending.claim() else { return }
            Task { @MainActor [weak self] in
                pending.release()
                self?.requestFrame()
            }
        }
    }

    /// The renderer's last frame (what is on screen), scaled to at most
    /// `maxPixelWidth`; nil before the first frame.
    func snapshot(maxPixelWidth: CGFloat? = nil) -> UIImage? {
        guard let cg = GhosttySnapshot.image(of: self, maxPixelWidth: maxPixelWidth) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Reads the visible rows' text on the output queue (in order with the
    /// output), then calls back on the main actor.
    func readVisibleLines(_ done: @escaping @MainActor ([String], (cols: Int, rows: Int)) -> Void) {
        guard let surface else { return }
        let ref = SurfaceRef(surface)
        outputQueue.async {
            let grid = ghostty_surface_grid(ref.surface)
            let cols = Int(grid.columns), rows = Int(grid.rows)
            let lines = TerminalTextReader.lines(ref.surface, cols: cols, rows: rows)
            Task { @MainActor in done(lines, (cols, rows)) }
        }
    }

    /// The grid that fits the current view at the current font (cells).
    var fittingGrid: (cols: Int, rows: Int) {
        guard let surface else { return (0, 0) }
        let size = ghostty_surface_size(surface)
        return (Int(size.columns), Int(size.rows))
    }

    /// The terminal's current (host-locked) grid.
    var currentGrid: (cols: Int, rows: Int, locked: Bool) {
        guard let surface else { return (0, 0, false) }
        let grid = ghostty_surface_grid(surface)
        return (Int(grid.columns), Int(grid.rows), grid.locked)
    }

    // MARK: Font size

    /// Sets the text size (points), clamped; the grid follows on the next draw.
    /// `minimum` lets a mirrored Mac grid go below the settings range.
    func setFontSize(_ size: Double, minimum: Double = TerminalFontSize.range.lowerBound) {
        let clamped = (min(max(size, minimum), TerminalFontSize.range.upperBound) * 2).rounded() / 2
        guard clamped != fontSize else { return }
        fontSize = clamped
        applyFontSize(clamped)
        requestFrame()
    }

    private func applyFontSize(_ size: Double) {
        guard let surface else { return }
        let action = "set_font_size:\(size)"
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
        diagnostics["font_size"] = String(size)
    }

    // MARK: Scrollback and selection

    /// Scrolls by a finger movement in points at `point` (positive dy moves
    /// the content down: older lines, or "wheel up" for a TUI). Ghostty picks
    /// the behavior from the mirrored modes: the scrollback viewport on the
    /// primary screen, wheel reports when the app enabled mouse reporting,
    /// arrow keys on the alternate screen with alternate scroll and no
    /// reporting. Reports carry the pointer position, so it is set first.
    func scroll(byPoints dy: CGFloat, at point: CGPoint) {
        guard let surface, dy != 0, dy.isFinite, point.x.isFinite, point.y.isFinite else { return }
        ghostty_surface_mouse_pos(surface, point.x, point.y, GHOSTTY_MODS_NONE)
        let scale = window?.screen.scale ?? 3
        // Precision scroll (bit 0): deltas in pixels; Ghostty turns them into rows.
        ghostty_surface_mouse_scroll(surface, 0, Double(dy * scale), ghostty_input_scroll_mods_t(1))
        requestFrame()
    }

    /// Starts a selection at a point: a double click selects the word.
    func beginSelection(at point: CGPoint) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, point.x, point.y, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        requestFrame()
    }

    /// Extends the selection while the finger moves.
    func extendSelection(to point: CGPoint) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, point.x, point.y, GHOSTTY_MODS_NONE)
        requestFrame()
    }

    func endSelection() {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        requestFrame()
    }

    /// True while the terminal app captures the mouse (mouse reporting on).
    var mouseCaptured: Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_captured(surface)
    }

    /// The last visible row that has text, or the cursor row when lower;
    /// a TUI's footer under the cursor counts, blank rows under a shell
    /// prompt do not. Cached per drawn frame: rows are read only after new
    /// output was drawn, not on every layout pass.
    var lastContentRow: (row: Int, cellHeight: CGFloat, paddingTop: CGFloat)? {
        // Reads rows: at most every 100 ms, so a fast redraw stream does not
        // make each frame read the whole screen.
        let now = CACurrentMediaTime()
        if let cache = contentRowCache, cache.draws == draws || now - contentRowComputedAt < 0.1 { return cache.value }
        let value = computeLastContentRow()
        contentRowCache = (draws, value)
        contentRowComputedAt = now
        return value
    }

    /// The bottom of `lastContentRow` in this view's points.
    var contentBottom: CGFloat? {
        lastContentRow.map { $0.paddingTop + CGFloat($0.row + 1) * $0.cellHeight }
    }

    private func computeLastContentRow() -> (row: Int, cellHeight: CGFloat, paddingTop: CGFloat)? {
        guard let surface else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), metrics.rows > 0, metrics.columns > 0 else { return nil }
        var lastRow = metrics.cursor_in_viewport ? Int(metrics.cursor_row) : 0
        var row = Int(metrics.rows) - 1
        while row > lastRow {
            if !isBlankRow(surface, row: row, columns: Int(metrics.columns)) { lastRow = row; break }
            row -= 1
        }
        return (lastRow, CGFloat(metrics.cell_height), CGFloat(metrics.padding_top))
    }

    /// Cell size and padding in points (from the current font).
    var cellMetrics: (width: CGFloat, height: CGFloat, padLeft: CGFloat, padTop: CGFloat)? {
        guard let surface else { return nil }
        var m = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &m), m.cell_width > 0 else { return nil }
        return (CGFloat(m.cell_width), CGFloat(m.cell_height), CGFloat(m.padding_left), CGFloat(m.padding_top))
    }

    /// The cursor's row in the viewport and the cell height (points).
    var cursorRow: (row: Int, cellHeight: CGFloat)? {
        guard let surface else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), metrics.cursor_in_viewport else { return nil }
        return (Int(metrics.cursor_row), CGFloat(metrics.cell_height))
    }

    private func isBlankRow(_ surface: ghostty_surface_t, row: Int, columns: Int) -> Bool {
        var selection = ghostty_selection_s()
        selection.top_left = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(row))
        selection.bottom_right = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                                 x: UInt32(columns - 1), y: UInt32(row))
        selection.rectangle = false
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return true }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let base = text.text, text.text_len > 0 else { return true }
        let bytes = UnsafeRawBufferPointer(start: base, count: Int(text.text_len))
        return bytes.allSatisfy { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
    }

    /// Composer send: the text as a paste (bracketed when the app enabled
    /// bracketed paste, raw otherwise), then Return unless `submit` is false.
    func sendComposed(_ text: String, submit: Bool) {
        if !text.isEmpty { perform([.paste(text)]) }
        if submit {
            let enter = TerminalKeyEvent(keyCode: TerminalHIDUsage.ghosttyKeyCode(TerminalHIDUsage.enter))
            perform([.key(enter), .key(enter.released)])
        }
    }

    var hasSelection: Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    var selectedText: String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let base = text.text, text.text_len > 0 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: base, count: Int(text.text_len)), as: UTF8.self)
    }

    func clearSelection() {
        guard let surface else { return }
        _ = ghostty_surface_clear_selection(surface)
        requestFrame()
    }

    func selectAll() {
        guard let surface else { return }
        let action = "select_all"
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
        requestFrame()
    }

    // MARK: Keyboard (plans/cmux-next/ios-keyboard.md T1-T4)

    override var canBecomeFirstResponder: Bool { true }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        TerminalMemory.trace("input: becomeFirstResponder -> \(became)")
        if became { onFocusChange?(true) }
        return became
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        TerminalMemory.trace("input: resignFirstResponder -> \(resigned)")
        if resigned {
            onFocusChange?(false)
            input.sticky.reset()
            keyBarView?.modifiers = input.sticky
            if input.markedText != nil { perform(input.setMarkedText(nil)) }
        }
        return resigned
    }

    /// The key bar hides while a hardware keyboard is attached (device only;
    /// the simulator always shows it).
    static var hardwareKeyboardAttached: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        GCKeyboard.coalesced != nil
        #endif
    }

    func keyBarKey(_ key: TerminalKeyBarKey) {
        switch key {
        case .paste: paste(nil)
        case .hideKeyboard: resignFirstResponder()
        case .composer: break // the controller handles the mode toggle
        default: perform(input.keyBar(key, at: ProcessInfo.processInfo.systemUptime))
        }
        keyBarView?.modifiers = input.sticky
    }

    override var keyCommands: [UIKeyCommand]? { navigationKeyCommands() }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        TerminalMemory.trace("input: pressesBegan \(presses.compactMap { $0.key.map { "\($0.keyCode.rawValue):\($0.characters.debugDescription)" } })")
        let unhandled = beginPresses(presses)
        keyBarView?.modifiers = input.sticky
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
        if action == #selector(copy(_:)) { return hasSelection }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Cmd-V, the edit menu and the key bar: a paste (bracketed when the app asked for it).
    override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        perform([.paste(text)])
    }

    override func copy(_ sender: Any?) {
        guard let text = selectedText, !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }
}

/// Coalesces "draw after output" hops: claimed on the output queue, released
/// on the main actor when the frame is requested.
final class FramePending: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if pending { return false }
        pending = true
        return true
    }

    func release() {
        lock.lock(); pending = false; lock.unlock()
    }
}

/// Reads a surface's visible rows as text (output queue only; the grid is
/// what the surface really has).
struct TerminalTextReader {
    static func lines(_ surface: ghostty_surface_t, cols: Int, rows: Int) -> [String] {
        guard cols > 0, rows > 0 else { return [] }
        return (0..<rows).map { row in
            var selection = ghostty_selection_s()
            selection.top_left = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(row))
            selection.bottom_right = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                                     x: UInt32(cols - 1), y: UInt32(row))
            var text = ghostty_text_s()
            guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
            defer { ghostty_surface_free_text(surface, &text) }
            guard let base = text.text, text.text_len > 0 else { return "" }
            return String(decoding: UnsafeRawBufferPointer(start: base, count: Int(text.text_len)), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: "")
        }
    }
}

/// DEBUG `CMUX_NEXT_TERMINAL_MEMORY=1`: logs live Ghostty surfaces to stderr.
@MainActor
struct TerminalMemory {
    static let tracing: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["CMUX_NEXT_TERMINAL_MEMORY"] == "1"
        #else
        false
        #endif
    }()

    /// The line is only built when tracing is on.
    static func trace(_ line: @autoclosure () -> String) {
        guard tracing else { return }
        FileHandle.standardError.write(Data((line() + "\n").utf8))
    }

    static func log() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["CMUX_NEXT_TERMINAL_MEMORY"] == "1" else { return }
        FileHandle.standardError.write(Data("terminal surfaces: views=\(GhosttyTerminalView.liveCount) thumbnails=\(HeadlessTerminal.liveCount)\n".utf8))
        #endif
    }
}

/// A surface handle sent to the output queue. The owner keeps the surface
/// alive until every queued output call returned.
struct SurfaceRef: @unchecked Sendable {
    let surface: ghostty_surface_t
    init(_ surface: ghostty_surface_t) { self.surface = surface }
}

/// Holds the input callback for the C trampoline (userdata pointer).
/// Bytes from `io_write_cb` (any thread, possibly under Ghostty's terminal
/// lock) are appended under a lock and delivered on the main queue after the
/// Ghostty call that produced them returned: in arrival order, one delivery
/// for everything that arrived since the last one (a drag that produces
/// hundreds of wheel reports costs one send per main-queue turn).
final class InputBox: @unchecked Sendable {
    /// Main thread only.
    var deliver: ((Data) -> Void)?
    private let lock = NSLock()
    private var pending = Data()
    private var scheduled = false

    func enqueue(_ bytes: UnsafePointer<CChar>, _ count: Int) {
        lock.lock()
        pending.append(UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self), count: count)
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { flush() }
        }
    }

    @MainActor func flush() {
        lock.lock()
        let data = pending
        pending = Data()
        scheduled = false
        lock.unlock()
        if !data.isEmpty { deliver?(data) }
    }

    /// Bytes waiting to be delivered (tests).
    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }
}

/// Keeps an object alive across a queue hop.
struct Retained: @unchecked Sendable {
    let object: AnyObject
    init(_ object: AnyObject) { self.object = object }
}
#endif
