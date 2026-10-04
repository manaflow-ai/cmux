import Foundation
import GhosttyNextKit
import UIKit

/// One visible terminal drawn by ghostty-next in mirror mode (a plain
/// UIView: Ghostty adds and sizes its own surface layer; there is no display
/// link on iOS, the renderer draws on change): the phone owns
/// no PTY; host output and snapshots arrive through `enqueueOutput`, and everything the user
/// types leaves through `onInput` (encoded by Ghostty with the mirrored modes).
@MainActor
public final class GhosttyTerminalView: UIView, TerminalRenderer {
    public var onInput: ((Data) -> Void)?

    private var surface: ghostty_surface_t?
    private var app: GhosttyNextApp?
    /// The output functions (process_output, set_grid, restore and encode
    /// snapshot) run here: one serial queue, never the main thread
    /// (ghostty-next threading contract).
    private let outputQueue = DispatchQueue(label: "cmux.ios.terminal.output", qos: .userInteractive)
    private var inputBox: InputBox?
    private var draws = 0

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        guard let surface else { return }
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
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, surface == nil else { return }
        createSurface()
    }

    /// DEBUG diagnostics: what the surface did (DevTerminal writes them for simulator checks).
    public private(set) var diagnostics: [String: String] = [:]

    private func createSurface() {
        let app: GhosttyNextApp
        do { app = try GhosttyNextApp.shared() } catch {
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
        config.font_size = 13
        config.io_mode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR
        config.io_write_userdata = Unmanaged.passUnretained(box).toOpaque()
        config.io_write_cb = { userdata, bytes, length in
            guard let userdata, let bytes, length > 0 else { return }
            // Copy now: the bytes are valid only during the call.
            let data = Data(bytes: bytes, count: Int(length))
            let box = Unmanaged<InputBox>.fromOpaque(userdata).takeUnretainedValue()
            if Thread.isMainThread {
                MainActor.assumeIsolated { box.deliver?(data) }
            } else {
                Task { @MainActor in box.deliver?(data) }
            }
        }
        surface = ghostty_surface_new(app.app, &config)
        diagnostics["surface"] = surface == nil ? "nil" : "ok"
        if let surface {
            // Visible and focused: the renderer draws only for a visible surface.
            ghostty_surface_set_occlusion(surface, true)
            ghostty_surface_set_focus(surface, true)
        }
        syncSize()
        requestFrame()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        syncSize()
    }

    private func syncSize() {
        guard let surface, let window else { return }
        let scale = window.screen.scale
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(bounds.width * scale), UInt32(bounds.height * scale))
        requestFrame()
    }

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
        }
    }

    // MARK: TerminalRenderer

    public var snapshotVersion: UInt16 { GhosttyOutputSurface.snapshotVersion }

    @discardableResult
    public func enqueueOutput(_ work: @escaping @Sendable (any TerminalOutputSurface) -> Void) -> Bool {
        guard let surface else { return false }
        let output = GhosttyOutputSurface(ref: SurfaceRef(surface))
        outputQueue.async {
            work(output)
            Task { @MainActor [weak self] in self?.requestFrame() }
        }
        return true
    }

    public var fittingGrid: (cols: Int, rows: Int) {
        guard let surface else { return (0, 0) }
        let size = ghostty_surface_size(surface)
        return (Int(size.columns), Int(size.rows))
    }

    // MARK: Keyboard (software keyboard text; hardware keys come later via pressesBegan)

    public override var canBecomeFirstResponder: Bool { true }

    func sendText(_ text: String) {
        guard let surface else { return }
        let utf8 = Array(text.utf8CString)
        utf8.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            ghostty_surface_text_input(surface, base, UInt(buffer.count - 1))
        }
    }
}

extension GhosttyTerminalView: UIKeyInput {
    public var hasText: Bool { true }
    public func insertText(_ text: String) { sendText(text) }
    public func deleteBackward() { sendText("\u{7F}") }
}

/// Holds the input callback for the C trampoline (userdata pointer).
@MainActor
private final class InputBox {
    var deliver: ((Data) -> Void)?
}

/// Keeps an object alive across a queue hop.
private struct Retained: @unchecked Sendable {
    let object: AnyObject
    init(_ object: AnyObject) { self.object = object }
}
