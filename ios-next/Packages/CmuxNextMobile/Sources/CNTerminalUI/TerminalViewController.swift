#if os(iOS)
import CNCore
import CNDesign
import CNTransport
import SwiftUI
import UIKit

/// One attached terminal: a Ghostty surface fed by the host's `termOutput`
/// stream, with typed input sent back as `termInput`.
///
/// - Attach uses the grid that fits the view; the host replays scrollback
///   first, so the surface is reset before every attach (first attach,
///   reconnect, return to the screen).
/// - Keyboard (Aziz's decision, overriding plan D8 for this app): the grid
///   shrinks to the space between the nav bar and the top of the key bar /
///   composer while the software keyboard is up, and grows back when it
///   hides. During the keyboard animation the content slides with it (a
///   transform); when the animation ends the view takes the new height, the
///   grid is locked locally (content scrolled so the cursor stays on screen)
///   and one `term.resize` goes to the host. Full-screen apps redraw.
/// - Input: typing goes straight to the terminal (raw mode) or through the
///   composer row; the key bar works in both.
/// - A size or text size change locks the new grid locally and sends
///   `term.resize`, debounced.
@MainActor
final class TerminalViewController: UIViewController, UIGestureRecognizerDelegate, @MainActor UIEditMenuInteractionDelegate {
    let connection: HostConnection
    /// Nil until a new terminal is created (with the grid that fits the view,
    /// so the shell's first prompt is drawn at its final size).
    private(set) var terminalId: String?
    /// A new terminal was created on the host.
    var onCreated: ((String) -> Void)?
    let model: TerminalScreenModel
    let terminalView = GhosttyTerminalView(frame: .zero)
    /// The keyboard's frame (with its key bar) in window coordinates, from
    /// the keyboard notifications; nil while it is hidden.
    private var keyboardFrame: CGRect?
    private var keyboardObservers: [any NSObjectProtocol] = []
    private var bottomConstraint: NSLayoutConstraint?
    /// Composer (when shown) over the key bar, riding the keyboard's top.
    private let accessoryStack = UIStackView()
    let keyBar = TerminalKeyBar(keys: TerminalKeyBarKey.defaultKeys)
    private var composerHost: UIHostingController<TerminalComposer>?
    private var composerFocused = false
    /// The settled top of whatever covers the bottom (key bar, composer,
    /// keyboard), in window coordinates; nil when nothing does. The terminal's
    /// height follows it only when a keyboard or accessory change settles.
    private var settledCoverTop: CGFloat?
    /// The cursor row before a grow; the next draw slides the content from
    /// there to where Ghostty put it.
    private var growCompensation: (row: Int, cellHeight: CGFloat)?
    private var compensating = false
    private let clock: any Clock<Duration>

    /// The connection generation the stream belongs to (0: not attached).
    private var attachedGeneration = 0
    private var attaching = false
    /// The generation whose attach failed: no retry until the next
    /// (re)connect, so a gone terminal never loops on attach.
    private var failedGeneration = 0
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
    private weak var scrollPan: UIPanGestureRecognizer?
    private var scrollPoint: CGPoint = .zero
    private var pinchBase: Double = TerminalFontSize.defaultSize
    private var editMenu: UIEditMenuInteraction?

    /// `term.resize` waits this long for the size to settle (pinch, rotation).
    static let resizeDebounce: Duration = .milliseconds(150)
    static let cursorMargin: CGFloat = 4

    init(connection: HostConnection, terminalId: String?, model: TerminalScreenModel,
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
        installAccessories()
        installGestures()
        terminalView.onFocusChange = { [weak self] _ in self?.inputFocusChanged() }
        terminalView.onDraw = { [weak self] in
            self?.applyGrowCompensation()
            self?.panToCursor()
            self?.sync()
        }
        terminalView.onReady = { [weak self] in self?.sync() }
        terminalView.onInput = { [weak self] data in self?.send(data) }
        model.controller = self
        #if DEBUG && targetEnvironment(simulator)
        // DEBUG harness: the headless simulator reports a hardware keyboard;
        // CMUX_NEXT_SOFTWARE_KEYBOARD=1 switches its input modes to the
        // software keyboard so keyboard layout can be measured (UI-test trick).
        if ProcessInfo.processInfo.environment["CMUX_NEXT_SOFTWARE_KEYBOARD"] == "1" {
            let selector = NSSelectorFromString("setHardwareLayout:")
            for mode in UITextInputMode.activeInputModes where mode.responds(to: selector) {
                mode.perform(selector, with: nil)
            }
        }
        #endif
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
        // The grid ends on the settled top of the key bar, composer or
        // keyboard (never the live, animating one).
        var inset = homeIndicator
        if let window = view.window, let coverTop = settledCoverTop {
            let bottomInWindow = view.convert(CGPoint(x: 0, y: view.bounds.maxY), to: window).y
            inset = max(inset, bottomInWindow - coverTop)
        }
        if bottomConstraint?.constant != -inset { bottomConstraint?.constant = -inset }
        if placeAccessories() { view.setNeedsLayout() }
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
            guard generation != failedGeneration, model.status != .ended else { return }
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
        let existingId = self.terminalId
        attachTask = Task { [weak self] in
            // A terminal this attach created; closed on the host if the attach
            // never completes, so no orphan PTY is left behind.
            var createdHere: String?
            do {
                var terminalId = existingId
                if terminalId == nil {
                    let created = try await client.createTerminal(cols: grid.cols, rows: grid.rows)
                    createdHere = created.id
                    terminalId = created.id
                    guard let self, !Task.isCancelled else {
                        try? await client.closeTerminal(created.id)
                        return
                    }
                    self.terminalId = created.id
                    self.model.terminal = created
                    self.onCreated?(created.id)
                }
                guard let terminalId else { return }
                let result = try await client.attachTerminal(terminalId, cols: grid.cols, rows: grid.rows)
                createdHere = nil
                guard let self else { return }
                self.attaching = false
                guard !Task.isCancelled, self.visible, self.connection.generation == generation else {
                    try? await client.detachTerminal(streamId: result.streamId)
                    client.closeStream(id: result.streamId)
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
                if let createdHere { try? await client.closeTerminal(createdHere) }
                guard let self else { return }
                if createdHere != nil { self.terminalId = nil }
                self.attaching = false
                self.failedGeneration = generation
                if let rpc = error as? RPCError, rpc.code == .notFound {
                    // The PTY is gone (the Mac's host restarted or it was closed).
                    self.model.status = .ended
                } else {
                    self.model.status = .failed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
                }
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
            Task {
                try? await client.detachTerminal(streamId: streamId)
                client.closeStream(id: streamId)
            }
        }
        streamId = nil
    }

    private func lockGrid(_ grid: (cols: Int, rows: Int)) {
        hostGrid = grid
        gridGeneration += 1
        // Ghostty keeps the cursor on screen itself: a shrink drops top rows,
        // a grow brings scrollback rows back (like a real terminal).
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
        guard let terminalId = self.terminalId else { return }
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

    /// Shows the keyboard for typing into the terminal (user action only).
    func focusInput() {
        if model.composerMode { setComposerMode(false) }
        terminalView.becomeFirstResponder()
    }

    private func installAccessories() {
        accessoryStack.axis = .vertical
        accessoryStack.spacing = 0
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStack.backgroundColor = CNTheme.shared.palette.terminalBackground
        let composer = UIHostingController(rootView: TerminalComposer(
            model: model,
            onSend: { [weak self] text, submit in self?.terminalView.sendComposed(text, submit: submit) },
            onAttach: { [weak self] attachment in self?.upload(attachment) },
            onFocusChange: { [weak self] focused in
                self?.composerFocused = focused
                self?.inputFocusChanged()
            },
            onHeightChange: { [weak self] in
                guard let self, let host = self.composerHost else { return }
                host.view.invalidateIntrinsicContentSize()
                self.relayoutAccessories(animated: true)
            }
        ))
        composer.sizingOptions = [.intrinsicContentSize]
        composer.view.backgroundColor = CNTheme.shared.palette.terminalBackground
        composer.view.isHidden = true
        addChild(composer)
        accessoryStack.addArrangedSubview(composer.view)
        composer.didMove(toParent: self)
        composerHost = composer
        keyBar.isHidden = true
        keyBar.onKey = { [weak self] key in self?.keyBarKey(key) }
        terminalView.keyBarView = keyBar
        accessoryStack.addArrangedSubview(keyBar)
        view.addSubview(accessoryStack)
        // The keyboard layout guide includes the keyboard's own bars and
        // follows the keyboard's animation; the stack rides its top.
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        NSLayoutConstraint.activate([
            accessoryStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            accessoryStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            accessoryStack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    private func keyBarKey(_ key: TerminalKeyBarKey) {
        switch key {
        case .composer:
            setComposerMode(!model.composerMode)
        case .hideKeyboard:
            if composerFocused { requestComposerFocus(false) } else { terminalView.resignFirstResponder() }
        default:
            terminalView.keyBarKey(key)
        }
    }

    /// Composer mode shows the input row and focuses it; raw mode types
    /// straight into the terminal.
    func setComposerMode(_ on: Bool) {
        guard model.composerMode != on else { return }
        model.composerMode = on
        keyBar.composerMode = on
        if on {
            requestComposerFocus(true)
        } else {
            requestComposerFocus(false)
            terminalView.becomeFirstResponder()
        }
        relayoutAccessories(animated: true)
    }

    private func endInputFocus() {
        if composerFocused {
            requestComposerFocus(false)
            composerHost?.view.endEditing(true)
        }
        if terminalView.isFirstResponder { terminalView.resignFirstResponder() }
    }

    private func requestComposerFocus(_ focused: Bool) {
        model.composerWantsFocus = focused
        model.composerFocusRequest += 1
    }

    private func inputFocusChanged() {
        relayoutAccessories(animated: true)
    }

    /// Uploads an attachment to the Mac and inserts its quoted path.
    private func upload(_ attachment: TerminalAttachment) {
        guard let client = connection.client else {
            model.uploadError = TerminalText.uploadFailed
            return
        }
        model.uploading += 1
        Task { [weak self] in
            do {
                defer { if let temp = attachment.temporary { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) } }
                let path = try await client.uploadFile(name: attachment.name, mimeType: attachment.mimeType, source: attachment.source)
                guard let self else { return }
                self.model.uploading -= 1
                let quoted = shellQuoted(path)
                let text = self.model.composerText
                let separator = text.isEmpty || text.hasSuffix(" ") ? "" : " "
                self.model.composerText = text + separator + quoted + " "
            } catch {
                guard let self else { return }
                self.model.uploading -= 1
                self.model.uploadError = (error as? LocalizedError)?.errorDescription ?? TerminalText.uploadFailed
            }
        }
    }

    /// The keyboard moves: accessories and pan follow on its own curve and
    /// duration. Only the keyboard's end frame counts (window coordinates),
    /// so layout passes of the hosting view during the move cannot make the
    /// terminal jump.
    private func keyboardWillChange(_ change: KeyboardChange) {
        guard let window = view.window else { return }
        let end = window.convert(change.endFrame, from: window.screen.coordinateSpace)
        keyboardFrame = change.hiding || end.minY >= window.bounds.maxY - 1 ? nil : end
        // The keyboard went down (swipe, Hide key, anything): drop focus so a
        // tap on the composer field or the terminal brings it back. Not with
        // a hardware keyboard, where the software keyboard is never shown.
        if keyboardFrame == nil, !GhosttyTerminalView.hardwareKeyboardAttached { endInputFocus() }
        let animations = {
            self.placeAccessories()
            self.view.layoutIfNeeded()
            self.panToCursor()
        }
        // Hiding: grow first (the keyboard uncovers the new rows as it goes);
        // showing: shrink once the keyboard has arrived.
        let growing = keyboardFrame == nil
        if growing { settle() }
        if change.duration > 0, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: change.duration, delay: 0,
                           options: [UIView.AnimationOptions(rawValue: change.curve << 16), .beginFromCurrentState],
                           animations: animations) { [weak self] _ in
                if !growing { self?.settle() }
            }
        } else {
            animations()
            if !growing { settle() }
        }
    }

    /// Gives the terminal the height above whatever now covers its bottom,
    /// locks the matching grid at once and sends one `term.resize`.
    private func settle() {
        guard let window = view.window else { return }
        placeAccessories()
        view.layoutIfNeeded()
        // Target positions, not the animating ones: the keyboard's end frame
        // (or the home indicator) minus the accessories' height.
        let accessoriesShown = !keyBar.isHidden || !(composerHost?.view.isHidden ?? true)
        let homeTop = window.bounds.maxY - window.safeAreaInsets.bottom
        let keyboardTop = min(keyboardFrame?.minY ?? homeTop, homeTop)
        let coverTop = keyboardTop - (accessoriesShown ? accessoryStack.frame.height : 0)
        let newTop: CGFloat? = coverTop < homeTop - 0.5 ? coverTop : nil
        guard newTop != settledCoverTop else { return }
        settledCoverTop = newTop
        view.setNeedsLayout()
        view.layoutIfNeeded()
        resizeNow()
    }

    /// Locks the grid that fits now and tells the host, without the debounce
    /// (a settled change, not a drag).
    private func resizeNow() {
        resizeTask?.cancel()
        guard let client, streamId != nil, let terminalId else { return }
        let fit = terminalView.fittingGrid
        guard fit.cols >= 2, fit.rows >= 2, hostGrid.map({ $0 != fit }) ?? true else { return }
        // A grow moves the cursor down (scrollback comes back): slide into it.
        if let rows = hostGrid?.rows, fit.rows > rows, let cursor = terminalView.cursorRow {
            growCompensation = (cursor.row, cursor.cellHeight)
        }
        lockGrid(fit)
        Task { try? await client.resizeTerminal(terminalId, cols: fit.cols, rows: fit.rows) }
    }

    private func relayoutAccessories(animated: Bool) {
        let changes = {
            self.placeAccessories()
            self.view.layoutIfNeeded()
            self.panToCursor()
        }
        if animated, !UIAccessibility.isReduceMotionEnabled, view.window != nil {
            UIView.animate(springDuration: 0.35, bounce: 0, animations: changes) { [weak self] _ in self?.settle() }
        } else {
            changes()
            settle()
        }
    }

    private var inputFocused: Bool { terminalView.isFirstResponder || composerFocused }

    /// Shows the composer and key bar for the current mode and focus.
    /// Returns true when anything changed.
    @discardableResult
    private func placeAccessories() -> Bool {
        var changed = false
        let showBar = inputFocused && !GhosttyTerminalView.hardwareKeyboardAttached
        let showComposer = model.composerMode
        if keyBar.isHidden == showBar { keyBar.isHidden = !showBar; changed = true }
        if let host = composerHost, host.view.isHidden == showComposer { host.view.isHidden = !showComposer; changed = true }
        return changed
    }

    /// The visible bottom of the terminal: the top of the composer and key
    /// bar when shown, else the keyboard's top (layout must be current).
    private var visibleBottomInView: CGFloat {
        let accessoriesShown = !keyBar.isHidden || !(composerHost?.view.isHidden ?? true)
        return accessoriesShown ? accessoryStack.frame.minY : view.keyboardLayoutGuide.layoutFrame.minY
    }

    /// The keyboard never changes the grid (D8). While the key bar, composer
    /// or keyboard covers the bottom of the grid, the terminal moves up so
    /// its last row sits on their top edge; it never moves so far that the
    /// cursor row leaves the top, and always far enough that the cursor row
    /// stays above them.
    /// After a grow Ghostty brings scrollback rows back and the content jumps
    /// down; start it where it was and let it follow the keyboard down.
    private func applyGrowCompensation() {
        guard let before = growCompensation, let after = terminalView.cursorRow else { return }
        growCompensation = nil
        let delta = CGFloat(after.row - before.row) * before.cellHeight
        guard delta > 0.5, !UIAccessibility.isReduceMotionEnabled else { return }
        compensating = true
        terminalView.transform = CGAffineTransform(translationX: 0, y: -delta)
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.terminalView.transform = .identity
        } completion: { [weak self] _ in
            self?.compensating = false
            self?.panToCursor()
        }
    }

    private func panToCursor() {
        guard !compensating else { return }
        let restingTop = terminalView.center.y - terminalView.bounds.height / 2
        let restingBottom = restingTop + terminalView.bounds.height
        let visibleBottom = min(visibleBottomInView, restingBottom)
        let cursor = terminalView.cursorRect
        let accessoriesShown = !keyBar.isHidden || model.composerMode
        // Measured only while something covers the bottom (it reads rows).
        // Not clamped to the view: right after a settle the view is already
        // shorter while the locally scrolled grid has not been drawn yet.
        let contentBottom = accessoriesShown || keyboardFrame != nil ? (terminalView.contentBottom ?? 0) : 0
        var shift = max(0, restingTop + contentBottom - visibleBottom)
        if cursor.height > 0 {
            let cursorShift = max(0, restingTop + cursor.maxY + Self.cursorMargin - visibleBottom)
            let cursorTopLimit = max(cursorShift, cursor.minY - Self.cursorMargin)
            shift = min(max(shift, cursorShift), cursorTopLimit)
        }
        shift = max(0, shift)
        let transform = CGAffineTransform(translationX: 0, y: -shift)
        if terminalView.transform != transform { terminalView.transform = transform }
        if model.keyboardShift != shift { model.keyboardShift = shift }
        updateDebugValue()
        #if DEBUG
        TerminalTrace.shared.log("pan shift=\(shift) visibleBottom=\(visibleBottom) contentBottom=\(restingTop + contentBottom) cursor=\(cursor) bar=\(!keyBar.isHidden) composer=\(model.composerMode) stack=\(accessoryStack.frame)")
        #endif
    }

    // MARK: Gestures

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        scrollPan = pan
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
        // A tap on the terminal always types straight into it.
        focusInput()
    }

    /// One finger drags vertically: Ghostty scrolls its scrollback on the
    /// primary screen, or sends wheel reports / arrow keys to a TUI on the
    /// alternate screen (see `GhosttyTerminalView.scroll`). Momentum follows
    /// a fling. Works with the keyboard up.
    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.location(in: terminalView)
        switch recognizer.state {
        case .began:
            momentum?.stop()
            scrollPoint = point
            // The slop the recognizer consumed before beginning counts too.
            let dy = recognizer.translation(in: terminalView).y
            recognizer.setTranslation(.zero, in: terminalView)
            terminalView.scroll(byPoints: dy, at: point)
        case .changed:
            scrollPoint = point
            let dy = recognizer.translation(in: terminalView).y
            recognizer.setTranslation(.zero, in: terminalView)
            terminalView.scroll(byPoints: dy, at: point)
        case .ended:
            let velocity = recognizer.velocity(in: terminalView).y
            guard !UIAccessibility.isReduceMotionEnabled, abs(velocity) > 200 else { return }
            let at = point
            let momentum = ScrollMomentum(velocity: velocity) { [weak self] dy in self?.terminalView.scroll(byPoints: dy, at: at) }
            self.momentum = momentum
            momentum.start()
        default:
            break
        }
    }

    /// Vertical drags only (a slow drag begins with zero velocity, so the
    /// translation decides; ties go to scrolling).
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer, pan === scrollPan else { return true }
        let t = pan.translation(in: terminalView)
        let v = pan.velocity(in: terminalView)
        let dx = abs(t.x) > 0.5 || abs(t.y) > 0.5 ? abs(t.x) : abs(v.x)
        let dy = abs(t.x) > 0.5 || abs(t.y) > 0.5 ? abs(t.y) : abs(v.y)
        return dy >= dx
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    /// Other pans outside the terminal (the drawer's horizontal pan) wait
    /// for the scroll pan to fail, so a vertical drag always scrolls.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard recognizer === scrollPan, other is UIPanGestureRecognizer, other.view !== terminalView else { return false }
        return !(other is UIScreenEdgePanGestureRecognizer)
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
