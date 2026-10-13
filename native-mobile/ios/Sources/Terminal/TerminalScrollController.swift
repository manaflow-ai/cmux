import UIKit

/// Hosts a Ghostty surface inside a real `UIScrollView`, so a shell's
/// scrollback scrolls like any Apple list: pixel-smooth, with momentum,
/// rubber-banding and the iOS 26 scroll edge effects under the navigation
/// bar and the composer.
///
/// How it works: the scroll view's content is as tall as Ghostty's whole
/// buffer (scrollback + screen, in rows). The Ghostty view stays the size of
/// the grid and rides inside the content: on every scroll it is placed at the
/// row boundary at or below the visible top, and Ghostty's own viewport is
/// moved to that row (`scroll_to_row`). The sub-row remainder comes from the
/// view's position, so motion is continuous instead of one row at a time.
///
/// A shell's grid starts at the top of the screen, under the floating glass
/// controls: older output scrolls up beneath them with the soft top edge
/// effect, like a chat transcript. The content inset keeps row 0 below the
/// bar at the top of the scrollback, and a pinned short screen (after
/// `clear`) rests up to the bar's height above the true bottom so its first
/// rows are clear of the bar (`TerminalViewportMath.bottomShift`).
///
/// A TUI (alternate screen) assumes its whole grid is visible, so it gets a
/// fixed grid between the bars, no scrolling and no edge effects; vertical
/// pans become wheel events (mouse tracking) or arrow keys.
@MainActor
final class TerminalScrollController: UIViewController, UIScrollViewDelegate {
    let session: TerminalSession
    private let scrollView = UIScrollView()
    private var surface: GhosttySurfaceView { session.surfaceView }

    /// Composer + keyboard height, measured from the docked composer.
    private var bottomInset: CGFloat = 0
    /// Status bar + navigation bar (the view's safe area top).
    private var topInset: CGFloat { view.safeAreaInsets.top }
    /// The composer, docked to the keyboard; the bottom edge effect follows it.
    private var composer: UIViewController?

    private var scrollback = (total: 0, offset: 0, length: 0)
    private var cell = CGSize(width: 7, height: 15)
    private var pinnedToBottom = true
    private var applyingOffset = false
    private var lastViewportRow = -1
    private var tuiPan: UIPanGestureRecognizer?
    /// Direct typing (tap the terminal); the composer steps aside meanwhile.
    let keyInput = TerminalKeyInputView()
    var onDirectTypingChange: ((Bool) -> Void)?
    private var tuiPanCarry: CGFloat = 0
    /// Blank rows at the bottom of the live screen (shell mode).
    private var blankRows = 0
    /// Points a pinned shell rests above the true bottom (see `bottomShift`).
    private var bottomShift: CGFloat = 0
    private var blankCheckPending = false
    private var debugOverlay: TerminalDebugOverlay?

    init(session: TerminalSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.terminalBackground
        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.indicatorStyle = .white
        scrollView.keyboardDismissMode = .interactive
        scrollView.backgroundColor = .clear
        view.addSubview(scrollView)
        scrollView.addSubview(surface)
        scrollView.topEdgeEffect.style = .soft
        scrollView.bottomEdgeEffect.style = .soft
        setContentScrollView(scrollView, for: .top)
        setContentScrollView(scrollView, for: .bottom)

        view.addSubview(keyInput)
        keyInput.onText = { [weak self] text in self?.session.send(text: text) }
        keyInput.onKeys = { [weak self] keys in self?.session.sendKeys(keys) }
        keyInput.onFocusChange = { [weak self] focused in self?.onDirectTypingChange?(focused) }
        let tap = UITapGestureRecognizer(target: self, action: #selector(terminalTapped))
        tap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(tuiPanned(_:)))
        pan.isEnabled = false
        view.addGestureRecognizer(pan)
        tuiPan = pan

        // Hidden diagnostics: three-finger long press shows the render state.
        let debugPress = UILongPressGestureRecognizer(target: self, action: #selector(debugPressed(_:)))
        debugPress.numberOfTouchesRequired = 3
        debugPress.minimumPressDuration = 0.6
        debugPress.cancelsTouchesInView = false
        view.addGestureRecognizer(debugPress)
        if TerminalDebugOverlay.enabled { showDebugOverlay(true) }

        surface.onScrollbar = { [weak self] total, offset, length in
            self?.scrollbarChanged(total: total, offset: offset, length: length)
        }
        surface.onReady = { [weak self] in self?.view.setNeedsLayout() }
        surface.onOutput = { [weak self] in self?.outputApplied() }
        session.onGridChange = { [weak self] _, _ in
            self?.view.setNeedsLayout()
            self?.outputApplied()
        }
        session.onModeChange = { [weak self] _ in self?.modeChanged() }
    }

    /// Docks the composer to the keyboard layout guide.
    func install(composer: UIViewController) {
        loadViewIfNeeded()
        self.composer = composer
        addChild(composer)
        let host = composer.view!
        host.backgroundColor = .clear
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        composer.didMove(toParent: self)
        let interaction = UIScrollEdgeElementContainerInteraction()
        interaction.scrollView = scrollView
        interaction.edge = .bottom
        host.addInteraction(interaction)
    }

    // MARK: Layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        onWidthChange?(view.bounds.width)
        if let host = composer?.view {
            // The measured composer bar, not the hosting view's frame: the
            // frame lags its content (the keys row grew the SwiftUI content
            // but not the frame) and also holds the jump-to-bottom button,
            // which must not move the content when it appears.
            let belowComposer = max(0, view.bounds.height - host.frame.maxY)
            // The SwiftUI content sits above the host's bottom safe area
            // (home indicator) when the keyboard is down.
            bottomInset = composerMeasured
                ? belowComposer + composerContentHeight + host.safeAreaInsets.bottom
                : belowComposer + host.frame.height
        }
        if let size = surface.cellSize { cell = size }
        let tui = session.isTUI
        // Shell: the grid reaches up under the floating top controls (old
        // output shows through the soft edge); TUI: only the clear area.
        let gridTop = tui ? topInset : 0
        // A shell keeps its grid while the keyboard is up (no SIGWINCH redraw
        // for every keyboard toggle); the scroll view lifts the last rows
        // above the keyboard instead. A TUI must see its whole grid, so it
        // resizes to the space left above the keyboard.
        let keyboard = view.keyboardLayoutGuide.layoutFrame.height
        let reserved = tui ? bottomInset : max(0, bottomInset - keyboard)
        let available = CGSize(
            width: TerminalViewportMath.gridWidth(viewWidth: view.bounds.width),
            height: max(cell.height * 5, view.bounds.height - reserved - gridTop)
        )
        if let fit = surface.gridFitting(available) {
            session.fit(cols: fit.cols, rows: fit.rows)
        }
        layoutContent()
    }

    /// Left edge of the grid (side inset, centered leftover).
    private var gridX: CGFloat {
        TerminalViewportMath.gridOriginX(viewWidth: view.bounds.width, cols: session.cols, cellWidth: cell.width)
    }

    /// The composer's SwiftUI content height (see `bottomInset`).
    private var composerContentHeight: CGFloat = 0
    private var composerMeasured = false

    func composerContentHeightChanged(_ height: CGFloat) {
        guard !composerMeasured || abs(height - composerContentHeight) > 0.5 else { return }
        composerMeasured = true
        composerContentHeight = height
        composer?.view.invalidateIntrinsicContentSize()
        view.setNeedsLayout()
    }

    /// Pixel height of the Mac's grid (falls back to the fitted area).
    private var gridHeight: CGFloat {
        CGFloat(max(session.rows, 1)) * cell.height
    }

    private func layoutContent() {
        let bounds = view.bounds
        let width = bounds.width
        if session.isTUI {
            scrollView.isScrollEnabled = false
            scrollView.topEdgeEffect.isHidden = true
            scrollView.bottomEdgeEffect.isHidden = true
            tuiPan?.isEnabled = true
            scrollView.contentInset = .zero
            scrollView.contentSize = bounds.size
            scrollView.contentOffset = .zero
            // Anchor the grid right above the composer, fully visible.
            let top = max(topInset, bounds.height - bottomInset - gridHeight)
            surface.frame = CGRect(x: gridX, y: top, width: TerminalViewportMath.gridWidth(viewWidth: width), height: gridHeight)
            return
        }
        tuiPan?.isEnabled = false
        scrollView.isScrollEnabled = true
        // The grid always reaches under the bars, so the edge effects stay
        // on (over the black background they show only where text is).
        scrollView.topEdgeEffect.isHidden = false
        scrollView.bottomEdgeEffect.isHidden = false
        // Scrolls (and rubber-bands) only when there is more than fits.
        scrollView.alwaysBounceVertical = false
        let rows = max(scrollback.total, session.rows)
        // The grid's bottom sits on the composer; leftover space goes on top.
        let topPad = TerminalViewportMath.topPad(viewHeight: bounds.height, bottomInset: bottomInset, gridHeight: gridHeight)
        let contentHeight = topPad + CGFloat(rows) * cell.height
        bottomShift = TerminalViewportMath.bottomShift(
            screenTopY: bounds.height - bottomInset - gridHeight, topInset: topInset,
            blankRows: blankRows, cellHeight: cell.height
        )
        applyingOffset = true
        // Top: the oldest row rests right below the bar. Bottom: the
        // composer, less the blank rows a short screen hides under it.
        scrollView.contentInset = UIEdgeInsets(top: max(0, topInset - topPad), left: 0, bottom: bottomInset - bottomShift, right: 0)
        scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        scrollView.contentSize = CGSize(width: width, height: contentHeight)
        if pinnedToBottom { scrollView.contentOffset.y = maxOffset }
        applyingOffset = false
        placeSurface()
    }

    /// Re-reads the blank rows at the bottom of the screen after output
    /// (once per main-actor hop) and re-lays the content when they change
    /// the pinned position.
    private func outputApplied() {
        guard !session.isTUI, !blankCheckPending else { return }
        blankCheckPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.blankCheckPending = false
            guard !self.session.isTUI, self.cell.height > 0 else { return }
            let needed = max(0, self.topInset - (self.view.bounds.height - self.bottomInset - self.gridHeight))
            let limit = Int((needed / self.cell.height).rounded(.up)) + 2
            let blank = self.surface.trailingBlankRows(rows: self.session.rows, cols: self.session.cols, limit: limit)
            guard blank != self.blankRows else { return }
            self.blankRows = blank
            self.layoutContent()
        }
    }

    /// The pinned (bottom) offset. Negative when a short screen with no
    /// scrollback rests below the bar (see `bottomShift`).
    private var maxOffset: CGFloat {
        max(-scrollView.contentInset.top, scrollView.contentSize.height + scrollView.contentInset.bottom - scrollView.bounds.height)
    }

    /// Puts the Ghostty view on the row boundary at or below the visible
    /// top and moves Ghostty's viewport to the matching row.
    private func placeSurface() {
        let bounds = view.bounds
        let topPad = TerminalViewportMath.topPad(viewHeight: bounds.height, bottomInset: bottomInset, gridHeight: gridHeight)
        // Away from the bottom, Ghostty's rows start below the status bar
        // and reach under the composer (see `shellViewportRow`).
        let statusBar = view.window?.windowScene?.statusBarManager?.statusBarFrame.height ?? 0
        let lead = statusBar - scrollAhead
        let (row, maxRow) = TerminalViewportMath.shellViewportRow(
            offset: scrollView.contentOffset.y, cellHeight: cell.height, topPad: topPad, lead: lead,
            visibleBottom: bounds.height - bottomInset,
            totalRows: scrollback.total, gridRows: session.rows, viewportRows: scrollback.length
        )
        let frame = CGRect(x: gridX, y: topPad + CGFloat(row) * cell.height,
                           width: TerminalViewportMath.gridWidth(viewWidth: bounds.width), height: gridHeight)
        let mode = TerminalScrollSync.mode
        if row == lastViewportRow {
            if pendingFrame != nil { pendingFrame = frame } else { surface.frame = frame }
            return
        }
        lastViewportRow = row
        let toBottom = row >= maxRow
        switch mode {
        case .deferredFrame, .deferredBoth:
            // Ghostty presents a new viewport one hop later than this pass;
            // move the view by the row in that same hop, after the draw.
            pendingFrame = frame
            if toBottom { surface.scrollViewportToBottom(now: mode == .deferredFrame) } else { surface.scrollViewport(toRow: row, now: mode == .deferredFrame) }
            Task { @MainActor [weak self] in
                guard let self, let pending = self.pendingFrame else { return }
                self.pendingFrame = nil
                guard !self.session.isTUI else { return }
                self.surface.frame = pending
            }
        case .immediate, .sync:
            surface.frame = frame
            if toBottom { surface.scrollViewportToBottom(now: mode == .sync) } else { surface.scrollViewport(toRow: row, now: mode == .sync) }
        }
    }

    /// A row move waiting for Ghostty's draw (see `TerminalScrollSync`).
    private var pendingFrame: CGRect?
    private var lastScrollOffset: CGFloat = 0
    /// Points the last scroll moved toward older output (see `scrollViewDidScroll`).
    private var scrollAhead: CGFloat = 0

    // MARK: Ghostty scrollbar

    private func scrollbarChanged(total: Int, offset: Int, length: Int) {
        let grew = total != scrollback.total || length != scrollback.length
        scrollback = (total, offset, length)
        guard grew, !session.isTUI else { return }
        layoutContent()
    }

    // MARK: Scrolling

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !applyingOffset, !session.isTUI else { return }
        pinnedToBottom = scrollView.contentOffset.y >= maxOffset - cell.height / 2
        // Moving toward older output, the view's row move lands a hop after
        // the scroll (`TerminalScrollSync`), so rows start that much higher:
        // the lag then shows under the composer instead of under the bar.
        let delta = scrollView.contentOffset.y - lastScrollOffset
        lastScrollOffset = scrollView.contentOffset.y
        scrollAhead = delta < 0 ? min(-delta, 120) : 0
        placeSurface()
        onScrollStateChange?(pinnedToBottom)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { scrollSettled() }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scrollSettled() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { scrollSettled() }

    /// At rest the rows start below the status bar again.
    private func scrollSettled() {
        guard scrollAhead != 0, !session.isTUI else { return }
        scrollAhead = 0
        placeSurface()
    }

    /// Lands on whole rows so text never rests half-cut under a bar.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard !session.isTUI else { return }
        let target = targetContentOffset.pointee.y
        if target >= maxOffset - 1 || target <= 0 { return }
        targetContentOffset.pointee.y = (target / cell.height).rounded() * cell.height
    }

    /// Fires with the view's width (the docked composer sizes to it).
    var onWidthChange: ((CGFloat) -> Void)?

    /// Fires when the view leaves or returns to the bottom (jump button).
    var onScrollStateChange: ((Bool) -> Void)?

    func scrollToBottom(animated: Bool) {
        pinnedToBottom = true
        scrollView.setContentOffset(CGPoint(x: 0, y: maxOffset), animated: animated)
    }

    private func modeChanged() {
        pinnedToBottom = true
        lastViewportRow = -1
        pendingFrame = nil
        UIView.performWithoutAnimation { view.setNeedsLayout(); view.layoutIfNeeded() }
        outputApplied()
    }

    @objc private func terminalTapped() {
        if keyInput.isFirstResponder { return }
        let became = keyInput.becomeFirstResponder()
        AppModel.log.info("terminal tap: becameFirstResponder=\(became, privacy: .public) window=\(self.keyInput.window != nil, privacy: .public)")
        Haptics.soft()
    }

    /// Starts direct typing (the composer's terminal-keyboard button).
    func beginDirectTyping() { keyInput.becomeFirstResponder() }

    // MARK: Debug overlay

    @objc private func debugPressed(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began else { return }
        let show = debugOverlay == nil
        TerminalDebugOverlay.enabled = show
        showDebugOverlay(show)
        if show { surface.redraw() }
        Haptics.soft()
    }

    private func showDebugOverlay(_ show: Bool) {
        guard show else {
            debugOverlay?.removeFromSuperview()
            debugOverlay = nil
            return
        }
        guard debugOverlay == nil else { return }
        let overlay = TerminalDebugOverlay()
        overlay.provider = { [weak self] in self?.diagnosticsLines() ?? [] }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            overlay.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
        ])
        debugOverlay = overlay
    }

    /// Everything the overlay shows: session, surface and placement.
    func diagnosticsLines() -> [String] {
        var lines = session.diagnosticsLines()
        lines += surface.diagnosticsLines()
        let visible = CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size)
        let inView = scrollView.convert(surface.frame, to: view)
        let fraction = TerminalViewportMath.visibleFraction(of: surface.frame, in: visible)
        lines.append(String(format: "placement: in view y %.0f..%.0f visible %.0f%% offset %.0f/%.0f content %.0f", inView.minY, inView.maxY,
                            fraction * 100, scrollView.contentOffset.y, maxOffset, scrollView.contentSize.height))
        lines.append(String(format: "layout: view %.0fx%.0f top %.0f bottom %.0f cell %.2fx%.2f row %d pinned %@ blank %d shift %.0f", view.bounds.width, view.bounds.height,
                            topInset, bottomInset, cell.width, cell.height, lastViewportRow, pinnedToBottom ? "yes" : "no", blankRows, bottomShift))
        return lines
    }

    // MARK: TUI gestures

    @objc private func tuiPanned(_ pan: UIPanGestureRecognizer) {
        let dy = pan.translation(in: view).y
        pan.setTranslation(.zero, in: view)
        tuiPanCarry += dy
        let step = cell.height
        while abs(tuiPanCarry) >= step {
            let up = tuiPanCarry > 0
            tuiPanCarry -= up ? step : -step
            if session.modes.mouseTracking {
                // SGR wheel report at the grid's center.
                let col = max(1, session.cols / 2), row = max(1, session.rows / 2)
                let code = up ? 64 : 65
                session.sendBytes(Data("\u{1B}[<\(code);\(col);\(row)M".utf8))
            } else {
                session.sendKeys([up ? "up" : "down"])
            }
        }
        if pan.state == .ended || pan.state == .cancelled { tuiPanCarry = 0 }
    }
}
