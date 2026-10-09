#if os(iOS)
import CNCore
import CNDesign
import CNTransport
import UIKit

/// One attached terminal: a Ghostty surface fed by the host's `termOutput`
/// stream, with typed input sent back as `termInput`.
///
/// - Attach uses the grid that fits the view; the host replays scrollback
///   first, so the surface is reset before every attach (first attach,
///   reconnect, return to the screen).
/// - The keyboard never changes the grid (plans/cmux-next/ios-keyboard.md
///   D8): the view keeps its height and pans up so the cursor row stays
///   above the keyboard and its key bar, on the keyboard's curve.
/// - A size or text size change locks the new grid locally and sends
///   `term.resize`, debounced.
@MainActor
final class TerminalViewController: UIViewController, UIGestureRecognizerDelegate, @MainActor UIEditMenuInteractionDelegate {
    let connection: HostConnection
    let terminalId: String
    let model: TerminalScreenModel
    let terminalView = GhosttyTerminalView(frame: .zero)
    /// The keyboard's frame (with its key bar) in window coordinates, from
    /// the keyboard notifications; nil while it is hidden.
    private var keyboardFrame: CGRect?
    private var keyboardObservers: [any NSObjectProtocol] = []
    private var bottomConstraint: NSLayoutConstraint?
    private let clock: any Clock<Duration>

    /// The connection generation the stream belongs to (0: not attached).
    private var attachedGeneration = 0
    private var attaching = false
    private var streamId: UInt32?
    private weak var client: HostClient?
    private var streamTask: Task<Void, Never>?
    private var attachTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    /// The grid the host has (or was last asked for).
    private var hostGrid: (cols: Int, rows: Int)?
    private var gridGeneration: UInt64 = 0
    private var visible = false

    private var momentum: ScrollMomentum?
    private var pinchBase: Double = TerminalFontSize.defaultSize
    private var editMenu: UIEditMenuInteraction?

    /// `term.resize` waits this long for the size to settle (pinch, rotation).
    static let resizeDebounce: Duration = .milliseconds(150)
    static let cursorMargin: CGFloat = 4

    init(connection: HostConnection, terminalId: String, model: TerminalScreenModel,
         clock: any Clock<Duration> = ContinuousClock()) {
        self.connection = connection
        self.terminalId = terminalId
        self.model = model
        self.clock = clock
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        for observer in keyboardObservers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = CNTheme.shared.palette.terminalBackground
        view.clipsToBounds = true
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)
        let bottom = terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        bottomConstraint = bottom
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            // The keyboard never changes the grid's rows: the bottom follows
            // the window's safe area (home indicator), never the keyboard.
            bottom,
        ])
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
            keyboardObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] note in
                let info = KeyboardChange(note)
                MainActor.assumeIsolated { self?.keyboardWillChange(info) }
            })
        }
        installGestures()
        terminalView.onDraw = { [weak self] in
            self?.panToCursor()
            self?.sync()
        }
        terminalView.onReady = { [weak self] in self?.sync() }
        terminalView.onInput = { [weak self] data in self?.send(data) }
        model.controller = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        sync()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        visible = false
        detach()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Keep the grid above the home indicator, measured against the window
        // (the hosting view may or may not extend under it; never the keyboard).
        var homeIndicator: CGFloat = 0
        if let window = view.window {
            let bottomInWindow = view.convert(CGPoint(x: 0, y: view.bounds.maxY), to: window).y
            homeIndicator = max(0, window.safeAreaInsets.bottom - (window.bounds.height - bottomInWindow))
        }
        if bottomConstraint?.constant != -homeIndicator { bottomConstraint?.constant = -homeIndicator }
        panToCursor()
        sync()
    }

    // MARK: Attach, resize, reconnect

    /// The connection generation changed (reconnect) or the view is ready.
    func sync() {
        guard visible, terminalView.surface != nil, !attaching else { return }
        let fit = terminalView.fittingGrid
        guard fit.cols >= 2, fit.rows >= 2 else { return }
        let generation = connection.generation
        if generation != attachedGeneration {
            guard let client = connection.client else {
                model.status = connection.state.isConnected ? .attaching : .reconnecting
                return
            }
            attach(client: client, generation: generation, grid: fit)
            return
        }
        if let hostGrid, hostGrid != fit { scheduleResize(fit) }
    }

    private func attach(client: HostClient, generation: Int, grid: (cols: Int, rows: Int)) {
        streamTask?.cancel()
        resizeTask?.cancel()
        if let streamId, let old = self.client { old.closeStream(id: streamId) }
        streamId = nil
        attaching = true
        model.status = .attaching
        #if DEBUG
        TerminalTrace.shared.log("attach generation=\(generation) grid=\(grid.cols)x\(grid.rows)")
        #endif
        // The host replays the scrollback: start from a clean terminal.
        terminalView.resetTerminal()
        lockGrid(grid)
        let terminalId = self.terminalId
        attachTask = Task { [weak self] in
            do {
                let result = try await client.attachTerminal(terminalId, cols: grid.cols, rows: grid.rows)
                guard let self else { return }
                self.attaching = false
                guard !Task.isCancelled, self.visible, self.connection.generation == generation else {
                    try? await client.detachTerminal(streamId: result.streamId)
                    self.sync()
                    return
                }
                self.client = client
                self.streamId = result.streamId
                self.attachedGeneration = generation
                self.model.terminal = result.terminal
                self.model.status = result.terminal.running ? .live : .exited
                self.startStream(client: client, streamId: result.streamId)
                // The view may have changed size while attaching.
                self.sync()
            } catch {
                guard let self else { return }
                self.attaching = false
                self.model.status = .failed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            }
        }
    }

    private func startStream(client: HostClient, streamId: UInt32) {
        let frames = client.openStream(id: streamId)
        streamTask = Task { [weak self] in
            for await bytes in frames {
                guard let self else { return }
                self.terminalView.feed(bytes)
                self.model.outputBytes += bytes.count
            }
            // The link closed: the next generation re-attaches.
            guard let self, !Task.isCancelled else { return }
            if self.streamId == streamId { self.model.status = .reconnecting }
            #if DEBUG
            TerminalTrace.shared.log("stream \(streamId) ended")
            #endif
        }
    }

    private func detach() {
        attachTask?.cancel()
        streamTask?.cancel()
        resizeTask?.cancel()
        attaching = false
        attachedGeneration = 0
        hostGrid = nil
        if let streamId, let client {
            Task { try? await client.detachTerminal(streamId: streamId) }
        }
        streamId = nil
    }

    private func lockGrid(_ grid: (cols: Int, rows: Int)) {
        hostGrid = grid
        gridGeneration += 1
        terminalView.setGrid(cols: grid.cols, rows: grid.rows, generation: gridGeneration)
        model.grid = "\(grid.cols)×\(grid.rows)"
        updateDebugValue()
    }

    /// DEBUG: grid, text size and keyboard pan, readable with `axe describe-ui`.
    private func updateDebugValue() {
        #if DEBUG
        let grid = hostGrid.map { "\($0.cols)x\($0.rows)" } ?? "none"
        let value = "grid=\(grid) font=\(terminalView.fontSize) shift=\(Int(model.keyboardShift.rounded())) theme=\(terminalView.diagnostics["theme"] ?? "?")"
        if terminalView.accessibilityValue != value { terminalView.accessibilityValue = value }
        #endif
    }

    private func scheduleResize(_ grid: (cols: Int, rows: Int)) {
        resizeTask?.cancel()
        let clock = self.clock
        let terminalId = self.terminalId
        resizeTask = Task { [weak self] in
            // Intentional bounded delay: coalesce pinch and rotation steps.
            do { try await clock.sleep(for: Self.resizeDebounce) } catch { return }
            guard let self, let client = self.client, self.streamId != nil else { return }
            let fit = self.terminalView.fittingGrid
            guard fit.cols >= 2, fit.rows >= 2, self.hostGrid.map({ $0 != fit }) ?? true else { return }
            self.lockGrid(fit)
            try? await client.resizeTerminal(terminalId, cols: fit.cols, rows: fit.rows)
        }
    }

    private func send(_ data: Data) {
        guard let streamId, let client else { return }
        try? client.sendTerminalInput(streamId: streamId, data)
    }

    // MARK: Keyboard pan

    /// Shows the keyboard (user action only).
    func focusInput() { terminalView.becomeFirstResponder() }

    /// The keyboard moves: pan on its own curve and duration. Only the
    /// keyboard's end frame counts (in window coordinates), so layout passes
    /// of the hosting view during the move cannot make the terminal jump.
    private func keyboardWillChange(_ change: KeyboardChange) {
        guard let window = view.window else { return }
        let end = window.convert(change.endFrame, from: window.screen.coordinateSpace)
        keyboardFrame = change.hiding || end.minY >= window.bounds.maxY - 1 ? nil : end
        let animations = { self.panToCursor() }
        if change.duration > 0, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: change.duration, delay: 0,
                           options: [UIView.AnimationOptions(rawValue: change.curve << 16), .beginFromCurrentState],
                           animations: animations)
        } else {
            animations()
        }
    }

    /// The keyboard never changes the grid (D8): while it covers the cursor
    /// row, the terminal moves up just enough to show that row above the
    /// keyboard and its key bar. Keyboard moves animate on the keyboard's
    /// curve; after output the move is immediate.
    private func panToCursor() {
        guard let window = view.window else { return }
        let cursor = terminalView.cursorRect
        guard cursor.height > 0 else { return }
        // The resting frame (center and bounds ignore the transform), in the window.
        let restingTop = view.convert(CGPoint(x: 0, y: terminalView.center.y - terminalView.bounds.height / 2), to: window).y
        let cursorBottom = restingTop + cursor.maxY + Self.cursorMargin
        let keyboardTopY = keyboardFrame?.minY ?? window.bounds.maxY
        let shift = terminalView.isFirstResponder ? max(0, cursorBottom - keyboardTopY) : 0
        let transform = CGAffineTransform(translationX: 0, y: -shift)
        if terminalView.transform != transform { terminalView.transform = transform }
        if model.keyboardShift != shift { model.keyboardShift = shift }
        updateDebugValue()
        #if DEBUG
        TerminalTrace.shared.log("pan shift=\(shift) kbTop=\(keyboardTopY) cursorBottom=\(cursorBottom) restingTop=\(restingTop) viewInWindow=\(view.convert(view.bounds, to: nil)) fr=\(terminalView.isFirstResponder)")
        #endif
    }

    // MARK: Gestures

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        press.minimumPressDuration = 0.35
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        tap.require(toFail: press)
        for recognizer in [tap, pan, press, pinch] as [UIGestureRecognizer] {
            terminalView.addGestureRecognizer(recognizer)
        }
        let menu = UIEditMenuInteraction(delegate: self)
        terminalView.addInteraction(menu)
        editMenu = menu
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        momentum?.stop()
        if terminalView.hasSelection {
            terminalView.clearSelection()
            return
        }
        focusInput()
    }

    /// One finger drags the scrollback (Ghostty scroll), with momentum.
    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            momentum?.stop()
        case .changed:
            let dy = recognizer.translation(in: terminalView).y
            recognizer.setTranslation(.zero, in: terminalView)
            terminalView.scroll(byPoints: dy)
        case .ended:
            let velocity = recognizer.velocity(in: terminalView).y
            guard !UIAccessibility.isReduceMotionEnabled, abs(velocity) > 200 else { return }
            let momentum = ScrollMomentum(velocity: velocity) { [weak self] dy in self?.terminalView.scroll(byPoints: dy) }
            self.momentum = momentum
            momentum.start()
        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: terminalView)
        return abs(v.y) > abs(v.x)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    /// Long press selects a word; dragging extends it; release shows Copy.
    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: terminalView)
        switch recognizer.state {
        case .began:
            momentum?.stop()
            editMenu?.dismissMenu()
            terminalView.beginSelection(at: point)
            UISelectionFeedbackGenerator().selectionChanged()
        case .changed:
            terminalView.extendSelection(to: point)
        case .ended:
            terminalView.endSelection()
            if terminalView.hasSelection {
                editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
            }
        case .cancelled, .failed:
            terminalView.endSelection()
        default:
            break
        }
    }

    /// Pinch changes the text size; the grid follows (debounced resize).
    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinchBase = terminalView.fontSize
            terminalView.pinching = true
        case .changed:
            terminalView.setFontSize(pinchBase * Double(recognizer.scale))
            model.fontSize = terminalView.fontSize
        case .ended, .cancelled:
            terminalView.pinching = false
            TerminalFontSize.store(terminalView.fontSize)
            model.fontSize = terminalView.fontSize
        default:
            break
        }
    }

    func stepFontSize(by points: Double) {
        terminalView.setFontSize(terminalView.fontSize + points)
        TerminalFontSize.store(terminalView.fontSize)
        model.fontSize = terminalView.fontSize
    }

    func resetFontSize() {
        terminalView.setFontSize(TerminalFontSize.defaultSize)
        TerminalFontSize.store(TerminalFontSize.defaultSize)
        model.fontSize = terminalView.fontSize
    }

    func paste() { terminalView.paste(nil) }
    func copySelection() { terminalView.copy(nil) }
    func selectAll() { terminalView.selectAll() }
    var hasSelection: Bool { terminalView.hasSelection }

    // MARK: Edit menu

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        var actions: [UIMenuElement] = []
        if terminalView.hasSelection {
            actions.append(UIAction(title: TerminalText.copy, image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copySelection()
                self?.terminalView.clearSelection()
            })
        }
        if UIPasteboard.general.hasStrings {
            actions.append(UIAction(title: TerminalText.paste, image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.paste()
            })
        }
        actions.append(UIAction(title: TerminalText.selectAll) { [weak self] _ in
            self?.selectAll()
        })
        return UIMenu(children: actions)
    }
}

/// The parts of a keyboard notification the pan needs (Sendable across the hop).
struct KeyboardChange: Sendable {
    let endFrame: CGRect
    let duration: TimeInterval
    let curve: UInt
    let hiding: Bool

    init(_ note: Notification) {
        let info = note.userInfo ?? [:]
        endFrame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
        curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        hiding = note.name == UIResponder.keyboardWillHideNotification
    }
}

#if DEBUG
/// DEBUG: `CMUX_NEXT_TERMINAL_TRACE=1` appends layout traces to tmp/terminal-trace.log.
@MainActor
final class TerminalTrace {
    static let shared = TerminalTrace()
    private let handle: FileHandle?
    private let start = CACurrentMediaTime()

    private init() {
        guard ProcessInfo.processInfo.environment["CMUX_NEXT_TERMINAL_TRACE"] == "1" else { handle = nil; return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-trace.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func log(_ line: String) {
        guard let handle else { return }
        handle.write(Data((String(format: "%.3f ", CACurrentMediaTime() - start) + line + "\n").utf8))
    }
}
#endif

/// Scroll momentum after a fling: UIScrollView's normal deceleration
/// (0.998 per ms), driven by the display's frame callbacks.
@MainActor
final class ScrollMomentum: NSObject {
    private var velocity: CGFloat
    private let step: (CGFloat) -> Void
    private var link: CADisplayLink?
    private var last: CFTimeInterval?

    static let decelerationPerMs: CGFloat = 0.998
    static let stopVelocity: CGFloat = 20

    init(velocity: CGFloat, step: @escaping (CGFloat) -> Void) {
        self.velocity = velocity
        self.step = step
        super.init()
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard let last else { return }
        let dt = link.timestamp - last
        velocity *= pow(Self.decelerationPerMs, CGFloat(dt * 1000))
        if abs(velocity) < Self.stopVelocity { stop(); return }
        step(velocity * CGFloat(dt))
    }
}
#endif
