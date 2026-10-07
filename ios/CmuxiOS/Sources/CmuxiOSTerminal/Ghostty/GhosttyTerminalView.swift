public import CmuxTerminalRenderCore
public import CmuxTheme
import Foundation
import GameController
import GhosttyNextKit
public import UIKit

/// One visible terminal drawn by ghostty-next (a plain UIView: Ghostty adds
/// and sizes its own surface layer; frames are drawn on change, never by a
/// continuous display link). The phone owns no PTY: output and snapshots
/// arrive through `enqueueOutput`, and everything the user types leaves
/// through `onInput`, encoded by Ghostty's key encoder.
///
/// `authority` picks the I/O mode: `.host` mirrors a session host
/// (MANUAL_MIRROR: parser replies dropped, grid locked by the host);
/// `.local` makes this surface the parser (MANUAL: Ghostty answers terminal
/// queries through `onInput`, the grid follows the view).
@MainActor
public final class GhosttyTerminalView: UIView, TerminalRenderer {
    public var onInput: ((Data) -> Void)?
    /// The terminal drew a frame (the cursor may have moved).
    public var onDraw: (() -> Void)?
    /// A tap that did not open a link (the screen focuses the keyboard).
    public var onTap: (() -> Void)?
    /// The window title the terminal set (OSC 0/2).
    public var onTitle: ((String) -> Void)?
    /// The viewport changed: cells that fit, or visibility. Reported at the
    /// end of a pinch, never during it, and never for the software keyboard
    /// (the screen keeps this view's height).
    public var onViewportChange: ((TerminalViewport) -> Void)?

    public let authority: TerminalAuthority
    /// Theme from cmux theme tokens; nil keeps Ghostty's default colors.
    public var theme: ThemeInput? {
        didSet { if theme != oldValue { applyConfig() } }
    }
    /// Font size follows Dynamic Type (body style) unless turned off.
    public var followsDynamicType = true {
        didSet { applyFontSize() }
    }
    /// Pinch zoom (client view state, saved per device by the owner).
    public var zoom: Double = 1 {
        didSet { applyFontSize() }
    }
    public var fontSizing = TerminalFontSizing() {
        didSet { applyFontSize() }
    }
    /// `font-family` from Settings; nil keeps Ghostty's embedded font.
    public var fontFamily: String? {
        didSet { if fontFamily != oldValue { applyConfig() } }
    }
    /// `cursor-style` from Settings; nil keeps Ghostty's default.
    public var cursorStyle: TerminalCursorStyle? {
        didSet { if cursorStyle != oldValue { applyConfig() } }
    }
    public var cursorBlink = false {
        didSet { if cursorBlink != oldValue { applyConfig() } }
    }
    public var linkPolicy = TerminalLinkPolicy()
    /// Opens an allowed link (injected so tests and previews never leave the app).
    public var openLink: (URL) -> Void = { UIApplication.shared.open($0) }
    /// The font size last applied, in points.
    public private(set) var fontSize: Double = TerminalFontSizing().baseSize

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
        didSet {
            guard keyBarKeys != oldValue else { return }
            keyBarView = nil
            if isFirstResponder { reloadInputViews() }
        }
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
    /// The config the surface uses now; freed after the next one replaced it.
    private var surfaceConfig: ghostty_config_t?
    private var sceneObservers: [any NSObjectProtocol] = []
    private var lastViewport: TerminalViewport?
    /// True while a pinch runs: viewport reports wait for its end.
    var deferViewportReports = false
    /// Gesture state (scroll, selection, pinch); client view state.
    var gestures = TerminalGestureState()
    lazy var frameLink = TerminalGestureFrameLink()

    public convenience init(authority: TerminalAuthority) {
        self.init(frame: .zero, authority: authority)
    }

    public override convenience init(frame: CGRect) {
        self.init(frame: frame, authority: .host)
    }

    public init(frame: CGRect, authority: TerminalAuthority) {
        self.authority = authority
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        isAccessibilityElement = true
        accessibilityLabel = TerminalText.terminalLabel
        accessibilityTraits = .allowsDirectInteraction
        // The key bar hides while a hardware keyboard is attached (device only).
        for name in [NSNotification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            keyboardObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.reloadInputViews() }
            })
        }
        // A backgrounded app never submits GPU work (iOS terminates it) and a
        // phone that is not looking never counts toward the shared grid.
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification,
                     UIScene.didEnterBackgroundNotification, UIScene.willEnterForegroundNotification] {
            sceneObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.visibilityChanged() }
            })
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: GhosttyTerminalView, _) in
            view.applyFontSize()
        }
        installGestures()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        for observer in keyboardObservers + sceneObservers { NotificationCenter.default.removeObserver(observer) }
        frameLink.stop()
        guard let surface else { return }
        app?.unregister(surface)
        // Free only after every queued process_output returned (contract), and
        // keep the input box and config alive until free returns (io_write_cb may run).
        let ref = SurfaceRef(surface)
        let box = inputBox.map(Retained.init)
        let config = surfaceConfig.map(ConfigRef.init)
        outputQueue.async {
            DispatchQueue.main.async {
                ghostty_surface_free(ref.surface)
                if let config { ghostty_config_free(config.config) }
                _ = box
            }
        }
    }

    /// Creates the surface once the view has a window (its scale is known).
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, surface == nil { createSurface() }
        visibilityChanged()
    }

    /// On screen, in a foreground-active scene.
    public var isPresented: Bool {
        guard let scene = window?.windowScene, !isHidden else { return false }
        return scene.activationState == .foregroundActive
    }

    private func visibilityChanged() {
        guard let surface else { return }
        let presented = isPresented
        ghostty_surface_set_occlusion(surface, presented)
        if !presented { frameLink.stop() }
        reportViewport()
    }

    /// Reports the viewport when it changed (and no pinch is running).
    func reportViewport() {
        guard surface != nil, !deferViewportReports else { return }
        let grid = fittingGrid
        guard grid.cols > 0, grid.rows > 0 else { return }
        let viewport = TerminalViewport(cols: grid.cols, rows: grid.rows, visible: isPresented)
        guard viewport != lastViewport else { return }
        lastViewport = viewport
        onViewportChange?(viewport)
    }

    /// The last reported viewport (the session sends it on open).
    public var viewport: TerminalViewport? { lastViewport }

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
        fontSize = currentFontSize()
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(self).toOpaque()))
        config.scale_factor = Double(window?.screen.scale ?? 3)
        config.font_size = Float(fontSize)
        config.io_mode = authority == .host ? GHOSTTY_SURFACE_IO_MANUAL_MIRROR : GHOSTTY_SURFACE_IO_MANUAL
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
            app.register(surface, view: self)
            // Focused; visible only while presented (the renderer draws only for a visible surface).
            ghostty_surface_set_occlusion(surface, isPresented)
            ghostty_surface_set_focus(surface, true)
            if needsConfig { applyConfig() }
        }
        syncSize()
        requestFrame()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        syncSize()
        reportViewport()
    }

    // MARK: Font and theme

    private func currentFontSize() -> Double {
        let scale = followsDynamicType
            ? Double(UIFontMetrics(forTextStyle: .body).scaledValue(for: 1, compatibleWith: traitCollection))
            : 1
        return fontSizing.fontSize(dynamicTypeScale: scale, zoom: zoom)
    }

    /// Applies Dynamic Type and zoom. A host-locked grid keeps its size; only
    /// the cells that fit (the viewport proposal) change.
    func applyFontSize() {
        let size = currentFontSize()
        guard let surface, size != fontSize else { return }
        fontSize = size
        let action = "set_font_size:" + String(format: "%.1f", size)
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
        requestFrame()
        reportViewport()
    }

    /// True when the surface needs more than the app config (a theme or a
    /// Settings choice).
    private var needsConfig: Bool {
        theme != nil || fontFamily != nil || cursorStyle != nil || cursorBlink
    }

    /// Applies the theme, font family, cursor (and the phone's scrollback
    /// budget) to the surface.
    private func applyConfig() {
        guard let surface else { return }
        let settings = TerminalGhosttyConfig(fontSize: fontSize, theme: theme, cursorBlink: cursorBlink,
                                             fontFamily: fontFamily, cursorStyle: cursorStyle)
        guard let config = GhosttyNextApp.makeConfig(settings) else { return }
        ghostty_surface_update_config(surface, config)
        if let old = surfaceConfig { ghostty_config_free(old) }
        surfaceConfig = config
        backgroundColor = theme.map { UIColor(red: $0.background.red, green: $0.background.green,
                                              blue: $0.background.blue, alpha: 1) } ?? .black
        requestFrame()
    }

    // MARK: Actions from Ghostty

    func handle(_ action: GhosttySurfaceAction) {
        switch action {
        case .openURL(let link):
            gestures.openedLink = true
            if let url = linkPolicy.url(for: link) { openLink(url) }
        case .title(let title):
            onTitle?(title)
        case .hoverLink(let link):
            gestures.hoveredLink = link
        }
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

    func requestFrame() {
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

    /// The key bar over the software keyboard; none while a hardware
    /// keyboard is attached (ghostty-next section 5). The simulator always
    /// shows it: GameController reports the host Mac's keyboard there even
    /// while the software keyboard is up.
    public override var inputAccessoryView: UIView? {
        if Self.hardwareKeyboardAttached { return nil }
        if let keyBarView { return keyBarView }
        let bar = TerminalKeyBar(keys: keyBarKeys)
        bar.onKey = { [weak self] key in self?.keyBarKey(key) }
        bar.modifiers = input.sticky
        keyBarView = bar
        return bar
    }

    static var hardwareKeyboardAttached: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        GCKeyboard.coalesced != nil
        #endif
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
        if action == #selector(copy(_:)) { return hasSelection }
        if action == #selector(selectAll(_:)) { return surface != nil }
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

/// A config handle freed on the main queue after the surface.
private struct ConfigRef: @unchecked Sendable {
    let config: ghostty_config_t
    init(_ config: ghostty_config_t) { self.config = config }
}
