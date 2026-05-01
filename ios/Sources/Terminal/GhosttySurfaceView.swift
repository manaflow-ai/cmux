import OSLog
import UIKit

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "ghostty.surface")

enum TerminalInputDebugLog {
    private static let isEnabled = ProcessInfo.processInfo.environment["CMUX_INPUT_DEBUG"] == "1"

    static func log(_ message: String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        #endif
        guard isEnabled else { return }
        TerminalSidebarStore.debugLog("input: \(message)")
    }

    static func textSummary(_ text: String) -> String {
        let summary = String(reflecting: text)
        guard summary.count > 96 else { return summary }
        return "\(summary.prefix(96))..."
    }

    static func dataSummary(_ data: Data) -> String {
        let prefix = data.prefix(32)
        let prefixData = Data(prefix)
        let hex = prefix.map { String(format: "%02X", $0) }.joined(separator: " ")
        let utf8 = String(data: prefixData, encoding: .utf8) ?? "<non-utf8>"
        let suffix = data.count > prefix.count ? " ..." : ""
        return "len=\(data.count) hex=\(hex)\(suffix) utf8=\(textSummary(utf8))"
    }
}

@MainActor
protocol GhosttySurfaceViewDelegate: AnyObject {
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data)
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize)
}

@MainActor
protocol TerminalSurfaceHosting: AnyObject {
    var currentGridSize: TerminalGridSize { get }
    func processOutput(_ data: Data)
    func focusInput()
    func updateRemotePlatform(_ platform: RemotePlatform)
    /// Apply the daemon's authoritative rendering grid. Unconditional —
    /// implementations render at exactly cols × rows and letterbox any
    /// remaining container area. The daemon broadcasts this on every
    /// attach/resize/detach/open, plus inlined in RPC responses, so
    /// every attached device converges on the same grid.
    func applyViewSize(cols: Int, rows: Int)
    #if DEBUG
    func accessibilityRenderedTextForTesting() -> String?
    #endif
}

extension TerminalSurfaceHosting {
    func focusInput() {}
    func updateRemotePlatform(_ platform: RemotePlatform) {}
    func applyViewSize(cols _: Int, rows _: Int) {}
    #if DEBUG
    func accessibilityRenderedTextForTesting() -> String? { nil }
    #endif
}

final class GhosttySurfaceBridge {
    weak var surfaceView: GhosttySurfaceView?

    func attach(to surfaceView: GhosttySurfaceView) {
        self.surfaceView = surfaceView
    }

    func detach() {
        surfaceView = nil
    }

    func handleWrite(_ bytes: Data) {
        Task { @MainActor [weak self] in
            guard let surfaceView = self?.surfaceView else { return }
            surfaceView.handleOutboundBytes(bytes)
        }
    }

    func handleCloseSurface(processAlive: Bool) {
        Task { @MainActor [weak self] in
            guard let surfaceView = self?.surfaceView else { return }
            NotificationCenter.default.post(
                name: .ghosttySurfaceDidRequestClose,
                object: surfaceView,
                userInfo: ["process_alive": processAlive]
            )
        }
    }

    static func fromOpaque(_ userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceBridge? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
    }
}

private enum GhosttySurfaceDisposer {
    static let queue = DispatchQueue(label: "GhosttySurfaceDisposer.queue")

    static func dispose(surface: ghostty_surface_t, bridge: GhosttySurfaceBridge) {
        let retainedBridge = Unmanaged.passRetained(bridge)
        queue.async {
            ghostty_surface_free(surface)
            retainedBridge.release()
        }
    }
}

struct TerminalTextInputPipeline {
    struct Result: Equatable {
        var committedText: String?
        var nextBufferText: String
    }

    static func process(text: String, isComposing: Bool) -> Result {
        guard !isComposing else {
            return Result(committedText: nil, nextBufferText: text)
        }
        guard !text.isEmpty else {
            return Result(committedText: nil, nextBufferText: "")
        }
        return Result(committedText: text, nextBufferText: "")
    }
}

struct TerminalCursorBlinkState: Equatable {
    static let interval: CFTimeInterval = 0.5

    private(set) var isVisible = true
    private var lastToggle: CFTimeInterval = 0

    mutating func start(now: CFTimeInterval) {
        isVisible = true
        lastToggle = now
    }

    mutating func reset(now: CFTimeInterval) {
        isVisible = true
        lastToggle = now
    }

    mutating func advance(now: CFTimeInterval) -> Bool {
        let elapsed = now - lastToggle
        guard elapsed >= Self.interval else { return false }
        let intervals = max(1, Int(elapsed / Self.interval))
        if intervals % 2 == 1 {
            isVisible.toggle()
        }
        lastToggle += CFTimeInterval(intervals) * Self.interval
        return true
    }
}

private struct TerminalHardwareKeyCommand: Sendable {
    let input: String
    let modifierFlags: UIKeyModifierFlags
}

private enum TerminalHardwareKeyResolver {
    private static let supportedModifierFlags: UIKeyModifierFlags = [.shift, .control, .alternate]
    private static let keyCommands: [TerminalHardwareKeyCommand] = {
        let navigation = [
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [.alternate]),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [.alternate]),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputHome, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputEnd, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputPageUp, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputPageDown, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputDelete, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputDelete, modifierFlags: [.alternate]),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: []),
            TerminalHardwareKeyCommand(input: "\t", modifierFlags: []),
            TerminalHardwareKeyCommand(input: "\t", modifierFlags: [.shift]),
        ]
        let controlInputs = Array("abcdefghijklmnopqrstuvwxyz[]\\ 234567/").map(String.init)
            .map { TerminalHardwareKeyCommand(input: $0, modifierFlags: [.control]) }
        let shiftedControlInputs = Array("@^_?").map(String.init)
            .map { TerminalHardwareKeyCommand(input: $0, modifierFlags: [.control, .shift]) }
        return navigation + controlInputs + shiftedControlInputs
    }()

    static func makeKeyCommands(target: Any, action: Selector) -> [UIKeyCommand] {
        keyCommands.map { command in
            UIKeyCommand(
                input: command.input,
                modifierFlags: command.modifierFlags,
                action: action
            )
        }
    }

    static func data(input: String, modifierFlags: UIKeyModifierFlags) -> Data? {
        let normalizedFlags = modifierFlags.intersection(supportedModifierFlags)

        switch (input, normalizedFlags) {
        case (UIKeyCommand.inputLeftArrow, [.alternate]):
            return Data([0x1B, 0x62])
        case (UIKeyCommand.inputRightArrow, [.alternate]):
            return Data([0x1B, 0x66])
        case (UIKeyCommand.inputUpArrow, []):
            return Data([0x1B, 0x5B, 0x41])
        case (UIKeyCommand.inputDownArrow, []):
            return Data([0x1B, 0x5B, 0x42])
        case (UIKeyCommand.inputRightArrow, []):
            return Data([0x1B, 0x5B, 0x43])
        case (UIKeyCommand.inputLeftArrow, []):
            return Data([0x1B, 0x5B, 0x44])
        case (UIKeyCommand.inputHome, []):
            return Data([0x1B, 0x5B, 0x48])
        case (UIKeyCommand.inputEnd, []):
            return Data([0x1B, 0x5B, 0x46])
        case (UIKeyCommand.inputPageUp, []):
            return Data([0x1B, 0x5B, 0x35, 0x7E])
        case (UIKeyCommand.inputPageDown, []):
            return Data([0x1B, 0x5B, 0x36, 0x7E])
        case (UIKeyCommand.inputDelete, []):
            return Data([0x1B, 0x5B, 0x33, 0x7E])
        case (UIKeyCommand.inputDelete, [.alternate]):
            return Data([0x1B, 0x7F])
        case (UIKeyCommand.inputEscape, []):
            return Data([0x1B])
        case ("\t", []):
            return Data([0x09])
        case ("\t", [.shift]):
            return Data([0x1B, 0x5B, 0x5A])
        case let (input, flags) where flags == [.control] || flags == [.control, .shift]:
            return controlCharacter(for: input)
        default:
            return nil
        }
    }

    private static func controlCharacter(for input: String) -> Data? {
        switch input {
        case " ":
            return Data([0x00])
        case "2":
            return Data([0x00])
        case "3":
            return Data([0x1B])
        case "4":
            return Data([0x1C])
        case "5":
            return Data([0x1D])
        case "6":
            return Data([0x1E])
        case "7":
            return Data([0x1F])
        case "/":
            return Data([0x1F])
        case "?":
            return Data([0x7F])
        default:
            break
        }

        guard let scalar = input.uppercased().unicodeScalars.first,
              input.unicodeScalars.count == 1 else { return nil }

        guard (0x40...0x5F).contains(scalar.value) else { return nil }
        return Data([UInt8(scalar.value & 0x1F)])
    }
}

enum TerminalFontZoomDirection: Equatable {
    case decrease
    case increase

    var bindingAction: String {
        switch self {
        case .decrease:
            return "decrease_font_size:1"
        case .increase:
            return "increase_font_size:1"
        }
    }
}

enum TerminalInputAccessoryAction: Int, CaseIterable {
    case control
    case alternate
    case command
    case shift
    case zoomOut
    case zoomIn
    case escape
    case tab
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow
    case claude
    case codex
    case tilde
    case pipe
    case ctrlC
    case ctrlD
    case ctrlZ
    case ctrlL
    case home
    case end
    case pageUp
    case pageDown
    var title: String {
        title(isMacRemote: false)
    }

    func title(isMacRemote: Bool) -> String {
        switch self {
        case .control:
            return isMacRemote ? "⌃" : "Ctrl"
        case .alternate:
            return isMacRemote ? "⌥" : "Alt"
        case .command:
            return "⌘"
        case .shift:
            return "⇧"
        case .zoomOut:
            return ""
        case .zoomIn:
            return ""
        case .escape:
            return "Esc"
        case .tab:
            return "Tab"
        case .ctrlC:
            return "^C"
        case .ctrlD:
            return "^D"
        case .ctrlZ:
            return "^Z"
        case .ctrlL:
            return "^L"
        case .upArrow:
            return "↑"
        case .downArrow:
            return "↓"
        case .leftArrow:
            return "←"
        case .rightArrow:
            return "→"
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .home:
            return "Home"
        case .end:
            return "End"
        case .pageUp:
            return "PgUp"
        case .tilde:
            return "~"
        case .pipe:
            return "|"
        case .pageDown:
            return "PgDn"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .control: return "terminal.inputAccessory.control"
        case .alternate: return "terminal.inputAccessory.alt"
        case .command: return "terminal.inputAccessory.command"
        case .shift: return "terminal.inputAccessory.shift"
        case .zoomOut: return "terminal.inputAccessory.zoomOut"
        case .zoomIn: return "terminal.inputAccessory.zoomIn"
        case .escape: return "terminal.inputAccessory.escape"
        case .tab: return "terminal.inputAccessory.tab"
        case .upArrow: return "terminal.inputAccessory.up"
        case .downArrow: return "terminal.inputAccessory.down"
        case .leftArrow: return "terminal.inputAccessory.left"
        case .rightArrow: return "terminal.inputAccessory.right"
        case .claude: return "terminal.inputAccessory.claude"
        case .codex: return "terminal.inputAccessory.codex"
        case .tilde: return "terminal.inputAccessory.tilde"
        case .pipe: return "terminal.inputAccessory.pipe"
        case .ctrlC: return "terminal.inputAccessory.ctrlC"
        case .ctrlD: return "terminal.inputAccessory.ctrlD"
        case .ctrlZ: return "terminal.inputAccessory.ctrlZ"
        case .ctrlL: return "terminal.inputAccessory.ctrlL"
        case .home: return "terminal.inputAccessory.home"
        case .end: return "terminal.inputAccessory.end"
        case .pageUp: return "terminal.inputAccessory.pageUp"
        case .pageDown: return "terminal.inputAccessory.pageDown"
        }
    }

    var accessibilityLabel: String? {
        switch self {
        case .zoomOut:
            return String(localized: "terminal.input_accessory.zoom_out", defaultValue: "Zoom Out")
        case .zoomIn:
            return String(localized: "terminal.input_accessory.zoom_in", defaultValue: "Zoom In")
        default:
            return nil
        }
    }

    var symbolName: String? {
        switch self {
        case .zoomOut:
            return "minus.magnifyingglass"
        case .zoomIn:
            return "plus.magnifyingglass"
        default:
            return nil
        }
    }

    var zoomDirection: TerminalFontZoomDirection? {
        switch self {
        case .zoomOut:
            return .decrease
        case .zoomIn:
            return .increase
        default:
            return nil
        }
    }

    /// Whether this action is a modifier key (toggleable armed state).
    var isModifier: Bool {
        switch self {
        case .control, .alternate, .command, .shift: return true
        default: return false
        }
    }

    var output: Data? {
        switch self {
        case .control, .alternate, .command, .shift, .zoomOut, .zoomIn:
            return nil
        case .escape:
            return Data([0x1B])
        case .tab:
            return Data([0x09])
        case .tilde:
            return Data([0x7E]) // ~
        case .pipe:
            return Data([0x7C]) // |
        case .ctrlC:
            return Data([0x03])
        case .ctrlD:
            return Data([0x04])
        case .ctrlZ:
            return Data([0x1A])
        case .ctrlL:
            return Data([0x0C])
        case .upArrow:
            return Data([0x1B, 0x5B, 0x41]) // ESC[A
        case .downArrow:
            return Data([0x1B, 0x5B, 0x42]) // ESC[B
        case .leftArrow:
            return Data([0x1B, 0x5B, 0x44]) // ESC[D
        case .rightArrow:
            return Data([0x1B, 0x5B, 0x43]) // ESC[C
        case .claude:
            return Data("claude --dangerously-skip-permissions\r".utf8)
        case .codex:
            return Data("codex --dangerously-bypass-approvals-and-sandbox -c model_reasoning_effort=xhigh --search\r".utf8)
        case .home:
            return Data([0x1B, 0x5B, 0x48]) // ESC[H
        case .end:
            return Data([0x1B, 0x5B, 0x46]) // ESC[F
        case .pageUp:
            return Data([0x1B, 0x5B, 0x35, 0x7E]) // ESC[5~
        case .pageDown:
            return Data([0x1B, 0x5B, 0x36, 0x7E]) // ESC[6~
        }
    }
}

final class GhosttySurfaceView: UIView, TerminalSurfaceHosting {
    private weak var runtime: GhosttyRuntime?
    private weak var delegate: GhosttySurfaceViewDelegate?
    private let fontSize: Float32
    private let bridge = GhosttySurfaceBridge()
    private let prefersSnapshotFallbackRendering = false
    var onFocusInputRequestedForTesting: (() -> Void)?
    private var surfaceTitle: String?
    private var displayLink: CADisplayLink?
    private var cursorBlinkState = TerminalCursorBlinkState()
    private var cursorOverlayLayer: CALayer?
    private var needsDraw: Bool = false
    private var surfaceHasReceivedOutput: Bool = false
    private var shouldScrollInitialOutputToBottom = true
    // Serial background queue for feeding bytes into Ghostty. Keeps
    // `ghostty_surface_process_output` off the main thread so a potential
    // Ghostty internal mutex/futex wait can't freeze the UI. Ordering is
    // preserved because the queue is serial.
    private static let outputQueue = DispatchQueue(
        label: "dev.cmux.GhosttySurfaceView.output",
        qos: .userInitiated
    )
    #if DEBUG
    private var lastInputTimestamp: CFTimeInterval = 0
    private var latencySamples: [Double] = []
    var onOutputProcessedForTesting: (() -> Void)?
    #endif
    private let snapshotFallbackView: UITextView = {
        let view = UITextView()
        view.backgroundColor = UIColor(red: 0x27/255.0, green: 0x28/255.0, blue: 0x22/255.0, alpha: 1)
        view.textColor = UIColor(red: 0xfd/255.0, green: 0xff/255.0, blue: 0xf1/255.0, alpha: 1)
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        view.textContainer.lineFragmentPadding = 0
        view.isEditable = false
        view.isSelectable = false
        view.isScrollEnabled = true
        view.isUserInteractionEnabled = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.isHidden = true
        return view
    }()

    private(set) var surface: ghostty_surface_t?
    private var lastReportedSize: TerminalGridSize?
    private var lastSnapshotFallbackHTML: String?
    /// Daemon-authoritative effective grid (min across attached devices). When
    /// set, the Ghostty surface is pinned to this cols×rows inside the
    /// container so every attached device renders at the same grid. When
    /// nil, the surface fills the container's natural capacity.
    private var effectiveGrid: (cols: Int, rows: Int)?
    /// Cached cell metrics derived from the most recent
    /// `ghostty_surface_size` measurement. Used to translate an effective
    /// cols×rows pin into a pixel box without re-round-tripping through
    /// Ghostty. Zero until the first layout has measured.
    private var cellPixelSize: CGSize = .zero
    /// 1 px separator stroke drawn around the pinned surface rect when the
    /// container is larger than the render target (i.e., this device is
    /// not the smallest). Added lazily on first letterbox.
    private var letterboxBorderLayer: CAShapeLayer?
    /// Last render rect used for the Ghostty surface inside the host view's
    /// coordinate space. Kept so the border layer can match it without a
    /// second set_size round-trip.
    private var lastRenderRect: CGRect = .zero

    #if DEBUG
    struct DebugGeometrySnapshot {
        let boundsSize: CGSize
        let renderRect: CGRect
        let screenScale: CGFloat
        let reportedSize: TerminalGridSize?
        let renderedSize: TerminalGridSize?
    }

    func debugGeometrySnapshotForTesting() -> DebugGeometrySnapshot {
        let renderedSize: TerminalGridSize? = {
            guard let surface else { return nil }
            let size = ghostty_surface_size(surface)
            return TerminalGridSize(
                columns: Int(size.columns),
                rows: Int(size.rows),
                pixelWidth: Int(size.width_px),
                pixelHeight: Int(size.height_px)
            )
        }()
        return DebugGeometrySnapshot(
            boundsSize: bounds.size,
            renderRect: lastRenderRect,
            screenScale: preferredScreenScale,
            reportedSize: lastReportedSize,
            renderedSize: renderedSize
        )
    }

    func setKeyboardHeightForTesting(_ height: CGFloat) {
        keyboardHeight = max(0, height)
        syncSurfaceGeometry()
    }
    #endif

    var currentGridSize: TerminalGridSize {
        lastReportedSize ?? TerminalGridSize(columns: 100, rows: 32, pixelWidth: 900, pixelHeight: 650)
    }

    private lazy var inputProxy: TerminalInputTextView = {
        let inputProxy = TerminalInputTextView()
        inputProxy.onText = { [weak self] text in
            guard let self else { return }
            self.resetCursorBlink()
            #if DEBUG
            self.lastInputTimestamp = CACurrentMediaTime()
            #endif
            // Send all text directly to the transport as raw bytes.
            // Ghostty is display-only; the remote server handles echo.
            // Replace \n with \r (terminals expect CR for Return).
            let normalized = text.replacingOccurrences(of: "\n", with: "\r")
            let data = Data(normalized.utf8)
            TerminalInputDebugLog.log("surface.onText text=\(TerminalInputDebugLog.textSummary(text)) data=\(TerminalInputDebugLog.dataSummary(data))")
            self.delegate?.ghosttySurfaceView(self, didProduceInput: data)
        }
        inputProxy.onBackspace = { [weak self] in
            guard let self else { return }
            self.resetCursorBlink()
            // Send DEL (0x7F) directly to transport as raw byte.
            let data = Data([0x7F])
            TerminalInputDebugLog.log("surface.onBackspace data=\(TerminalInputDebugLog.dataSummary(data))")
            self.delegate?.ghosttySurfaceView(self, didProduceInput: data)
        }
        inputProxy.onEscapeSequence = { [weak self] data in
            guard let self else { return }
            self.resetCursorBlink()
            TerminalInputDebugLog.log("surface.onEscape data=\(TerminalInputDebugLog.dataSummary(data))")
            self.delegate?.ghosttySurfaceView(self, didProduceInput: data)
        }
        inputProxy.onZoom = { [weak self] direction in
            self?.performFontZoom(direction)
        }
        inputProxy.onHideKeyboard = { [weak self] in
            self?.inputProxy.resignFirstResponder()
        }
        inputProxy.accessoryLayoutInsetsProvider = { [weak self] in
            guard let self,
                  let window = self.window else {
                return .zero
            }

            let terminalFrame = self.convert(self.bounds, to: window)
            return UIEdgeInsets(
                top: 0,
                left: max(0, terminalFrame.minX),
                bottom: 0,
                right: max(0, window.bounds.maxX - terminalFrame.maxX)
            )
        }
        return inputProxy
    }()

    init(runtime: GhosttyRuntime, delegate: GhosttySurfaceViewDelegate, fontSize: Float32 = 10) {
        self.runtime = runtime
        self.delegate = delegate
        self.fontSize = fontSize
        super.init(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        bridge.attach(to: self)
        backgroundColor = .black
        isOpaque = true
        #if DEBUG
        accessibilityIdentifier = "terminal.surface"
        isAccessibilityElement = true
        #endif
        addSubview(snapshotFallbackView)
        addSubview(inputProxy)
        initializeSurface()

        let tap = UITapGestureRecognizer(target: self, action: #selector(focusInput))
        addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc private func handleAppDidEnterBackground() {
        guard let surface else { return }
        stopDisplayLink()
        setFocus(false)
        ghostty_surface_set_occlusion(surface, false)  // false = not visible (occluded)
    }

    @objc private func handleAppWillEnterForeground() {
        guard let surface, window != nil else { return }
        ghostty_surface_set_occlusion(surface, true)  // true = visible
        setFocus(true)
        startDisplayLink()
    }

    private var keyboardHeight: CGFloat = 0
    var autoFocusOnWindowAttach = true

    @objc private func handleKeyboardWillShow(_ notification: Notification) {
        guard let frameEnd = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let window else { return }
        let keyboardFrameInView = convert(frameEnd, from: window)
        let overlap = max(0, bounds.maxY - keyboardFrameInView.minY)
        guard overlap != keyboardHeight else { return }
        keyboardHeight = overlap
        syncSurfaceGeometry()
    }

    @objc private func handleKeyboardWillHide(_ notification: Notification) {
        guard keyboardHeight != 0 else { return }
        keyboardHeight = 0
        syncSurfaceGeometry()
    }

    private var pinchAccumulatedScale: CGFloat = 1.0

    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        guard let surface else { return }
        if gesture.state == .changed {
            let translation = gesture.translation(in: self)
            // iOS natural scrolling: swipe down (positive translation) = scroll up (show history).
            // Ghostty: positive y = scroll down. So pass translation.y directly for natural feel.
            let scrollY = translation.y / 10.0
            ghostty_surface_mouse_scroll(surface, 0, Double(scrollY), 0)
            gesture.setTranslation(.zero, in: self)
            needsDraw = true
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchAccumulatedScale = 1.0
        case .changed:
            let delta = gesture.scale - pinchAccumulatedScale
            if abs(delta) >= 0.15 {
                let direction: TerminalFontZoomDirection = delta > 0 ? .increase : .decrease
                if performFontZoom(direction) {
                    pinchAccumulatedScale = gesture.scale
                }
            }
        case .ended, .cancelled:
            // Final sync to make sure the last font change is applied.
            syncSurfaceGeometry()
        default:
            break
        }
    }

    @discardableResult
    private func performFontZoom(_ direction: TerminalFontZoomDirection) -> Bool {
        let handled = performBindingAction(direction.bindingAction)
        guard handled else { return false }

        // Font size changes recalculate cell metrics. Re-sync geometry so the
        // new natural cols/rows are propagated through session.resize to every
        // attached device.
        syncSurfaceGeometry()
        return true
    }

    @discardableResult
    private func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { pointer in
            ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        disposeSurface()
    }

    override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        snapshotFallbackView.frame = bounds
        inputProxy.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        inputProxy.updateAccessoryLayoutInsets()
        liveAnchormuxLog("surface.layout bounds=\(Int(bounds.width))x\(Int(bounds.height)) window=\(window != nil)")
        syncSurfaceGeometry()
        syncSurfaceVisibility()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        liveAnchormuxLog("surface.didMoveToWindow window=\(window != nil)")
        syncSurfaceVisibility()
        if window != nil {
            syncSurfaceGeometry()
            setFocus(true)
            if autoFocusOnWindowAttach {
                focusInput()
            }
            startDisplayLink()
        } else {
            stopDisplayLink()
            setFocus(false)
        }
    }

    private var lastProcessOutputLogTime: CFTimeInterval = 0

    func processOutput(_ data: Data) {
        guard let surface else { return }
        #if DEBUG
        if lastInputTimestamp > 0 {
            let elapsed = (CACurrentMediaTime() - lastInputTimestamp) * 1000.0
            lastInputTimestamp = 0
            latencySamples.append(elapsed)
            if latencySamples.count % 10 == 0 {
                let sorted = latencySamples.sorted()
                let avg = latencySamples.reduce(0, +) / Double(latencySamples.count)
                let p50 = sorted[sorted.count / 2]
                let p95 = sorted[Int(Double(sorted.count) * 0.95)]
                log.debug("Keypress latency (\(self.latencySamples.count, privacy: .public) samples): avg=\(avg, privacy: .public)ms p50=\(p50, privacy: .public)ms p95=\(p95, privacy: .public)ms min=\(sorted.first!, privacy: .public)ms max=\(sorted.last!, privacy: .public)ms")
            }
        }
        #endif
        let forwarded = Self.forwardDaemonOutputBytes(data)

        // Dispatch the actual Ghostty call to a serial background queue.
        // ghostty_surface_process_output can block on Ghostty's internal
        // mutex / mailbox, and running it on main would freeze the UI
        // (see TerminalSidebarStore deadlock notes). Ordering is preserved
        // because the queue is serial.
        Self.outputQueue.async { [weak self] in
            forwarded.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                let pointer = baseAddress.assumingMemoryBound(to: CChar.self)
                ghostty_surface_process_output(surface, pointer, UInt(buffer.count))
            }
            // Hop back to main for Swift-side state updates and diagnostics.
            DispatchQueue.main.async {
                guard let self else { return }
                self.needsDraw = true
                if !self.surfaceHasReceivedOutput {
                    self.surfaceHasReceivedOutput = true
                    self.snapshotFallbackView.isHidden = true
                    self.scrollInitialOutputToBottomIfNeeded()
                }
                let now = CACurrentMediaTime()
                if now - self.lastProcessOutputLogTime > 1.0 {
                    self.lastProcessOutputLogTime = now
                    if self.window != nil {
                        self.logLayerTree(reason: "processOutput")
                    }
                }
                #if DEBUG
                self.onOutputProcessedForTesting?()
                #endif
            }
        }
    }

    private func scrollInitialOutputToBottomIfNeeded() {
        guard shouldScrollInitialOutputToBottom else { return }
        shouldScrollInitialOutputToBottom = false
        _ = performBindingAction("scroll_to_bottom")
    }

    static func forwardDaemonOutputBytes(_ data: Data) -> Data {
        // The daemon owns terminal byte semantics. iOS must feed Ghostty the
        // exact VT stream it received so desktop and mobile render the same
        // session history and prompt state.
        data
    }

    @objc
    func focusInput() {
        onFocusInputRequestedForTesting?()
        syncSurfaceGeometry()
        inputProxy.updateAccessoryLayoutInsets()
        inputProxy.becomeFirstResponder()
    }

    func updateRemotePlatform(_ platform: RemotePlatform) {
        inputProxy.updateModifierLabels(isMacRemote: platform.goOS == "darwin")
    }

    func simulateTextInputForTesting(_ text: String) {
        setFocus(true)
        sendText(text)
        runtime?.tick()
    }

    func simulatePasteInputForTesting(_ text: String) {
        setFocus(true)
        sendPaste(text)
        runtime?.tick()
    }

    func simulateInputProxyTextChangeForTesting(_ text: String, isComposing: Bool) {
        setFocus(true)
        inputProxy.simulateTextChangeForTesting(text, isComposing: isComposing)
        runtime?.tick()
    }

    func renderedTextForTesting(pointTag: ghostty_point_tag_e = GHOSTTY_POINT_VIEWPORT) -> String? {
        guard let surface else { return nil }

        let topLeft = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return nil
        }
        defer {
            ghostty_surface_free_text(surface, &text)
        }

        guard let ptr = text.text, text.text_len > 0 else {
            return ""
        }

        let data = Data(bytes: ptr, count: Int(text.text_len))
        return String(decoding: data, as: UTF8.self)
    }

    #if DEBUG
    func accessibilityRenderedTextForTesting() -> String? {
        let candidates = [
            renderedTextForTesting(pointTag: GHOSTTY_POINT_SURFACE),
            renderedTextForTesting(pointTag: GHOSTTY_POINT_SCREEN),
            renderedTextForTesting(pointTag: GHOSTTY_POINT_ACTIVE),
            renderedTextForTesting(pointTag: GHOSTTY_POINT_VIEWPORT),
        ].compactMap { $0 }

        return candidates.max { lhs, rhs in
            lhs.utf8.count < rhs.utf8.count
        }
    }
    #endif

    func renderedHTMLForTesting(pointTag: ghostty_point_tag_e = GHOSTTY_POINT_VIEWPORT) -> String? {
        _ = pointTag
        // ghostty_surface_read_text_html not available in this build
        return nil
    }

    func processExitedForTesting() -> Bool {
        guard let surface else { return false }
        return ghostty_surface_process_exited(surface)
    }

    func disposeSurface() {
        stopDisplayLink()
        guard let surface else { return }
        GhosttySurfaceView.unregister(surface: surface)
        self.surface = nil
        bridge.detach()
        GhosttySurfaceDisposer.dispose(surface: surface, bridge: bridge)
    }

    private var preferredScreenScale: CGFloat {
        if let screen = window?.windowScene?.screen {
            return screen.scale
        }

        let traitScale = traitCollection.displayScale
        return traitScale > 0 ? traitScale : 2
    }

    private func sendText(_ text: String) {
        guard let surface else { return }
        let normalized = text.replacingOccurrences(of: "\n", with: "\r")
        let count = normalized.utf8CString.count
        guard count > 1 else { return }
        normalized.withCString { pointer in
            ghostty_surface_text_input(surface, pointer, UInt(count - 1))
        }
    }

    private func sendPaste(_ text: String) {
        guard let surface else { return }
        let count = text.utf8CString.count
        guard count > 0 else { return }
        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(count - 1))
        }
    }

    private func initializeSurface() {
        guard let app = runtime?.app else { return }
        surface = makeSurface(app: app)
        if let surface {
            GhosttySurfaceView.register(surface: surface, for: self)
            if let config = runtime?.config {
                applyBackgroundColorFromConfig(config)
            }
            // Hide the snapshot fallback immediately. The Metal renderer
            // handles all rendering once the surface exists.
            snapshotFallbackView.isHidden = true
            surfaceHasReceivedOutput = true
        }
        syncSurfaceGeometry()
        startDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(target: self), selector: #selector(DisplayLinkProxy.handleDisplayLink))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        cursorBlinkState.start(now: CACurrentMediaTime())
        needsDraw = true
        updateCursorOverlay()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        cursorOverlayLayer?.isHidden = true
    }

    /// Reset cursor to visible and restart blink cycle (call on user input).
    private func resetCursorBlink() {
        guard surface != nil else { return }
        cursorBlinkState.reset(now: CACurrentMediaTime())
        needsDraw = true
        updateCursorOverlay()
    }

    @objc func handleDisplayLinkFire() {
        guard let surface else { return }
        let now = CACurrentMediaTime()
        let blinkChanged = cursorBlinkState.advance(now: now)
        if needsDraw || blinkChanged {
            needsDraw = false
            ghostty_surface_render_now(surface)
            updateCursorOverlay()
        }
    }

    private func updateCursorOverlay() {
        guard let surface,
              window != nil,
              !isHidden,
              alpha > 0.01,
              !lastRenderRect.isEmpty,
              cellPixelSize.width > 0,
              cellPixelSize.height > 0 else {
            cursorOverlayLayer?.isHidden = true
            return
        }
        let overlay = ensureCursorOverlayLayer()
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let scale = max(preferredScreenScale, 1)
        overlay.contentsScale = scale
        let cellWidth = max(cellPixelSize.width / scale, 1)
        let cellHeight = max(CGFloat(height), cellPixelSize.height / scale, 1)
        let cursorWidth = max(1.0 / scale, min(CGFloat(1.5), cellWidth))
        let cursorX = lastRenderRect.minX + CGFloat(x) - (cellWidth / 2)
        let cursorY = lastRenderRect.minY + CGFloat(y) - cellHeight
        overlay.frame = CGRect(
            x: floor(cursorX),
            y: floor(cursorY),
            width: cursorWidth,
            height: ceil(cellHeight)
        )
        overlay.backgroundColor = cursorBlinkState.isVisible
            ? (configCursorColor ?? UIColor(red: 0xc0/255.0, green: 0xc1/255.0, blue: 0xb5/255.0, alpha: 1.0)).cgColor
            : (configBackgroundColor ?? backgroundColor ?? .black).cgColor
        overlay.isHidden = false
    }

    private func ensureCursorOverlayLayer() -> CALayer {
        if let cursorOverlayLayer {
            return cursorOverlayLayer
        }
        let layer = CALayer()
        layer.name = "cmux.cursorOverlay"
        layer.zPosition = 1001
        layer.actions = [
            "backgroundColor": NSNull(),
            "bounds": NSNull(),
            "frame": NSNull(),
            "position": NSNull(),
        ]
        self.layer.addSublayer(layer)
        cursorOverlayLayer = layer
        return layer
    }

    private(set) var configBackgroundColor: UIColor?
    private(set) var configCursorColor: UIColor?

    private func applyBackgroundColorFromConfig(_ config: ghostty_config_t) {
        var bgColor = ghostty_config_color_s()
        let bgKey = "background"
        if ghostty_config_get(config, &bgColor, bgKey, UInt(bgKey.lengthOfBytes(using: .utf8))) {
            let bg = UIColor(red: CGFloat(bgColor.r) / 255.0, green: CGFloat(bgColor.g) / 255.0, blue: CGFloat(bgColor.b) / 255.0, alpha: 1.0)
            backgroundColor = bg
            snapshotFallbackView.backgroundColor = bg
            configBackgroundColor = bg
            #if DEBUG
            log.debug("applyBg: config r=\(bgColor.r, privacy: .public) g=\(bgColor.g, privacy: .public) b=\(bgColor.b, privacy: .public) -> UIColor(\(bg.debugDescription, privacy: .public)), hardcoded Monokai=#272822 r=39 g=40 b=34")
            #endif
        } else {
            #if DEBUG
            log.debug("applyBg: ghostty_config_get returned false, no bg color from config")
            #endif
        }
        var fgColor = ghostty_config_color_s()
        let fgKey = "foreground"
        if ghostty_config_get(config, &fgColor, fgKey, UInt(fgKey.lengthOfBytes(using: .utf8))) {
            snapshotFallbackView.textColor = UIColor(red: CGFloat(fgColor.r) / 255.0, green: CGFloat(fgColor.g) / 255.0, blue: CGFloat(fgColor.b) / 255.0, alpha: 1.0)
        }
        var cursorColor = ghostty_config_color_s()
        let cursorKey = "cursor-color"
        if ghostty_config_get(config, &cursorColor, cursorKey, UInt(cursorKey.lengthOfBytes(using: .utf8))) {
            configCursorColor = UIColor(
                red: CGFloat(cursorColor.r) / 255.0,
                green: CGFloat(cursorColor.g) / 255.0,
                blue: CGFloat(cursorColor.b) / 255.0,
                alpha: 1.0
            )
        }
    }

    private func setFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    private func syncSurfaceVisibility() {
        guard let surface else { return }
        let visible = window != nil &&
            !isHidden &&
            alpha > 0.01 &&
            bounds.width > 0 &&
            bounds.height > 0
        liveAnchormuxLog("surface.occlusion visible=\(visible) window=\(window != nil) hidden=\(isHidden) alpha=\(alpha)")
        ghostty_surface_set_occlusion(surface, visible)
        if visible {
            updateCursorOverlay()
        } else {
            cursorOverlayLayer?.isHidden = true
        }
    }

    func applyViewSize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        if effectiveGrid?.cols == cols && effectiveGrid?.rows == rows { return }
        effectiveGrid = (cols, rows)
        if window != nil {
            syncSurfaceGeometry(shouldReassertNaturalSize: false)
        } else {
            setNeedsLayout()
        }
    }

    private func setSurfaceSizeAtLeastGrid(
        _ surface: ghostty_surface_t,
        cols: Int,
        rows: Int,
        cellPixelSize: CGSize
    ) -> (requestedW: UInt32, requestedH: UInt32, actual: ghostty_surface_size_s) {
        var requestedW = UInt32(max(1, Int((CGFloat(cols) * cellPixelSize.width).rounded(.down))))
        var requestedH = UInt32(max(1, Int((CGFloat(rows) * cellPixelSize.height).rounded(.down))))

        ghostty_surface_set_size(surface, requestedW, requestedH)
        var actual = ghostty_surface_size(surface)

        // Ghostty's grid calculation subtracts padding and floors partial cells,
        // so the reverse mapping has to be confirmed against Ghostty itself.
        // This keeps the iOS mirror on the exact daemon grid instead of
        // occasionally rendering one column short.
        var steps = 0
        while steps < 128,
              Int(actual.columns) < cols || Int(actual.rows) < rows {
            if Int(actual.columns) < cols {
                requestedW += 1
            }
            if Int(actual.rows) < rows {
                requestedH += 1
            }
            ghostty_surface_set_size(surface, requestedW, requestedH)
            actual = ghostty_surface_size(surface)
            steps += 1
        }

        return (requestedW, requestedH, actual)
    }

    private func syncSurfaceGeometry(shouldReassertNaturalSize: Bool = true) {
        guard let surface else { return }

        let scale = preferredScreenScale
        ghostty_surface_set_content_scale(surface, scale, scale)

        // The container's visible device-preferred pixel box. The iOS
        // keyboard and input accessory cover the bottom of this UIView, so
        // they must reduce the render/report height while visible. When
        // the keyboard hides, layout re-expands and reports the full host
        // capacity again.
        let bottomInset = min(max(0, keyboardHeight), max(0, bounds.height - 1))
        let containerW = max(1, bounds.width)
        let containerH = max(1, bounds.height - bottomInset)
        let containerPxW = UInt32(max(1, Int((containerW * scale).rounded(.down))))
        let containerPxH = UInt32(max(1, Int((containerH * scale).rounded(.down))))

        // Measure the container's natural cell capacity by sizing Ghostty
        // to the full container box and reading back cols/rows. This is
        // what we report via `session.resize`; the daemon uses the
        // smallest live attachment as the effective PTY size.
        ghostty_surface_set_size(surface, containerPxW, containerPxH)
        let measured = ghostty_surface_size(surface)
        if measured.columns > 0 && measured.rows > 0 && measured.width_px > 0 && measured.height_px > 0 {
            cellPixelSize = CGSize(
                width: CGFloat(measured.width_px) / CGFloat(measured.columns),
                height: CGFloat(measured.height_px) / CGFloat(measured.rows)
            )
        }
        let naturalSize = TerminalGridSize(
            columns: Int(measured.columns),
            rows: Int(measured.rows),
            pixelWidth: Int(measured.width_px),
            pixelHeight: Int(measured.height_px)
        )

        // If the daemon pinned us to a smaller effective grid, re-size
        // Ghostty to that grid in pixels and remember the inner rect so
        // the renderer layer + border can center around it. If the pin
        // would exceed the container (stale push mid-resize, or we are
        // actually the smallest device) fall back to natural fill.
        let renderRect: CGRect
        if let eff = effectiveGrid,
           eff.cols > 0, eff.rows > 0,
           cellPixelSize.width > 0, cellPixelSize.height > 0 {
            let columnSlack = Int(measured.columns) - eff.cols
            let rowSlack = Int(measured.rows) - eff.rows
            let fillsNaturalGrid = eff.cols >= Int(measured.columns) && eff.rows >= Int(measured.rows)
            let withinOneCell = columnSlack <= 1 && rowSlack <= 1
            let pinnedW = CGFloat(eff.cols) * cellPixelSize.width / scale
            let pinnedH = CGFloat(eff.rows) * cellPixelSize.height / scale
            if fillsNaturalGrid || withinOneCell {
                renderRect = CGRect(x: 0, y: 0, width: containerW, height: containerH)
            } else if pinnedW + 0.5 < containerW || pinnedH + 0.5 < containerH {
                let fittedSize = setSurfaceSizeAtLeastGrid(
                    surface,
                    cols: eff.cols,
                    rows: eff.rows,
                    cellPixelSize: cellPixelSize
                )
                let actualWidthPx = fittedSize.actual.width_px > 0 ? fittedSize.actual.width_px : fittedSize.requestedW
                let actualHeightPx = fittedSize.actual.height_px > 0 ? fittedSize.actual.height_px : fittedSize.requestedH
                let clampedW = min(CGFloat(actualWidthPx) / scale, containerW)
                let clampedH = min(CGFloat(actualHeightPx) / scale, containerH)
                // Left-align + top-anchor the pinned surface so cells line
                // up at the same screen column every render, regardless of
                // container width. Users scanning text expect a fixed left
                // margin; centering would make the prompt jitter horizontally
                // when another device attaches or detaches.
                renderRect = CGRect(x: 0, y: 0, width: clampedW, height: clampedH)
            } else {
                renderRect = CGRect(x: 0, y: 0, width: containerW, height: containerH)
            }
        } else {
            renderRect = CGRect(x: 0, y: 0, width: containerW, height: containerH)
        }

        lastRenderRect = renderRect
        syncRendererLayerFrame(scale: scale, renderRect: renderRect)
        updateLetterboxBorder(renderRect: renderRect, isLetterboxed: renderRect.width + 0.5 < containerW || renderRect.height + 0.5 < containerH)
        updateCursorOverlay()

        liveAnchormuxLog(
            "surface.geometry bounds=\(Int(bounds.width))x\(Int(bounds.height)) container=\(Int(containerW))x\(Int(containerH)) render=\(Int(renderRect.width))x\(Int(renderRect.height))@\(Int(renderRect.origin.x)),\(Int(renderRect.origin.y)) natural=\(naturalSize.columns)x\(naturalSize.rows) effective=\(effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "none")"
        )
        ghostty_surface_refresh(surface)
        syncSnapshotFallback()
        if window != nil {
            logLayerTree(reason: "geometry")
        }
        let effectiveMatchesNatural = effectiveGrid.map { grid in
            grid.cols == naturalSize.columns && grid.rows == naturalSize.rows
        } ?? true
        let shouldReportNaturalSize = naturalSize != lastReportedSize ||
            (shouldReassertNaturalSize && !effectiveMatchesNatural)
        guard shouldReportNaturalSize else { return }
        lastReportedSize = naturalSize
        delegate?.ghosttySurfaceView(self, didResize: naturalSize)
    }

    private func syncRendererLayerFrame(scale: CGFloat, renderRect: CGRect) {
        layer.contentsScale = scale
        for sublayer in layer.sublayers ?? [] where isGhosttyRendererLayer(sublayer) {
            if sublayer.frame != renderRect {
                sublayer.frame = renderRect
            }
            if sublayer.bounds.size != renderRect.size {
                sublayer.bounds = CGRect(origin: .zero, size: renderRect.size)
            }
            sublayer.contentsScale = scale
        }
    }

    /// Add / update a 1-pixel separator border around the pinned surface
    /// rect when the container is larger (this device is not the smallest
    /// attached to the shared PTY). Smallest-device layouts have
    /// `isLetterboxed == false` and the border layer is hidden. Uses a
    /// CAShapeLayer so the stroke doesn't intercept touches / key events.
    private func updateLetterboxBorder(renderRect: CGRect, isLetterboxed: Bool) {
        guard isLetterboxed else {
            letterboxBorderLayer?.isHidden = true
            return
        }
        let border: CAShapeLayer = {
            if let existing = letterboxBorderLayer { return existing }
            let b = CAShapeLayer()
            b.fillColor = UIColor.clear.cgColor
            b.lineWidth = 1.0
            b.zPosition = 1000 // above the Ghostty renderer layer
            b.isHidden = false
            // Decorative only; let pointer / key events pass through.
            b.isGeometryFlipped = false
            layer.addSublayer(b)
            letterboxBorderLayer = b
            return b
        }()
        border.isHidden = false
        border.strokeColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        border.contentsScale = layer.contentsScale
        let inset: CGFloat = 1.5 // half-line out so the stroke hugs the edge
        let outline = renderRect.insetBy(dx: -inset, dy: -inset)
        let path = UIBezierPath(rect: outline).cgPath
        if border.path != path {
            border.path = path
        }
        if border.frame != layer.bounds {
            border.frame = layer.bounds
        }
    }

    private func isGhosttyRendererLayer(_ layer: CALayer) -> Bool {
        String(describing: type(of: layer)) == "IOSurfaceLayer"
    }

    private func logLayerTree(reason: String) {
        let hostLayer = layer
        let hostSummary = "\(type(of: hostLayer)) bounds=\(hostLayer.bounds.integral.debugDescription) frame=\(hostLayer.frame.integral.debugDescription) contentsScale=\(hostLayer.contentsScale)"
        let childSummaries = (hostLayer.sublayers ?? []).prefix(4).enumerated().map { index, sublayer in
            "\(index):\(type(of: sublayer)) bounds=\(sublayer.bounds.integral.debugDescription) frame=\(sublayer.frame.integral.debugDescription) hidden=\(sublayer.isHidden) contents=\(sublayer.contents != nil) scale=\(sublayer.contentsScale)"
        }.joined(separator: " | ")
        liveAnchormuxLog("surface.layers reason=\(reason) host=\(hostSummary) children=[\(childSummaries)] fallbackHidden=\(snapshotFallbackView.isHidden) fallbackChars=\(snapshotFallbackView.text.count)")
    }

    private func makeSurface(app: ghostty_app_t) -> ghostty_surface_t? {
        var surfaceConfig = ghostty_surface_config_new()
        let bridgePointer = Unmanaged.passUnretained(bridge).toOpaque()
        surfaceConfig.userdata = bridgePointer
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_IOS
        surfaceConfig.platform = ghostty_platform_u(
            ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(self).toOpaque())
        )
        surfaceConfig.scale_factor = preferredScreenScale
        surfaceConfig.font_size = fontSize
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        surfaceConfig.io_mode = GHOSTTY_SURFACE_IO_MANUAL
        surfaceConfig.io_write_cb = { userdata, buf, len in
            guard let userdata, let buf, len > 0 else { return }
            let data = Data(bytes: buf, count: Int(len))
            let bridge = Unmanaged<GhosttySurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                bridge.surfaceView?.handleOutboundBytes(data)
            }
        }
        surfaceConfig.io_write_userdata = bridgePointer
        return ghostty_surface_new(app, &surfaceConfig)
    }

    func handleOutboundBytes(_ bytes: Data) {
        delegate?.ghosttySurfaceView(self, didProduceInput: bytes)
    }

    func drawForWakeup() {
        guard let surface, window != nil else { return }
        ghostty_surface_refresh(surface)
    }

    func visibleSnapshotTextForTesting() -> String {
        snapshotFallbackView.attributedText?.string ?? snapshotFallbackView.text
    }

    func visibleSnapshotAttributedTextForTesting() -> NSAttributedString? {
        snapshotFallbackView.attributedText
    }

    func isUsingSnapshotFallbackForTesting() -> Bool {
        !snapshotFallbackView.isHidden
    }

    private func syncSnapshotFallback() {
        // Once the Metal renderer is active (surface has received output),
        // keep the fallback hidden so the IOSurfaceLayer is visible.
        if surfaceHasReceivedOutput {
            snapshotFallbackView.isHidden = true
            return
        }

        let rendererHasContents = !prefersSnapshotFallbackRendering &&
            (layer.sublayers ?? []).contains(where: isGhosttyRendererLayerVisible)
        if rendererHasContents {
            snapshotFallbackView.isHidden = true
            return
        }

        let snapshot = renderedTextForTesting() ?? ""
        guard !snapshot.isEmpty else {
            lastSnapshotFallbackHTML = nil
            snapshotFallbackView.attributedText = nil
            snapshotFallbackView.text = ""
            snapshotFallbackView.isHidden = true
            return
        }

        let html = renderedHTMLForTesting()
        if let html,
           html != lastSnapshotFallbackHTML,
           let attributedSnapshot = makeSnapshotAttributedText(from: html) {
            lastSnapshotFallbackHTML = html
            snapshotFallbackView.attributedText = attributedSnapshot
            applySnapshotFallbackTheme(from: attributedSnapshot)
        } else if snapshotFallbackView.attributedText?.string != snapshot {
            lastSnapshotFallbackHTML = nil
            snapshotFallbackView.attributedText = nil
            snapshotFallbackView.text = snapshot
        }

        if snapshotFallbackView.text != snapshot && snapshotFallbackView.attributedText == nil {
            snapshotFallbackView.text = snapshot
        }

        let visibleTextLength = snapshotFallbackView.attributedText?.string.utf16.count ?? snapshotFallbackView.text.utf16.count
        if visibleTextLength > 0 {
            snapshotFallbackView.scrollRangeToVisible(NSRange(location: max(0, visibleTextLength - 1), length: 1))
        }
        snapshotFallbackView.isHidden = false
        flushSnapshotFallbackPresentation()
    }

    private func flushSnapshotFallbackPresentation() {
        snapshotFallbackView.textContainer.size = snapshotFallbackView.bounds.size
        snapshotFallbackView.layoutManager.ensureLayout(for: snapshotFallbackView.textContainer)
        snapshotFallbackView.layoutManager.invalidateDisplay(
            forCharacterRange: NSRange(location: 0, length: snapshotFallbackView.textStorage.length)
        )
        snapshotFallbackView.setNeedsDisplay()
    }

    private func makeSnapshotAttributedText(from html: String) -> NSAttributedString? {
        let wrappedHTML = """
        <style>
        body {
            margin: 0;
            padding: 0;
            font-family: Menlo, Monaco, monospace;
            font-size: 13px;
            line-height: 1.25;
        }
        div, pre {
            white-space: pre-wrap;
        }
        </style>
        \(html)
        """
        guard let wrappedData = wrappedHTML.data(using: .utf8) else { return nil }
        return try? NSMutableAttributedString(
            data: wrappedData,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        )
    }

    private func applySnapshotFallbackTheme(from attributedText: NSAttributedString) {
        guard attributedText.length > 0 else {
            snapshotFallbackView.backgroundColor = .black
            return
        }

        let probeIndex = firstVisibleThemeAttributeIndex(in: attributedText)
        if let background = attributedText.attribute(.backgroundColor, at: probeIndex, effectiveRange: nil) as? UIColor {
            snapshotFallbackView.backgroundColor = background
        } else {
            snapshotFallbackView.backgroundColor = .black
        }
    }

    private func firstVisibleThemeAttributeIndex(in attributedText: NSAttributedString) -> Int {
        let fullString = attributedText.string
        for (index, scalar) in fullString.unicodeScalars.enumerated() {
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return index
            }
        }
        return 0
    }

    private func isGhosttyRendererLayerVisible(_ layer: CALayer) -> Bool {
        isGhosttyRendererLayer(layer) && layer.contents != nil
    }

    nonisolated private static func handleWrite(
        userdata: UnsafeMutableRawPointer?,
        data: UnsafePointer<CChar>?,
        len: UInt
    ) {
        guard let userdata, let data, len > 0 else { return }
        let bytes = Data(bytes: data, count: Int(len))
        #if DEBUG
        // Detect OSC responses (ESC ] ...) flowing back to the remote terminal.
        // OSC 11 response = "\x1b]11;rgb:RRRR/GGGG/BBBB..." (background color report).
        if bytes.count < 200, let str = String(data: bytes, encoding: .utf8) {
            let escaped = str.unicodeScalars.map { scalar in
                scalar.value < 32 || scalar.value == 127
                    ? String(format: "\\x%02x", scalar.value)
                    : String(scalar)
            }.joined()
            if escaped.contains("\\x1b]") || escaped.contains("\\x1b[") {
                log.debug("io_write OSC/CSI response (\(bytes.count, privacy: .public) bytes): \(escaped, privacy: .public)")
            }
        }
        #endif
        GhosttySurfaceBridge.fromOpaque(userdata)?.handleWrite(bytes)
    }

    @MainActor
    static func focusInput(for surface: ghostty_surface_t) {
        view(for: surface)?.focusInput()
    }

    @MainActor
    static func setTitle(_ title: String, for surface: ghostty_surface_t) {
        view(for: surface)?.surfaceTitle = title
    }

    @MainActor
    static func ringBell(for surface: ghostty_surface_t) {
        view(for: surface)?.handleBell()
    }

    @MainActor
    static func title(for surface: ghostty_surface_t) -> String? {
        view(for: surface)?.surfaceTitle
    }

    @MainActor
    static func drawVisibleSurfacesForWakeup() {
        registeredSurfaceViews = registeredSurfaceViews.filter { $0.value.value != nil }
        for view in registeredSurfaceViews.values.compactMap(\.value) {
            view.drawForWakeup()
        }
    }

    private func handleBell() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        NotificationCenter.default.post(
            name: .ghosttySurfaceDidRingBell,
            object: self
        )
    }
}

private final class WeakGhosttySurfaceViewBox {
    weak var value: GhosttySurfaceView?

    init(_ value: GhosttySurfaceView) {
        self.value = value
    }
}

private extension GhosttySurfaceView {
    @MainActor
    static var registeredSurfaceViews: [UInt: WeakGhosttySurfaceViewBox] = [:]

    @MainActor
    static func register(surface: ghostty_surface_t, for view: GhosttySurfaceView) {
        registeredSurfaceViews[surfaceIdentifier(for: surface)] = WeakGhosttySurfaceViewBox(view)
        registeredSurfaceViews = registeredSurfaceViews.filter { $0.value.value != nil }
    }

    @MainActor
    static func unregister(surface: ghostty_surface_t) {
        registeredSurfaceViews.removeValue(forKey: surfaceIdentifier(for: surface))
    }

    @MainActor
    static func view(for surface: ghostty_surface_t) -> GhosttySurfaceView? {
        let identifier = surfaceIdentifier(for: surface)
        guard let view = registeredSurfaceViews[identifier]?.value else {
            registeredSurfaceViews.removeValue(forKey: identifier)
            return nil
        }
        return view
    }

    static func surfaceIdentifier(for surface: ghostty_surface_t) -> UInt {
        UInt(bitPattern: UnsafeRawPointer(surface))
    }
}

final class TerminalInputTextView: UITextView {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onEscapeSequence: ((Data) -> Void)?
    var onZoom: ((TerminalFontZoomDirection) -> Void)?
    var onHideKeyboard: (() -> Void)?
    var accessoryLayoutInsetsProvider: (() -> UIEdgeInsets)?
    private var controlAccessoryArmed = false
    private var alternateAccessoryArmed = false
    private var commandAccessoryArmed = false
    private var shiftAccessoryArmed = false
    private var controlAccessorySticky = false
    private var alternateAccessorySticky = false
    private var commandAccessorySticky = false
    private var shiftAccessorySticky = false
    private var lastControlTapTime: Date?
    private var lastAlternateTapTime: Date?
    private var lastCommandTapTime: Date?
    private var lastShiftTapTime: Date?
    private var pendingDirectInsertMirrorText = ""
    private static let directInsertMirrorTextLimit = 128

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard markedTextRange == nil else { return nil }
        return TerminalHardwareKeyResolver.makeKeyCommands(
            target: self,
            action: #selector(handleHardwareKeyCommand(_:))
        )
    }

    private static let monokaiBarColor = UIColor(red: 0x27/255.0, green: 0x28/255.0, blue: 0x22/255.0, alpha: 1)
    private static let accessoryHorizontalInset: CGFloat = 16
    private static let accessoryButtonFont = UIFont.systemFont(ofSize: 14, weight: .medium)
    private static let accessoryButtonSymbolConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    private static let accessoryButtonInsets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
    private static let accessoryButtonCornerRadius: CGFloat = 6
    private static let accessoryButtonHeight: CGFloat = 28
    private static let accessoryButtonMinWidth: CGFloat = 44
    private static let accessoryButtonNormalBackground = UIColor(white: 0.35, alpha: 1)
    private var accessoryBackgroundLeadingConstraint: NSLayoutConstraint?
    private var accessoryBackgroundTrailingConstraint: NSLayoutConstraint?
    private var accessoryDismissLeadingConstraint: NSLayoutConstraint?
    private var accessoryScrollTrailingConstraint: NSLayoutConstraint?

    private lazy var terminalAccessoryToolbar: UIView = {
        let container = UIView()
        container.backgroundColor = .clear
        container.frame = CGRect(x: 0, y: 0, width: 0, height: 44)

        let backgroundView = UIView()
        backgroundView.backgroundColor = Self.monokaiBarColor
        backgroundView.translatesAutoresizingMaskIntoConstraints = false

        // Pinned keyboard dismiss button on the left
        let dismissButton = UIButton(type: .system)
        let dismissConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        dismissButton.setImage(UIImage(systemName: "keyboard.chevron.compact.down", withConfiguration: dismissConfig), for: .normal)
        dismissButton.tintColor = UIColor(white: 0.7, alpha: 1)
        dismissButton.addTarget(self, action: #selector(handleHideKeyboard), for: .touchUpInside)
        dismissButton.accessibilityIdentifier = "terminal.inputAccessory.hideKeyboard"
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        // Scrollable action buttons
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center

        for action in TerminalInputAccessoryAction.allCases {
            let button = makeAccessoryButton(for: action)
            // Command is Mac-only; don't add it to the stack at all by default.
            // updateModifierLabels(isMacRemote: true) will insert it dynamically.
            if action == .command {
                commandAccessoryButton = button
            } else {
                stack.addArrangedSubview(button)
            }
        }

        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        // Arrow nub for directional pad
        let nub = TerminalArrowNubView()
        nub.onArrowKey = { [weak self] data in
            self?.onEscapeSequence?(data)
        }
        nub.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(backgroundView)
        container.addSubview(dismissButton)
        container.addSubview(nub)
        container.addSubview(scrollView)

        let backgroundLeadingConstraint = backgroundView.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        let backgroundTrailingConstraint = backgroundView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        let dismissLeadingConstraint = dismissButton.leadingAnchor.constraint(
            equalTo: container.safeAreaLayoutGuide.leadingAnchor,
            constant: Self.accessoryHorizontalInset
        )
        let scrollTrailingConstraint = scrollView.trailingAnchor.constraint(
            equalTo: container.safeAreaLayoutGuide.trailingAnchor,
            constant: -Self.accessoryHorizontalInset
        )

        NSLayoutConstraint.activate([
            backgroundLeadingConstraint,
            backgroundTrailingConstraint,
            backgroundView.topAnchor.constraint(equalTo: container.topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            dismissLeadingConstraint,
            dismissButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 32),

            nub.leadingAnchor.constraint(equalTo: dismissButton.trailingAnchor, constant: 6),
            nub.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            nub.widthAnchor.constraint(equalToConstant: 34),
            nub.heightAnchor.constraint(equalToConstant: 34),

            scrollView.leadingAnchor.constraint(equalTo: nub.trailingAnchor, constant: 6),
            scrollTrailingConstraint,
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor, constant: -8),
        ])

        accessoryBackgroundLeadingConstraint = backgroundLeadingConstraint
        accessoryBackgroundTrailingConstraint = backgroundTrailingConstraint
        accessoryDismissLeadingConstraint = dismissLeadingConstraint
        accessoryScrollTrailingConstraint = scrollTrailingConstraint
        accessoryStackView = stack
        return container
    }()

    private weak var accessoryStackView: UIStackView?
    // Strong reference — command button is not always in the stack's arrangedSubviews,
    // so nothing else retains it.
    private var commandAccessoryButton: UIButton?
    private var isMacRemote = false

    func updateAccessoryLayoutInsets() {
        let insets = accessoryLayoutInsetsProvider?() ?? .zero
        let leftInset = max(0, insets.left)
        let rightInset = max(0, insets.right)

        accessoryBackgroundLeadingConstraint?.constant = leftInset
        accessoryBackgroundTrailingConstraint?.constant = -rightInset
        accessoryDismissLeadingConstraint?.constant = Self.accessoryHorizontalInset + leftInset
        accessoryScrollTrailingConstraint?.constant = -(Self.accessoryHorizontalInset + rightInset)

        if accessoryStackView != nil {
            terminalAccessoryToolbar.setNeedsLayout()
            terminalAccessoryToolbar.layoutIfNeeded()
        }
    }

    func updateModifierLabels(isMacRemote: Bool) {
        guard self.isMacRemote != isMacRemote else { return }
        self.isMacRemote = isMacRemote
        guard let stack = accessoryStackView else { return }
        for case let button as UIButton in stack.arrangedSubviews {
            guard let action = TerminalInputAccessoryAction(rawValue: button.tag) else { continue }
            button.setTitle(action.title(isMacRemote: isMacRemote), for: .normal)
        }
        // Insert/remove the command button based on whether this is a Mac terminal.
        // We manage it outside the normal loop because it's not always in arrangedSubviews.
        if let cmdButton = commandAccessoryButton {
            if isMacRemote {
                if cmdButton.superview == nil {
                    // Insert after alternate (index 2 in original enum order: ctrl, alt, cmd)
                    // Find the alt button's index in the current arrangedSubviews
                    var insertIndex = stack.arrangedSubviews.count
                    for (idx, view) in stack.arrangedSubviews.enumerated() {
                        if view.tag == TerminalInputAccessoryAction.alternate.rawValue {
                            insertIndex = idx + 1
                            break
                        }
                    }
                    stack.insertArrangedSubview(cmdButton, at: insertIndex)
                }
            } else {
                if cmdButton.superview != nil {
                    stack.removeArrangedSubview(cmdButton)
                    cmdButton.removeFromSuperview()
                }
            }
        }
        // Disarm command state if switching away from Mac remote
        if !isMacRemote && commandAccessoryArmed {
            setCommandAccessoryArmed(false)
        }
    }

    init() {
        super.init(frame: .zero, textContainer: nil)
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no
        keyboardType = .default
        returnKeyType = .default
        textContainerInset = .zero
        inputAccessoryView = terminalAccessoryToolbar
        delegate = self
        text = ""
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        TerminalInputDebugLog.log("proxy.insertText text=\(TerminalInputDebugLog.textSummary(text)) composing=\(markedTextRange != nil)")
        if markedTextRange != nil {
            pendingDirectInsertMirrorText = ""
            super.insertText(text)
            return
        }
        rememberDirectInsertMirror(text)
        emitCommittedText(text, source: "insertText")
    }

    override func deleteBackward() {
        if commandAccessoryArmed, markedTextRange == nil, !hasText {
            if !commandAccessorySticky {
                setCommandAccessoryArmed(false)
            }
            // Cmd+Backspace on Mac = delete to start of line (Ctrl+U / 0x15)
            onEscapeSequence?(Data([0x15]))
            return
        }
        if alternateAccessoryArmed, markedTextRange == nil, !hasText {
            if !alternateAccessorySticky {
                setAlternateAccessoryArmed(false)
            }
            if let output = TerminalHardwareKeyResolver.data(
                input: UIKeyCommand.inputDelete,
                modifierFlags: [.alternate]
            ) {
                onEscapeSequence?(output)
            }
            return
        }
        if controlAccessoryArmed, markedTextRange == nil, !hasText {
            if !controlAccessorySticky {
                setControlAccessoryArmed(false)
            }
            onBackspace?()
            return
        }
        if markedTextRange != nil || hasText {
            super.deleteBackward()
            return
        }
        onBackspace?()
    }

    func simulateTextChangeForTesting(_ text: String, isComposing: Bool) {
        self.text = text
        handleTextChange(currentText: text, isComposing: isComposing)
    }

    func simulateHardwareKeyCommandForTesting(input: String, modifierFlags: UIKeyModifierFlags) -> Bool {
        handleHardwareKeyInput(input: input, modifierFlags: modifierFlags)
    }

    func simulateAccessoryActionForTesting(_ action: TerminalInputAccessoryAction) {
        resetStickyTapTimeForTesting(action)
        handleAccessoryAction(action)
    }

    private func resetStickyTapTimeForTesting(_ action: TerminalInputAccessoryAction) {
        switch action {
        case .control:
            lastControlTapTime = nil
        case .alternate:
            lastAlternateTapTime = nil
        case .command:
            lastCommandTapTime = nil
        case .shift:
            lastShiftTapTime = nil
        default:
            break
        }
    }

    @objc
    private func handleHardwareKeyCommand(_ sender: UIKeyCommand) {
        guard let input = sender.input else { return }
        _ = handleHardwareKeyInput(input: input, modifierFlags: sender.modifierFlags)
    }

    @objc
    private func handleHideKeyboard() {
        onHideKeyboard?()
    }

    @objc
    private func handleAccessoryButton(_ sender: Any) {
        guard let button = sender as? UIView,
              let action = TerminalInputAccessoryAction(rawValue: button.tag) else { return }
        handleAccessoryAction(action)
    }

    @discardableResult
    private func handleHardwareKeyInput(input: String, modifierFlags: UIKeyModifierFlags) -> Bool {
        guard let data = TerminalHardwareKeyResolver.data(input: input, modifierFlags: modifierFlags) else {
            return false
        }
        onEscapeSequence?(data)
        return true
    }

    private static let stickyDoubleTapInterval: TimeInterval = 0.4

    private func makeAccessoryButton(for action: TerminalInputAccessoryAction) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tag = action.rawValue
        button.addTarget(self, action: #selector(handleAccessoryButton(_:)), for: .touchUpInside)
        button.accessibilityIdentifier = action.accessibilityIdentifier
        button.accessibilityLabel = action.accessibilityLabel
        button.titleLabel?.font = Self.accessoryButtonFont

        if let symbolName = action.symbolName {
            button.setImage(UIImage(systemName: symbolName), for: .normal)
            button.setPreferredSymbolConfiguration(Self.accessoryButtonSymbolConfig, forImageIn: .normal)
        } else {
            button.setTitle(action.title, for: .normal)
        }

        applyAccessoryButtonBaseStyle(button)
        return button
    }

    private func applyAccessoryButtonBaseStyle(_ button: UIButton) {
        button.contentEdgeInsets = Self.accessoryButtonInsets
        button.backgroundColor = Self.accessoryButtonNormalBackground
        button.setTitleColor(.white, for: .normal)
        button.tintColor = .white
        button.layer.cornerRadius = Self.accessoryButtonCornerRadius
        button.heightAnchor.constraint(equalToConstant: Self.accessoryButtonHeight).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.accessoryButtonMinWidth).isActive = true
    }

    private func handleAccessoryAction(_ action: TerminalInputAccessoryAction) {
        if let zoomDirection = action.zoomDirection {
            disarmAllModifiers()
            refreshAccessoryButtonStyles()
            onZoom?(zoomDirection)
            return
        }

        if controlAccessoryArmed,
           !action.isModifier {
            if !controlAccessorySticky {
                setControlAccessoryArmed(false)
            }
            if let output = action.output {
                onEscapeSequence?(output)
            }
            return
        }

        if alternateAccessoryArmed,
           !action.isModifier {
            if !alternateAccessorySticky {
                setAlternateAccessoryArmed(false)
            }
            if let output = alternateAccessoryOutput(for: action) {
                onEscapeSequence?(output)
            }
            return
        }

        if commandAccessoryArmed,
           !action.isModifier {
            if !commandAccessorySticky {
                setCommandAccessoryArmed(false)
            }
            if let output = commandAccessoryOutput(for: action) {
                onEscapeSequence?(output)
            }
            return
        }

        switch action {
        case .control:
            toggleControlModifier()
        case .alternate:
            toggleAlternateModifier()
        case .command:
            toggleCommandModifier()
        case .shift:
            toggleShiftModifier()
        default:
            if let output = action.output {
                onEscapeSequence?(output)
            }
        }
    }

    private func disarmAllModifiers() {
        controlAccessoryArmed = false; controlAccessorySticky = false; lastControlTapTime = nil
        alternateAccessoryArmed = false; alternateAccessorySticky = false; lastAlternateTapTime = nil
        commandAccessoryArmed = false; commandAccessorySticky = false; lastCommandTapTime = nil
        shiftAccessoryArmed = false; shiftAccessorySticky = false; lastShiftTapTime = nil
    }

    private func toggleControlModifier() {
        let now = Date()
        if controlAccessorySticky {
            disarmAllModifiers()
        } else if controlAccessoryArmed, let last = lastControlTapTime, now.timeIntervalSince(last) < Self.stickyDoubleTapInterval {
            controlAccessorySticky = true
            lastControlTapTime = nil
        } else {
            let shouldArm = !controlAccessoryArmed
            disarmAllModifiers()
            controlAccessoryArmed = shouldArm
            lastControlTapTime = shouldArm ? now : nil
        }
        refreshAccessoryButtonStyles()
    }

    private func toggleAlternateModifier() {
        let now = Date()
        if alternateAccessorySticky {
            disarmAllModifiers()
        } else if alternateAccessoryArmed, let last = lastAlternateTapTime, now.timeIntervalSince(last) < Self.stickyDoubleTapInterval {
            alternateAccessorySticky = true
            lastAlternateTapTime = nil
        } else {
            let shouldArm = !alternateAccessoryArmed
            disarmAllModifiers()
            alternateAccessoryArmed = shouldArm
            lastAlternateTapTime = shouldArm ? now : nil
        }
        refreshAccessoryButtonStyles()
    }

    private func toggleCommandModifier() {
        let now = Date()
        if commandAccessorySticky {
            disarmAllModifiers()
        } else if commandAccessoryArmed, let last = lastCommandTapTime, now.timeIntervalSince(last) < Self.stickyDoubleTapInterval {
            commandAccessorySticky = true
            lastCommandTapTime = nil
        } else {
            let shouldArm = !commandAccessoryArmed
            disarmAllModifiers()
            commandAccessoryArmed = shouldArm
            lastCommandTapTime = shouldArm ? now : nil
        }
        refreshAccessoryButtonStyles()
    }

    private func toggleShiftModifier() {
        let now = Date()
        if shiftAccessorySticky {
            disarmAllModifiers()
        } else if shiftAccessoryArmed, let last = lastShiftTapTime, now.timeIntervalSince(last) < Self.stickyDoubleTapInterval {
            shiftAccessorySticky = true
            lastShiftTapTime = nil
        } else {
            let shouldArm = !shiftAccessoryArmed
            disarmAllModifiers()
            shiftAccessoryArmed = shouldArm
            lastShiftTapTime = shouldArm ? now : nil
        }
        refreshAccessoryButtonStyles()
    }

    private func refreshAccessoryButtonStyles() {
        guard let stack = accessoryStackView else { return }
        for case let button as UIButton in stack.arrangedSubviews {
            guard let action = TerminalInputAccessoryAction(rawValue: button.tag) else { continue }
            let armed = isAccessoryActionArmed(action)
            let sticky = isAccessoryActionSticky(action)
            if sticky {
                button.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
                button.setTitleColor(.white, for: .normal)
                button.tintColor = .white
                button.layer.borderWidth = 2
                button.layer.borderColor = UIColor.white.cgColor
            } else if armed {
                button.backgroundColor = .systemBlue
                button.setTitleColor(.white, for: .normal)
                button.tintColor = .white
                button.layer.borderWidth = 0
            } else {
                button.backgroundColor = Self.accessoryButtonNormalBackground
                button.setTitleColor(.white, for: .normal)
                button.tintColor = .white
                button.layer.borderWidth = 0
            }
        }
    }

    private func handleTextChange(currentText: String, isComposing: Bool) {
        TerminalInputDebugLog.log("proxy.textChange text=\(TerminalInputDebugLog.textSummary(currentText)) composing=\(isComposing) pendingDirect=\(TerminalInputDebugLog.textSummary(pendingDirectInsertMirrorText))")
        if isComposing {
            pendingDirectInsertMirrorText = ""
        } else if !pendingDirectInsertMirrorText.isEmpty {
            if currentText == pendingDirectInsertMirrorText {
                TerminalInputDebugLog.log("proxy.textChange suppressed direct insert mirror text=\(TerminalInputDebugLog.textSummary(currentText))")
                pendingDirectInsertMirrorText = ""
                if text != "" {
                    text = ""
                }
                return
            }
            pendingDirectInsertMirrorText = ""
        }

        let result = TerminalTextInputPipeline.process(text: currentText, isComposing: isComposing)
        if let committedText = result.committedText {
            emitCommittedText(committedText, source: "textChange")
        }
        if text != result.nextBufferText {
            text = result.nextBufferText
        }
    }

    private func rememberDirectInsertMirror(_ insertedText: String) {
        pendingDirectInsertMirrorText.append(insertedText)
        if pendingDirectInsertMirrorText.count > Self.directInsertMirrorTextLimit {
            pendingDirectInsertMirrorText = String(
                pendingDirectInsertMirrorText.suffix(Self.directInsertMirrorTextLimit)
            )
        }
    }

    private func emitCommittedText(_ committedText: String, source: String) {
        TerminalInputDebugLog.log("proxy.emit source=\(source) text=\(TerminalInputDebugLog.textSummary(committedText))")
        if controlAccessoryArmed {
            if !controlAccessorySticky {
                setControlAccessoryArmed(false)
            }
            if let controlSequence = controlSequence(for: committedText) {
                onEscapeSequence?(controlSequence)
            } else {
                onText?(committedText)
            }
        } else if alternateAccessoryArmed {
            if !alternateAccessorySticky {
                setAlternateAccessoryArmed(false)
            }
            if let alternateSequence = alternateSequence(for: committedText) {
                onEscapeSequence?(alternateSequence)
            } else {
                onText?(committedText)
            }
        } else if commandAccessoryArmed {
            if !commandAccessorySticky {
                setCommandAccessoryArmed(false)
            }
            if let commandSequence = commandTextSequence(for: committedText) {
                onEscapeSequence?(commandSequence)
            } else {
                onText?(committedText)
            }
        } else if shiftAccessoryArmed {
            if !shiftAccessorySticky {
                setShiftAccessoryArmed(false)
            }
            onText?(committedText.uppercased())
        } else {
            onText?(committedText)
        }
    }

    /// Translate Cmd+<letter> typed through the soft keyboard into Mac-terminal
    /// readline shortcuts (cmd+a = start of line, cmd+e = end, cmd+k = kill line, etc).
    private func commandTextSequence(for text: String) -> Data? {
        guard text.count == 1, let char = text.lowercased().first else { return nil }
        switch char {
        case "a": return Data([0x01]) // Ctrl+A - beginning of line
        case "e": return Data([0x05]) // Ctrl+E - end of line
        case "k": return Data([0x0B]) // Ctrl+K - kill to end of line
        case "u": return Data([0x15]) // Ctrl+U - kill to start of line
        case "w": return Data([0x17]) // Ctrl+W - delete previous word
        case "l": return Data([0x0C]) // Ctrl+L - clear screen
        case "c": return Data([0x03]) // Ctrl+C - SIGINT
        case "d": return Data([0x04]) // Ctrl+D - EOF
        default: return nil
        }
    }

    private func controlSequence(for text: String) -> Data? {
        guard text.count == 1 else { return nil }
        return TerminalHardwareKeyResolver.data(input: text, modifierFlags: [.control])
    }

    private func alternateSequence(for text: String) -> Data? {
        guard let encoded = text.data(using: .utf8), !encoded.isEmpty else { return nil }
        var sequence = Data([0x1B])
        sequence.append(encoded)
        return sequence
    }

    private func alternateAccessoryOutput(for action: TerminalInputAccessoryAction) -> Data? {
        switch action {
        case .leftArrow:
            return TerminalHardwareKeyResolver.data(
                input: UIKeyCommand.inputLeftArrow,
                modifierFlags: [.alternate]
            )
        case .rightArrow:
            return TerminalHardwareKeyResolver.data(
                input: UIKeyCommand.inputRightArrow,
                modifierFlags: [.alternate]
            )
        case .control, .alternate, .command:
            return nil
        default:
            guard let output = action.output else { return nil }
            var sequence = Data([0x1B])
            sequence.append(output)
            return sequence
        }
    }

    /// Translate Cmd+<key> into the equivalent Mac-terminal readline sequence.
    /// Cmd+Left/Right = start/end of line (Ctrl+A / Ctrl+E).
    /// Cmd+Backspace is handled directly in deleteBackward() as Ctrl+U.
    private func commandAccessoryOutput(for action: TerminalInputAccessoryAction) -> Data? {
        switch action {
        case .leftArrow:
            return Data([0x01]) // Ctrl+A - beginning of line
        case .rightArrow:
            return Data([0x05]) // Ctrl+E - end of line
        case .upArrow:
            // Cmd+Up on Mac often scrolls; just send the raw arrow
            return TerminalHardwareKeyResolver.data(
                input: UIKeyCommand.inputUpArrow,
                modifierFlags: []
            )
        case .downArrow:
            return TerminalHardwareKeyResolver.data(
                input: UIKeyCommand.inputDownArrow,
                modifierFlags: []
            )
        case .control, .alternate, .command, .shift:
            return nil
        default:
            return action.output
        }
    }

    private func isAccessoryActionArmed(_ action: TerminalInputAccessoryAction) -> Bool {
        switch action {
        case .control: return controlAccessoryArmed
        case .alternate: return alternateAccessoryArmed
        case .command: return commandAccessoryArmed
        case .shift: return shiftAccessoryArmed
        default: return false
        }
    }

    private func isAccessoryActionSticky(_ action: TerminalInputAccessoryAction) -> Bool {
        switch action {
        case .control: return controlAccessorySticky
        case .alternate: return alternateAccessorySticky
        case .command: return commandAccessorySticky
        case .shift: return shiftAccessorySticky
        default: return false
        }
    }

    private func setCommandAccessoryArmed(_ armed: Bool) {
        guard commandAccessoryArmed != armed else { return }
        commandAccessoryArmed = armed
        if !armed {
            commandAccessorySticky = false
            lastCommandTapTime = nil
        }
        refreshAccessoryButtonStyles()
    }

    private func setControlAccessoryArmed(_ armed: Bool) {
        guard controlAccessoryArmed != armed else { return }
        controlAccessoryArmed = armed
        if !armed {
            controlAccessorySticky = false
            lastControlTapTime = nil
        }
        refreshAccessoryButtonStyles()
    }

    private func setAlternateAccessoryArmed(_ armed: Bool) {
        guard alternateAccessoryArmed != armed else { return }
        alternateAccessoryArmed = armed
        if !armed {
            alternateAccessorySticky = false
            lastAlternateTapTime = nil
        }
        refreshAccessoryButtonStyles()
    }

    private func setShiftAccessoryArmed(_ armed: Bool) {
        guard shiftAccessoryArmed != armed else { return }
        shiftAccessoryArmed = armed
        if !armed {
            shiftAccessorySticky = false
            lastShiftTapTime = nil
        }
        refreshAccessoryButtonStyles()
    }
}

extension TerminalInputTextView: UITextViewDelegate {
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        TerminalInputDebugLog.log("proxy.shouldChange replacement=\(TerminalInputDebugLog.textSummary(text)) marked=\(textView.markedTextRange != nil) range=\(range.location):\(range.length)")
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        handleTextChange(
            currentText: textView.text ?? "",
            isComposing: textView.markedTextRange != nil
        )
    }
}

private class DisplayLinkProxy {
    private weak var target: GhosttySurfaceView?

    init(target: GhosttySurfaceView) {
        self.target = target
    }

    @objc func handleDisplayLink() {
        target?.handleDisplayLinkFire()
    }
}

// MARK: - Arrow Nub (draggable directional pad)

final class TerminalArrowNubView: UIView {
    var onArrowKey: ((Data) -> Void)?

    private let nubSize: CGFloat = 34
    private let deadZone: CGFloat = 8
    private let repeatInterval: TimeInterval = 0.08
    private let innerDot = UIView()
    private var dragOrigin: CGPoint = .zero
    private var repeatTimer: Timer?
    private var lastDirection: Direction?
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

    private enum Direction {
        case up, down, left, right
        var escapeSequence: Data {
            switch self {
            case .up:    return Data([0x1B, 0x5B, 0x41])
            case .down:  return Data([0x1B, 0x5B, 0x42])
            case .right: return Data([0x1B, 0x5B, 0x43])
            case .left:  return Data([0x1B, 0x5B, 0x44])
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.25, alpha: 0.85)
        layer.cornerRadius = nubSize / 2

        innerDot.backgroundColor = UIColor(white: 0.85, alpha: 1)
        innerDot.layer.cornerRadius = 6
        innerDot.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        innerDot.layer.shadowColor = UIColor.white.cgColor
        innerDot.layer.shadowOpacity = 0.3
        innerDot.layer.shadowRadius = 3
        innerDot.layer.shadowOffset = .zero
        addSubview(innerDot)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)

        feedbackGenerator.prepare()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if repeatTimer == nil {
            innerDot.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: nubSize, height: nubSize)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            dragOrigin = innerDot.center
            feedbackGenerator.prepare()
        case .changed:
            let maxOffset: CGFloat = nubSize / 2 - 8
            let clampedX = max(-maxOffset, min(maxOffset, translation.x))
            let clampedY = max(-maxOffset, min(maxOffset, translation.y))
            innerDot.center = CGPoint(x: dragOrigin.x + clampedX, y: dragOrigin.y + clampedY)

            let direction = directionFrom(dx: translation.x, dy: translation.y)
            if direction != lastDirection {
                lastDirection = direction
                stopRepeat()
                if let direction {
                    fireArrow(direction)
                    startRepeat(direction)
                }
            }
        case .ended, .cancelled:
            stopRepeat()
            lastDirection = nil
            UIView.animate(withDuration: 0.15) {
                self.innerDot.center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
            }
        default:
            break
        }
    }

    private func directionFrom(dx: CGFloat, dy: CGFloat) -> Direction? {
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > deadZone else { return nil }
        if abs(dx) > abs(dy) {
            return dx > 0 ? .right : .left
        } else {
            return dy > 0 ? .down : .up
        }
    }

    private func fireArrow(_ direction: Direction) {
        feedbackGenerator.impactOccurred()
        onArrowKey?(direction.escapeSequence)
    }

    private func startRepeat(_ direction: Direction) {
        repeatTimer = Timer.scheduledTimer(withTimeInterval: repeatInterval, repeats: true) { [weak self] _ in
            self?.fireArrow(direction)
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}
