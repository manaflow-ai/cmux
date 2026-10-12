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

        surface.onScrollbar = { [weak self] total, offset, length in
            self?.scrollbarChanged(total: total, offset: offset, length: length)
        }
        surface.onReady = { [weak self] in self?.view.setNeedsLayout() }
        session.onGridChange = { [weak self] _, _ in self?.view.setNeedsLayout() }
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
            bottomInset = max(0, view.bounds.height - host.frame.minY)
        }
        if let size = surface.cellSize { cell = size }
        let tui = session.isTUI
        // Shell: the grid reaches up under the floating top controls (old
        // output shows through the soft edge); TUI: only the clear area.
        let gridTop = tui ? topInset : view.safeAreaInsets.top
        // A shell keeps its grid while the keyboard is up (no SIGWINCH redraw
        // for every keyboard toggle); the scroll view lifts the last rows
        // above the keyboard instead. A TUI must see its whole grid, so it
        // resizes to the space left above the keyboard.
        let keyboard = view.keyboardLayoutGuide.layoutFrame.height
        let reserved = tui ? bottomInset : max(0, bottomInset - keyboard)
        let available = CGSize(
            width: view.bounds.width,
            height: max(cell.height * 5, view.bounds.height - reserved - gridTop)
        )
        if let fit = surface.gridFitting(available) {
            session.fit(cols: fit.cols, rows: fit.rows)
        }
        layoutContent()
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
            surface.frame = CGRect(x: 0, y: top, width: width, height: gridHeight)
            return
        }
        tuiPan?.isEnabled = false
        scrollView.isScrollEnabled = true
        let overflow = scrollback.total > scrollback.length
        // Edge effects only once content actually reaches under the bars.
        scrollView.topEdgeEffect.isHidden = !overflow
        scrollView.bottomEdgeEffect.isHidden = !overflow
        // Nothing to scroll: no rubber band dragging the grid around.
        scrollView.alwaysBounceVertical = overflow
        let rows = max(scrollback.total, session.rows)
        // The grid's bottom sits on the composer; leftover space goes on top.
        let topPad = max(0, bounds.height - bottomInset - gridHeight)
        let contentHeight = topPad + CGFloat(rows) * cell.height
        applyingOffset = true
        scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        scrollView.contentSize = CGSize(width: width, height: contentHeight)
        if pinnedToBottom { scrollView.contentOffset.y = maxOffset }
        applyingOffset = false
        placeSurface()
    }

    private var maxOffset: CGFloat {
        max(0, scrollView.contentSize.height + scrollView.contentInset.bottom - scrollView.bounds.height)
    }

    /// Puts the Ghostty view on the row boundary at or below the visible
    /// top and moves Ghostty's viewport to the matching row.
    private func placeSurface() {
        let bounds = view.bounds
        let topPad = max(0, bounds.height - bottomInset - gridHeight)
        let maxRow = max(0, scrollback.total - max(session.rows, scrollback.length))
        let offset = min(max(scrollView.contentOffset.y, 0), maxOffset)
        let row = min(maxRow, Int((offset / cell.height).rounded(.up)))
        surface.frame = CGRect(x: 0, y: topPad + CGFloat(row) * cell.height, width: bounds.width, height: gridHeight)
        guard row != lastViewportRow else { return }
        lastViewportRow = row
        if row >= maxRow { surface.scrollViewportToBottom() } else { surface.scrollViewport(toRow: row) }
    }

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
        placeSurface()
        onScrollStateChange?(pinnedToBottom)
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
        UIView.performWithoutAnimation { view.setNeedsLayout(); view.layoutIfNeeded() }
    }

    @objc private func terminalTapped() {
        if keyInput.isFirstResponder { return }
        let became = keyInput.becomeFirstResponder()
        AppModel.log.info("terminal tap: becameFirstResponder=\(became, privacy: .public) window=\(self.keyInput.window != nil, privacy: .public)")
        Haptics.soft()
    }

    /// Starts direct typing (the composer's terminal-keyboard button).
    func beginDirectTyping() { keyInput.becomeFirstResponder() }

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
