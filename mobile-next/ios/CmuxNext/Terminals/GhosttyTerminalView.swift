import GhosttyNextKit
import UIKit

/// A Ghostty surface in MANUAL IO mode: bytes from the Mac's pty are fed in
/// with `feed`, and everything Ghostty would write to a pty (keys, replies)
/// comes out of `onInput`.
final class GhosttyTerminalView: UIView, UIKeyInput, UITextInputTraits {
    var onInput: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    var onTitle: ((String) -> Void)?

    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
    private let outputQueue = DispatchQueue(label: "cnm.ghostty.output", qos: .userInteractive)
    private var lastGrid: (Int, Int) = (0, 0)
    nonisolated private let freedLock = NSLock()
    nonisolated(unsafe) private var _freed = false
    /// Read on the output queue: lock-protected, so not main-actor isolated.
    nonisolated private var freed: Bool {
        get { freedLock.withLock { _freed } }
        set { freedLock.withLock { _freed = newValue } }
    }
    /// Set by the key bar: the next typed letter is sent as a control code.
    var controlArmed = false { didSet { onControlChanged?(controlArmed) } }
    var onControlChanged: ((Bool) -> Void)?
    /// Take keyboard focus as soon as the view is on screen (a replacement
    /// terminal opened from the keyboard).
    var focusWhenShown = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255, alpha: 1)
        isMultipleTouchEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        // free() normally ran when the screen closed; this is the backstop.
        guard let surface else { return }
        freedLock.withLock { _freed = true }
        outputQueue.sync {}
        ghostty_surface_free(surface)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, surface == nil { createSurface() }
        if window != nil, focusWhenShown {
            focusWhenShown = false
            becomeFirstResponder()
        }
        if let surface { ghostty_surface_set_occlusion(surface, window != nil) }
    }

    private func createSurface() {
        guard let app = GhosttyRuntime.shared.app else { return }
        freed = false
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(window?.screen.scale ?? 3)
        config.font_size = 13
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        config.io_mode = GHOSTTY_SURFACE_IO_MANUAL
        config.io_write_userdata = Unmanaged.passUnretained(self).toOpaque()
        config.io_write_cb = { userdata, bytes, length in
            guard let userdata, let bytes, length > 0 else { return }
            let data = Data(bytes: bytes, count: Int(length))
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async { view.onInput?(data) }
        }
        surface = ghostty_surface_new(app, &config)
        setNeedsLayout()
    }

    /// Feeds pty output, in order, off the main thread.
    func feed(_ data: Data) {
        guard let surface else { return }
        outputQueue.async { [weak self] in
            guard let self, !self.freed else { return }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                ghostty_surface_process_output(surface, base.assumingMemoryBound(to: CChar.self), UInt(raw.count))
            }
        }
    }

    /// Runs after every byte fed so far has been parsed.
    func afterOutput(_ work: @escaping @MainActor () -> Void) {
        outputQueue.async { DispatchQueue.main.async { work() } }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.screen.scale ?? 3
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(bounds.width * scale), UInt32(bounds.height * scale))
        let size = ghostty_surface_size(surface)
        let grid = (Int(size.columns), Int(size.rows))
        if grid != lastGrid, grid.0 > 0, grid.1 > 0 {
            lastGrid = grid
            onResize?(grid.0, grid.1)
        }
    }

    var gridSize: (cols: Int, rows: Int) {
        guard let surface else { return (80, 24) }
        let size = ghostty_surface_size(surface)
        return (max(Int(size.columns), 2), max(Int(size.rows), 2))
    }

    func free() {
        freed = true
        outputQueue.sync {}
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
    }

    // MARK: Input

    @objc private func tapped() {
        if isFirstResponder { resignFirstResponder() } else { becomeFirstResponder() }
    }

    private var scrollRemainder: CGFloat = 0

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard let surface else { return }
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        scrollRemainder += translation.y
        let cellHeight = max(CGFloat(ghostty_surface_size(surface).cell_height_px) / (window?.screen.scale ?? 3), 8)
        let lines = (scrollRemainder / cellHeight).rounded(.towardZero)
        guard lines != 0 else { return }
        scrollRemainder -= lines * cellHeight
        ghostty_surface_mouse_scroll(surface, 0, Double(lines), 0)
    }

    private var pinchSteps: CGFloat = 0

    /// Pinch changes the font size one point per ~12% of scale; the grid
    /// (and the Mac's pty) follows through the normal resize path.
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard let surface else { return }
        if gesture.state == .began { pinchSteps = 0 }
        let steps = (log(gesture.scale) / log(1.12)).rounded(.towardZero)
        while pinchSteps < steps {
            pinchSteps += 1
            _ = "increase_font_size:1".withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
        }
        while pinchSteps > steps {
            pinchSteps -= 1
            _ = "decrease_font_size:1".withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
        }
        if gesture.state == .ended { setNeedsLayout() }
        if steps != 0 { setNeedsLayout() }
    }

    override var canBecomeFirstResponder: Bool { true }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        guard let surface else { return }
        if controlArmed, let scalar = text.lowercased().unicodeScalars.first, scalar.isASCII {
            controlArmed = false
            let value = scalar.value
            if (0x61...0x7A).contains(value) {
                send(Data([UInt8(value - 0x60)]))
                return
            }
        }
        text.withCString { pointer in
            ghostty_surface_text_input(surface, pointer, UInt(strlen(pointer)))
        }
    }

    func deleteBackward() {
        send(Data([0x7F]))
    }

    /// Sends raw bytes as if typed (key bar: esc, arrows, tab).
    func send(_ data: Data) {
        onInput?(data)
    }

    func paste(text: String) {
        guard let surface else { return }
        text.withCString { pointer in ghostty_surface_text(surface, pointer, UInt(strlen(pointer))) }
    }

    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
    var keyboardAppearance: UIKeyboardAppearance { get { .dark } set {} }

    // Hardware keyboards: arrows and escape arrive as presses.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            if let bytes = Self.sequence(for: key.keyCode) {
                send(bytes)
                handled = true
            } else if key.modifierFlags.contains(.control), let scalar = key.charactersIgnoringModifiers.lowercased().unicodeScalars.first,
                      (0x61...0x7A).contains(scalar.value)
            {
                send(Data([UInt8(scalar.value - 0x60)]))
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    static func sequence(for code: UIKeyboardHIDUsage) -> Data? {
        switch code {
        case .keyboardEscape: Data([0x1B])
        case .keyboardUpArrow: Data("\u{1B}[A".utf8)
        case .keyboardDownArrow: Data("\u{1B}[B".utf8)
        case .keyboardRightArrow: Data("\u{1B}[C".utf8)
        case .keyboardLeftArrow: Data("\u{1B}[D".utf8)
        default: nil
        }
    }
}
