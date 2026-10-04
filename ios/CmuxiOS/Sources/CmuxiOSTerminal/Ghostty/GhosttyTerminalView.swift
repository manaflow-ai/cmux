import Foundation
import GameController
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
    /// The terminal drew a frame (the cursor may have moved).
    public var onDraw: (() -> Void)?

    private(set) var surface: ghostty_surface_t?
    /// Keyboard input state (sticky modifiers, marked text); client view state.
    var input = TerminalInputRouter()
    /// UIKit's text input delegate (`UITextInput`).
    public weak var inputDelegate: (any UITextInputDelegate)?
    /// Hardware presses the router sent, by press, until their release.
    var handledPresses: [ObjectIdentifier: [TerminalInputAction]] = [:]
    /// The software keyboard (setting: `.asciiCapable` by default; the
    /// default keyboard allows non-Latin input).
    public var keyboardKind: UIKeyboardType = .asciiCapable
    /// The key bar's keys (setting `ios.terminal.accessoryKeys`).
    public var keyBarKeys: [TerminalKeyBarKey] = TerminalKeyBarKey.defaultKeys {
        didSet { keyBarView = nil }
    }
    /// Option sends Meta (setting `ios.terminal.optionAsMeta`, default true).
    public var optionAsMeta: Bool {
        get { input.optionAsMeta }
        set { input.optionAsMeta = newValue }
    }
    private var keyBarView: TerminalKeyBar?
    private var keyboardObservers: [any NSObjectProtocol] = []
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
        isAccessibilityElement = true
        accessibilityLabel = TerminalText.terminalLabel
        accessibilityTraits = .allowsDirectInteraction
        // The key bar hides while a hardware keyboard is attached.
        for name in [NSNotification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            keyboardObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.reloadInputViews() }
            })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        for observer in keyboardObservers { NotificationCenter.default.removeObserver(observer) }
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

    /// Draws again (marked text changed).
    func requestRedraw() { requestFrame() }

    private func requestFrame() {
        guard let app, surface != nil else { return }
        app.requestDraw(self) { [weak self] in
            guard let self, let surface = self.surface else { return }
            ghostty_surface_refresh(surface)
            ghostty_surface_draw(surface)
            self.draws += 1
            self.onDraw?()
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

    // MARK: Keyboard (plans/cmux-next/ios-keyboard.md T1-T4)

    public override var canBecomeFirstResponder: Bool { true }

    @discardableResult
    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            input.sticky.reset()
            keyBarView?.modifiers = input.sticky
            if input.markedText != nil { perform(input.setMarkedText(nil)) }
        }
        return resigned
    }

    /// The key bar over the software keyboard; none with a hardware keyboard.
    public override var inputAccessoryView: UIView? {
        guard GCKeyboard.coalesced == nil else { return nil }
        if let keyBarView { return keyBarView }
        let bar = TerminalKeyBar(keys: keyBarKeys)
        bar.onKey = { [weak self] key in self?.keyBarKey(key) }
        bar.modifiers = input.sticky
        keyBarView = bar
        return bar
    }

    private func keyBarKey(_ key: TerminalKeyBarKey) {
        switch key {
        case .paste: paste(nil)
        case .hideKeyboard: resignFirstResponder()
        default: perform(input.keyBar(key, at: ProcessInfo.processInfo.systemUptime))
        }
        keyBarView?.modifiers = input.sticky
    }

    public override var keyCommands: [UIKeyCommand]? { navigationKeyCommands() }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = beginPresses(presses)
        keyBarView?.modifiers = input.sticky
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = endPresses(presses)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = endPresses(presses)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return UIPasteboard.general.hasStrings }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Cmd-V, the edit menu and the key bar: a paste (bracketed when the app asked for it).
    public override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        perform([.paste(text)])
    }
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
