#if os(iOS)
import CnxDesign
import SwiftUI
import UIKit

/// Lays out the terminal screen in UIKit, where keyboard tracking is exact:
///
/// - The bottom stack (key bar + composer) is pinned to `keyboardLayoutGuide`,
///   so it rides the keyboard's own animation and interactive dismissal.
/// - Non-TUI: the Ghostty surface lives inside a `UIScrollView` whose content
///   height is the session's rows times the cell height. The surface is placed
///   at a row boundary in content coordinates and Ghostty's viewport is moved to
///   that row with a synchronous draw; the scroll view supplies the sub-row
///   pixel offset and its physics. Content runs under the toolbar and the
///   composer with the soft scroll edge effect.
/// - TUI (alternate screen): scrolling is off. The surface sits in a clip view
///   whose bottom is constrained to the composer's top and whose top is the
///   toolbar's bottom: the grid keeps its rows, follows the keyboard exactly and
///   is clipped at the top while the keyboard is up. Hard top edge.
///
/// Two chromes share this layout:
///
/// - `.standalone` (`TerminalScreen`): a navigation bar above, the safe area
///   below. The stack rests 8 pt above the home indicator.
/// - `.embedded` (a workspace tab inside CmuxTabsKit): TabsKit owns the
///   status bar and the floating toolbar; the controller is told how much of
///   the page they cover (`setEmbeddedInsets`). The stack then rests where
///   TabsKit puts a tab accessory (8 pt above the toolbar capsule) and rides
///   the keyboard from there. The stack stays in this controller (not in
///   TabsKit's SwiftUI accessory row) so the TUI clip, the scroll insets and
///   the stack are solved by one Auto Layout pass inside the keyboard's own
///   animation: the TUI frame cannot drift from the composer.
@MainActor
final class TerminalViewController: UIViewController, UIScrollViewDelegate {
    let model: TerminalModel
    let chrome: TerminalChrome
    let surface = TerminalSurfaceView(frame: .zero)
    /// Embedded: what TabsKit's status bar area (top) and toolbar (bottom,
    /// up to 8 pt above the capsule) cover.
    private var embeddedInsets = UIEdgeInsets.zero
    /// Stack bottom <= the chrome's resting line (safe area or toolbar).
    private var stackRestingLimit: NSLayoutConstraint!
    private var tuiTop: NSLayoutConstraint!
    /// Embedded: the status bar strip, registered as the top scroll edge container.
    private let topShelf = UIView()
    /// Embedded on iOS 26: the system draws no top scroll edge effect for a
    /// bare container (iOS 27 does), so a gradient fades the scrollback
    /// under the status bar instead.
    private let statusScrim = GradientView()
    private var statusScrimHeight: NSLayoutConstraint!

    private let scrollView = TerminalScrollView()
    private let tuiClip = UIView()
    private let tuiHost = UIView()
    private let bottomStack = UIView()
    private let bottomBacking = UIView()
    /// 24 pt fade above the composer card, shown only while rows are scrolled
    /// under it, so the row the card's edge cuts reads as "more below" (R2-6).
    private let bottomFade = GradientView()
    /// The last frame, held over the surface while a resize's mirror reset
    /// and replay are drawn, so the page never shows a black frame (R2-3).
    private var freezeView: UIView?
    private var freezeBatches = 0
    /// Clips the key bar while its height follows the keyboard; the bar
    /// itself keeps its 44 pt layout pinned to the clip's top.
    private let keyBarClip = UIView()
    private let scrollToBottomButton = UIButton(configuration: .glass())
    private var scrollButtonVisibility = JumpToBottomVisibility()
    private var keyBarHost: UIHostingController<TerminalKeyBar>!
    private var composerHost: UIHostingController<TerminalComposer>!
    private var tuiHeight: NSLayoutConstraint!

    /// Rows of the local grid: the screen plus the largest keyboard, so the
    /// surface covers the old and new visible ranges during a keyboard animation.
    private var surfaceRows = 0
    /// Rows a TUI gets: between the toolbar and the composer, keyboard down.
    private var tuiRows = 0
    private var gridColumns = 0
    private var cell = CGSize.zero
    /// Ghostty's scrollbar: total rows, viewport top row, visible rows.
    private var scrollbar = (total: 0, offset: 0, visible: 0)
    /// The session's document: absolute rows from the first row with text
    /// (never the blank rows above the Mac's screen) to the cursor's row.
    private var document: TerminalDocumentLayout?
    private var documentRows: Int { document?.rowCount ?? 0 }
    /// First absolute row of the document (content y 0).
    private var originRow: Int { document?.originRow ?? 0 }
    private var viewportTop = -1
    /// The viewport top row of the frame on screen.
    private var presentedTop = 0
    private var documentTotal = 0
    private var outputSinceProbe = false
    /// Row signatures of the frame on screen.
    private var presentedRows: [UInt64]?
    #if DEBUG
    var presentLog: [String] = []
    private var presentDebug = ""
    #endif
    /// Viewports requested before the current one (frames for them may still arrive).
    private var recentTops: [Int] = []
    private var follow = TerminalFollowPolicy()
    private var following: Bool {
        get { follow.following }
        set { follow.following = newValue }
    }
    /// Back from the alternate screen: until the user scrolls, Ghostty's
    /// latest viewport report places the surface. Frames on screen then
    /// have no earlier primary-screen frame to be matched against, and the
    /// first report after the switch can still describe the alternate screen.
    private var placesFromReport = false
    private var refreshAfterTUI = false
    private var started = false
    private var fling: FlingAnimator?
    /// When the key bar shows (SPEC M4) and the constraints that apply it.
    private var keyBarRule = KeyBarVisibility()
    private var tuiSizing = TerminalTUISizing()
    private var keyBarHidden: NSLayoutConstraint!
    private var keyBarPinned: NSLayoutConstraint!
    /// A drag that began while following the prompt with the keyboard up:
    /// a downward drag dismisses the keyboard and the content stays pinned
    /// to the composer, row for row (SPEC M6).
    private var dragPin = KeyboardDragPin()
    private var dragPinsToComposer: Bool { dragPin.pinning }
    private var pinningDrag = false

    init(model: TerminalModel, chrome: TerminalChrome = .standalone) {
        self.model = model
        self.chrome = chrome
        super.init(nibName: nil, bundle: nil)
        model.controller = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        outputLink?.invalidate()
        if outputPaused { model.session.setOutputPaused(false) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = CnxGhosttyApp.background
        // The terminal theme is dark: chrome, glass and the keyboard follow it.
        overrideUserInterfaceStyle = .dark
        view.clipsToBounds = true

        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        scrollView.indicatorStyle = .white
        scrollView.backgroundColor = .clear
        scrollView.topEdgeEffect.style = .soft
        scrollView.bottomEdgeEffect.style = .soft
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(surface)

        tuiClip.clipsToBounds = true
        tuiClip.isHidden = true
        tuiClip.translatesAutoresizingMaskIntoConstraints = false
        tuiHost.translatesAutoresizingMaskIntoConstraints = false
        tuiClip.addSubview(tuiHost)
        view.addSubview(tuiClip)

        let keyBar = UIHostingController(rootView: TerminalKeyBar(model: model))
        let composer = UIHostingController(rootView: TerminalComposer(model: model))
        keyBar.safeAreaRegions = []
        composer.safeAreaRegions = []
        // The terminal is dark in both appearances; so are its key bar and
        // composer (in light mode inside a workspace they drew light glass
        // over the black grid).
        keyBar.overrideUserInterfaceStyle = .dark
        composer.overrideUserInterfaceStyle = .dark
        composer.sizingOptions = [.intrinsicContentSize]
        bottomStack.addSubview(keyBarClip)
        for host in [keyBar as UIViewController, composer] {
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            addChild(host)
            (host === keyBar ? keyBarClip : bottomStack).addSubview(host.view)
            host.didMove(toParent: self)
        }
        keyBarHost = keyBar
        composerHost = composer
        keyBarClip.clipsToBounds = true
        keyBarClip.translatesAutoresizingMaskIntoConstraints = false
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        // The terminal background under the whole bottom chrome, from the
        // composer card's top to the page's bottom: rows scrolled under it are
        // not legible between and below the toolbar pills or at the
        // composer's corners (R1-2). Above the card the soft edge fades.
        bottomBacking.backgroundColor = CnxGhosttyApp.background
        bottomBacking.isUserInteractionEnabled = false
        bottomBacking.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBacking)
        let base = CnxGhosttyApp.background
        bottomFade.gradient.colors = [base.withAlphaComponent(0).cgColor, base.cgColor]
        bottomFade.isUserInteractionEnabled = false
        bottomFade.alpha = 0
        bottomFade.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomFade)
        view.addSubview(bottomStack)
        // The bottom soft edge follows the composer like a system toolbar.
        let edge = UIScrollEdgeElementContainerInteraction()
        edge.scrollView = scrollView
        edge.edge = .bottom
        bottomStack.addInteraction(edge)

        scrollToBottomButton.configuration?.image = UIImage(systemName: "arrow.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        scrollToBottomButton.configuration?.cornerStyle = .capsule
        scrollToBottomButton.tintColor = .label
        scrollToBottomButton.accessibilityLabel = "Scroll to bottom"
        scrollToBottomButton.alpha = 0
        scrollToBottomButton.translatesAutoresizingMaskIntoConstraints = false
        scrollToBottomButton.addAction(UIAction { [weak self] _ in self?.scrollToBottom(animated: true) }, for: .primaryActionTriggered)
        view.addSubview(scrollToBottomButton)

        // Everything below derives from the keyboard layout guide alone, so
        // the keyboard's own animated layout pass moves and resizes the whole
        // stack on the keyboard's curve and timing. No constraint is changed
        // from a keyboard notification (that would commit on another timeline).
        //
        // guide.top is the keyboard's top, or the view's bottom when hidden.
        // Stack bottom = min(guide.top, safe area bottom) - 8.
        // Key bar height = min(44, keyboard height); gap above it = min(8, key bar height).
        let spacer = UILayoutGuide()
        bottomStack.addLayoutGuide(spacer)
        func prioritized(_ constraint: NSLayoutConstraint, _ priority: UILayoutPriority) -> NSLayoutConstraint {
            constraint.priority = priority
            return constraint
        }
        tuiHeight = tuiHost.heightAnchor.constraint(equalToConstant: 0)
        switch chrome {
        case .standalone:
            stackRestingLimit = bottomStack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor)
            tuiTop = tuiClip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        case .embedded:
            stackRestingLimit = bottomStack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)
            tuiTop = tuiClip.topAnchor.constraint(equalTo: view.topAnchor)
            topShelf.isUserInteractionEnabled = false
            topShelf.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(topShelf)
            let topEdge = UIScrollEdgeElementContainerInteraction()
            topEdge.scrollView = scrollView
            topEdge.edge = .top
            topShelf.addInteraction(topEdge)
            if #unavailable(iOS 27) {
                statusScrim.isUserInteractionEnabled = false
                statusScrim.translatesAutoresizingMaskIntoConstraints = false
                let base = CnxGhosttyApp.background
                // A top bar under the status bar: solid terminal background
                // to the status bar's bottom, then a short fade. (A 92 %
                // gradient left scrollback legible under the clock; on iOS 26
                // the page read as having no top bar.)
                statusScrim.gradient.colors = [base.cgColor, base.cgColor, base.withAlphaComponent(0).cgColor]
                statusScrim.gradient.locations = [0, 0.75, 1]
                statusScrim.layer.zPosition = 1
                view.addSubview(statusScrim)
            }
        }
        let guide = view.keyboardLayoutGuide
        // The stack rides the keyboard only while the keyboard is docked at
        // the bottom. With a hardware keyboard the guide can report a 0-wide,
        // 44 pt frame near the top (172 pt on iPhone 17 Pro): pinned to it,
        // the composer and key bar jumped to the top of the page and the
        // terminal went blank. Away from the bottom the stack rests at the
        // chrome's line instead and the key bar folds away.
        guide.followsUndockedKeyboard = true
        guide.usesBottomSafeArea = false
        // The key bar's height: 0 without focus; with focus, 44 pt clipped to
        // the soft keyboard's height (so it folds with the keyboard), or 44 pt
        // pinned when a hardware keyboard leaves no soft keyboard (SPEC M4).
        keyBarHidden = keyBarClip.heightAnchor.constraint(equalToConstant: 0)
        keyBarPinned = prioritized(keyBarClip.heightAnchor.constraint(equalToConstant: 44), UILayoutPriority(950))
        guide.setConstraints([
            bottomStack.bottomAnchor.constraint(lessThanOrEqualTo: guide.topAnchor),
            prioritized(bottomStack.bottomAnchor.constraint(equalTo: guide.topAnchor), .defaultHigh),
            prioritized(keyBarClip.heightAnchor.constraint(lessThanOrEqualTo: guide.heightAnchor), UILayoutPriority(900)),
        ], activeWhenNearEdge: .bottom)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            bottomBacking.topAnchor.constraint(equalTo: bottomStack.topAnchor),
            bottomFade.bottomAnchor.constraint(equalTo: bottomStack.topAnchor),
            bottomFade.heightAnchor.constraint(equalToConstant: 24),
            bottomFade.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomFade.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBacking.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBacking.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBacking.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stackRestingLimit,
            // Rest on the chrome's line when nothing pins the stack higher.
            prioritized(bottomStack.bottomAnchor.constraint(equalTo: view.bottomAnchor), .defaultLow),
            composer.view.topAnchor.constraint(equalTo: bottomStack.topAnchor),
            composer.view.leadingAnchor.constraint(equalTo: bottomStack.leadingAnchor),
            composer.view.trailingAnchor.constraint(equalTo: bottomStack.trailingAnchor),
            composer.view.bottomAnchor.constraint(equalTo: spacer.topAnchor),
            spacer.bottomAnchor.constraint(equalTo: keyBarClip.topAnchor),
            spacer.heightAnchor.constraint(lessThanOrEqualToConstant: 8),
            spacer.heightAnchor.constraint(lessThanOrEqualTo: keyBarClip.heightAnchor),
            prioritized(spacer.heightAnchor.constraint(equalToConstant: 8), .defaultHigh - 2),
            keyBarClip.leadingAnchor.constraint(equalTo: bottomStack.leadingAnchor),
            keyBarClip.trailingAnchor.constraint(equalTo: bottomStack.trailingAnchor),
            keyBarClip.bottomAnchor.constraint(equalTo: bottomStack.bottomAnchor, constant: -8),
            keyBar.view.topAnchor.constraint(equalTo: keyBarClip.topAnchor),
            keyBar.view.leadingAnchor.constraint(equalTo: keyBarClip.leadingAnchor),
            keyBar.view.trailingAnchor.constraint(equalTo: keyBarClip.trailingAnchor),
            keyBar.view.heightAnchor.constraint(equalToConstant: 44),
            keyBarClip.heightAnchor.constraint(lessThanOrEqualToConstant: 44),
            keyBarClip.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            prioritized(keyBarClip.heightAnchor.constraint(equalToConstant: 44), .defaultHigh - 1),
            keyBarHidden,

            tuiTop,
            tuiClip.bottomAnchor.constraint(equalTo: bottomStack.topAnchor),
            tuiClip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tuiClip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tuiHost.bottomAnchor.constraint(equalTo: tuiClip.bottomAnchor),
            tuiHost.leadingAnchor.constraint(equalTo: tuiClip.leadingAnchor, constant: Self.sidePadding),
            tuiHost.trailingAnchor.constraint(equalTo: tuiClip.trailingAnchor, constant: -Self.sidePadding),
            tuiHeight,

            scrollToBottomButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scrollToBottomButton.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -10),
            scrollToBottomButton.widthAnchor.constraint(equalToConstant: 40),
            scrollToBottomButton.heightAnchor.constraint(equalToConstant: 40),
        ])
        if chrome == .embedded {
            NSLayoutConstraint.activate([
                topShelf.topAnchor.constraint(equalTo: view.topAnchor),
                topShelf.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                topShelf.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                topShelf.bottomAnchor.constraint(equalTo: tuiClip.topAnchor),
            ])
            if statusScrim.superview != nil {
                statusScrimHeight = statusScrim.heightAnchor.constraint(equalToConstant: 0)
                NSLayoutConstraint.activate([
                    statusScrim.topAnchor.constraint(equalTo: view.topAnchor),
                    statusScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    statusScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    statusScrimHeight,
                ])
            }
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(terminalTapped))
        scrollView.addGestureRecognizer(tap)
        let tuiTap = UITapGestureRecognizer(target: self, action: #selector(terminalTapped))
        tuiClip.addGestureRecognizer(tuiTap)

        surface.onInput = { [weak self] data in self?.model.session.send(data) }
        // Every input path (keyboard, key bar, composer, paste) goes through
        // the surface's `perform`: typing brings the prompt into view, like Terminal.
        surface.onUserInput = { [weak self] in self?.revealCursorForInput() }
        surface.onEvent = { [weak self] event in self?.surfaceEvent(event) }
        surface.onPresent = { [weak self] in self?.surfacePresented() }
        surface.onFocusChange = { [weak self] focused in
            guard let self else { return }
            self.model.surfaceFocused = focused
            self.inputFocusChanged()
            // Direct typing stays the keyboard target in TUI mode after the keyboard hides.
            self.model.directTyping = focused || self.model.isTUI
        }
        surface.onStickyChange = { [weak self] sticky in self?.model.sticky = sticky }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardDidChange), name: UIResponder.keyboardDidShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardDidHide), name: UIResponder.keyboardDidHideNotification, object: nil)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        registerEdgeEffectScrollView()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        registerEdgeEffectScrollView()
    }

    /// The navigation bar reads its scroll edge effect from the top view
    /// controller's content scroll view; SwiftUI's hosting controller is that
    /// controller, so it is told about this scroll view.
    private func registerEdgeEffectScrollView() {
        // Embedded: TabsKit's page is not a navigation controller's content;
        // the edge containers above are registered on the scroll view directly.
        guard chrome == .standalone else { return }
        var candidate: UIViewController? = self
        while let current = candidate {
            current.setContentScrollView(scrollView, for: .top)
            current.setContentScrollView(scrollView, for: .bottom)
            if current.parent is UINavigationController { break }
            candidate = current.parent
        }
    }

    /// Embedded: the chrome over the page changed (rotation, first layout).
    func setEmbeddedInsets(_ insets: UIEdgeInsets) {
        guard chrome == .embedded, insets != embeddedInsets else { return }
        embeddedInsets = insets
        tuiTop.constant = insets.top
        // Solid under the status bar, then an 18 pt fade that ends at the top
        // inset: row 0 at rest is at full brightness, and only rows scrolled
        // up under the status bar fade (R1-5).
        statusScrimHeight?.constant = insets.top
        if insets.top > 18 { statusScrim.gradient.locations = [0, NSNumber(value: Double((insets.top - 18) / insets.top)), 1] }
        // The composer rests 8 pt above the toolbar capsule, like a tab
        // accessory; the 8 pt below the (hidden) key bar are inside the stack.
        stackRestingLimit.constant = -(insets.bottom - 8)
        view.setNeedsLayout()
    }

    /// Top of the content area (under the navigation bar or the status bar).
    private var chromeTop: CGFloat {
        chrome == .embedded ? embeddedInsets.top : view.safeAreaInsets.top
    }

    /// The composer stack's top with the keyboard down (the key bar folded).
    private var restingStackTop: CGFloat {
        let composerHeight = composerHost.view.bounds.height > 0 ? composerHost.view.bounds.height : 64
        return restingComposerBottom - composerHeight
    }

    /// The composer's bottom with the keyboard down.
    private var restingComposerBottom: CGFloat {
        switch chrome {
        case .standalone: view.bounds.height - view.safeAreaInsets.bottom - 8
        case .embedded: view.bounds.height - embeddedInsets.bottom
        }
    }

    /// A still of the page for the tab grid (the render server's copy of
    /// what is on screen, so the Metal surface is included). Cheap: no
    /// second Ghostty surface; taken when the grid opens or the page leaves.
    func snapshot() -> UIImage? {
        guard view.window != nil, view.bounds.width > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
    }

    // MARK: Files and links (embedded)

    private weak var artifactsHost: UIViewController?

    func presentArtifacts() {
        guard artifactsHost == nil, presentedViewController == nil else { return }
        let model = model
        let host = UIHostingController(rootView: ArtifactsSheet(model: model).onDisappear { model.showArtifacts = false })
        host.overrideUserInterfaceStyle = .unspecified
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        artifactsHost = host
        present(host, animated: true)
    }

    func dismissArtifacts() {
        guard let host = artifactsHost, host.presentingViewController != nil, !host.isBeingDismissed else { return }
        host.dismiss(animated: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if chrome == .embedded, let image = snapshot() { model.snapshot = image }
    }

    /// The terminal or the composer gained or lost focus.
    func inputFocusChanged() {
        keyBarRule.inputFocused = model.inputFocused
        applyKeyBarMode()
    }

    private func applyKeyBarMode() {
        guard keyBarHidden != nil else { return }
        let mode = keyBarRule.mode
        keyBarHidden.isActive = mode == .hidden
        keyBarPinned.isActive = mode == .pinned
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutTerminal()
        if !started, surface.surface != nil, cell.height > 0 {
            started = true
            model.session.start { [weak self] event in self?.sessionEvent(event) }
        }
    }

    #if DEBUG
    /// DEBUG diagnostics for the demo timeline.
    var debugState: String {
        let grid = surface.grid
        return "sb=\(scrollbar.total)/\(scrollbar.offset)/\(scrollbar.visible) doc=\(originRow)+\(documentRows) top=\(viewportTop) rows=\(surfaceRows) tui=\(tuiRows) grid=\(grid.columns)x\(grid.rows) cell=\(cell) off=\(Int(scrollView.contentOffset.y)) size=\(Int(scrollView.contentSize.height)) inset=\(Int(scrollView.contentInset.top)),\(Int(scrollView.contentInset.bottom)) follow=\(following) cursor=\(surface.cursorViewportRow.map(String.init) ?? "-") draws=\(surface.draws) presents=\(surface.presents) presented=\(presentedTop) pacing(frames/hitches/longestMs/stepMs)=\(FlingAnimator.pacing.frames)/\(FlingAnimator.pacing.hitches)/\(String(format: "%.1f", FlingAnimator.pacing.longestMs))/\(String(format: "%.2f", FlingAnimator.pacing.stepMs)) kbguide=\(Int(view.keyboardLayoutGuide.layoutFrame.minY)) stack=\(Int(bottomStack.frame.minY))-\(Int(bottomStack.frame.maxY)) keybar=\(Int(keyBarClip.frame.minY))-\(Int(keyBarClip.frame.maxY)) view=\(Int(view.bounds.height)) safe=\(Int(view.safeAreaInsets.top)),\(Int(view.safeAreaInsets.bottom))"
    }
    #endif

    // MARK: Session

    /// Output waiting for the next display frame (see `pumpOutput`).
    private var output = TerminalOutputQueue()
    /// Runs while output is waiting; stopped when the queue is drained.
    private var outputLink: CADisplayLink?
    /// A batch is with Ghostty; the next waits for its completion.
    private var feedInFlight = false
    /// The next feed outside the display link waits until this time: the
    /// end of the display frame of the last feed.
    private var nextFeedAllowed: CFTimeInterval = 0
    /// The session was asked to stop delivering output (the queue is over its high water).
    private var outputPaused = false
    /// The row shift's state; used only on the surface's output queue, in feed order.
    private let rowShift = RowShiftBox()

    private func sessionEvent(_ event: TerminalSessionEvent) {
        switch event {
        case .output(let data):
            if data == Self.mirrorReset { freezeLastFrame() }
            // Per chunk: queue the bytes and nothing else. Parsing, the row
            // shift and the artifact scan happen once per display frame.
            model.ingest(event)
            output.append(data)
            if !outputPaused, output.isOverHighWater {
                outputPaused = true
                model.session.setOutputPaused(true)
            }
            scheduleOutput()
        case .alternateScreen(let on):
            // In order with the bytes: applied once the bytes before it were parsed.
            output.append(alternateScreen: on)
            scheduleOutput()
        default:
            model.ingest(event)
        }
    }

    /// Feeds at once when nothing was fed in this display frame (an echo is
    /// not held back to the next frame); otherwise the display link feeds at
    /// the start of the next frame. Either way, at most one batch per frame.
    private func scheduleOutput() {
        if !feedInFlight, CACurrentMediaTime() >= nextFeedAllowed {
            pumpOutput()
        }
        guard outputLink == nil, !output.isEmpty || feedInFlight else { return }
        let link = CADisplayLink(target: DisplayLinkProxy { [weak self] in
            // A new frame: one more batch may go.
            self?.nextFeedAllowed = 0
            self?.pumpOutput()
        }, selector: #selector(DisplayLinkProxy.step))
        link.add(to: .main, forMode: .common)
        outputLink = link
    }

    private var frameInterval: CFTimeInterval {
        let fps = view.window?.screen.maximumFramesPerSecond ?? 60
        return 1 / Double(max(30, fps))
    }

    /// One display frame: hands Ghostty the next batch (at most
    /// `TerminalOutputQueue.frameBudget` bytes) when the previous one is
    /// parsed, applying alternate screen switches in order on the way.
    private func pumpOutput() {
        while !feedInFlight, let step = output.next() {
            switch step {
            case .alternateScreen(let on):
                model.ingest(.alternateScreen(on))
                applyMode(tui: on)
            case .bytes(let data):
                feedInFlight = true
                nextFeedAllowed = outputLink?.targetTimestamp ?? CACurrentMediaTime() + frameInterval
                model.scanOutput(data)
                let transform: (@Sendable (Data) -> Data)?
                if let remote = model.session.remoteRows {
                    let offset = max(0, surface.grid.rows - remote)
                    let box = rowShift
                    transform = { box.filter($0, offset: offset, remoteRows: remote) }
                } else {
                    transform = nil
                }
                let raw = data.count
                surface.feed(data, transform: transform) { [weak self] in self?.outputProcessed(raw) }
            }
        }
        if outputPaused, output.isUnderLowWater {
            outputPaused = false
            model.session.setOutputPaused(false)
        }
        if output.isEmpty, !feedInFlight { stopOutputLink() }
    }

    private func stopOutputLink() {
        outputLink?.invalidate()
        outputLink = nil
    }

    /// Ghostty parsed a batch (`raw` session bytes).
    private func outputProcessed(_ raw: Int) {
        feedInFlight = false
        if freezeView != nil, raw > Self.mirrorReset.count, replayHasContent() {
            // The replay is parsed and draws something: drop the held frame on
            // the next present (or after one more batch, whichever comes first).
            freezeBatches += 1
            if freezeBatches >= 2 { unfreeze() }
        }
        if raw > Self.mirrorReset.count { model.liveOutputDrawn() }
        #if DEBUG
        TerminalBenchProbe.shared?.outputProcessed(raw)
        #endif
        outputSinceProbe = true
        #if DEBUG
        if CommandLine.arguments.contains("-CnxTermLog") { NSLog("cnxterm processed %@", debugState) }
        #endif
        if refreshAfterTUI, !model.isTUI {
            // The switch back from the alternate screen is processed by
            // now: ask for the primary screen's viewport and its report.
            refreshAfterTUI = false
            surface.scrollToActiveArea()
        }
        if scrollbar.total == 0 { scrollbar = (surface.grid.rows, 0, surface.grid.rows) }
        updateDocument()
        if output.isEmpty { stopOutputLink() }
    }

    private func surfaceEvent(_ event: TerminalSurfaceEvent) {
        switch event {
        case .scrollbar(let total, let offset, let visible):
            scrollbar = (total, offset, visible)
            updateDocument()
            #if DEBUG
            if CommandLine.arguments.contains("-CnxTermLog") { NSLog("cnxterm scrollbar %@", debugState) }
            #endif
            if placesFromReport, !model.isTUI { place(atRow: offset) }
            // Whatever moved Ghostty's viewport (a request, a cursor probe
            // restoring an older row), it must cover the visible rows; a
            // report that leaves them uncovered asks again. Without this, a
            // reattach replay left the probe's restore at row 0 while the
            // screen showed the bottom: a blank page.
            updateViewport(visibleMinY: scrollView.contentOffset.y)
        case .cellSize:
            view.setNeedsLayout()
        case .bell:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    // MARK: Held frame (R2-3)

    /// `ESC c`: the session resets the mirror before a replay (a resize, a reattach).
    static let mirrorReset = Data("\u{1B}c".utf8)

    /// Holds what is on screen until the replay after a reset is drawn. Only
    /// once the page has drawn something (the first attach has nothing to hold).
    private func freezeLastFrame() {
        guard freezeView == nil, view.window != nil, document != nil || model.isTUI,
              let snapshot = view.snapshotView(afterScreenUpdates: false) else { return }
        snapshot.frame = view.bounds
        snapshot.isUserInteractionEnabled = false
        view.insertSubview(snapshot, belowSubview: bottomBacking)
        freezeView = snapshot
        freezeBatches = 0
        // A TUI's replay at a new size can be an empty alternate screen until
        // the program repaints (R3-2); the held frame waits for that, but
        // never longer than this.
        let held = ObjectIdentifier(snapshot)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.freezeCap) { [weak self] in
            guard let self, let view = self.freezeView, ObjectIdentifier(view) == held else { return }
            self.unfreeze()
        }
    }

    /// The longest a held frame stays up after a reset.
    static let freezeCap: TimeInterval = 0.5

    /// Whether the screen now has something to show: on the alternate screen,
    /// a TUI that has repainted (any text); the primary screen's replay
    /// always counts.
    private func replayHasContent() -> Bool {
        guard model.isTUI else { return true }
        let rows = surface.grid.rows
        guard rows > 0, let blank = surface.leadingBlankRows(through: rows - 1) else { return true }
        return blank < rows
    }

    private func unfreeze() {
        freezeView?.removeFromSuperview()
        freezeView = nil
        freezeBatches = 0
    }

    /// Shows the bottom fade while rows are scrolled under the composer.
    private func updateBottomFade() {
        let under = !model.isTUI && scrollView.contentOffset.y < maxOffsetY - 1
        let alpha: CGFloat = under ? 1 : 0
        if bottomFade.alpha != alpha { bottomFade.alpha = alpha }
    }

    // MARK: Layout

    private func layoutTerminal() {
        let bounds = view.bounds
        guard bounds.width > 0 else { return }
        #if DEBUG
        if CommandLine.arguments.contains("-CnxTermLog") {
            NSLog("cnxterm layout kb=%@ stack=%@ view=%@ window=%@", NSCoder.string(for: view.keyboardLayoutGuide.layoutFrame), NSCoder.string(for: bottomStack.frame), NSCoder.string(for: view.frame), NSCoder.string(for: view.convert(view.bounds, to: nil)))
        }
        #endif
        let measured = surface.cellSize
        if measured.height > 0 { cell = measured }
        let cellHeight = cell.height > 0 ? cell.height : 16
        // The screen plus a margin above and below the visible rows, within
        // the largest texture Metal allows (8192 px; a bigger surface's frames
        // are discarded by Ghostty's layer).
        let scale = view.window?.screen.scale ?? 3
        let maxRows = Int(floor(8192 / (cellHeight * scale)))
        let rows = min(Int(ceil(bounds.height / cellHeight)) + 2 * Self.marginRows, maxRows)
        if rows != surfaceRows {
            surfaceRows = rows
            viewportTop = -1
        }
        let surfaceSize = CGSize(width: bounds.width - 2 * Self.sidePadding, height: CGFloat(rows) * cellHeight)
        if surface.bounds.size != surfaceSize {
            UIView.performWithoutAnimation {
                surface.frame.size = surfaceSize
                surface.layoutIfNeeded()
            }
        }

        // TUI rows: toolbar bottom to the composer's top where it settled
        // (keyboard down, or up once the keyboard finished showing: R1-1).
        let newTUIRows = tuiSizing.rows(restingStackTop: restingStackTop, chromeTop: chromeTop, cellHeight: cellHeight)
        let columns = cell.width > 0 ? max(1, Int(floor((bounds.width - 2 * Self.sidePadding) / cell.width))) : 0
        if newTUIRows != tuiRows || columns != gridColumns {
            tuiRows = newTUIRows
            gridColumns = columns
            tuiHeight.constant = CGFloat(tuiRows) * cellHeight
            if columns > 0 { model.session.resize(columns: columns, rows: tuiRows) }
        }

        // Insets: content starts under the toolbar and ends above the composer.
        let top = chromeTop
        // The last row rests 8 pt above the composer card (SPEC M3).
        let bottom = max(0, bounds.height - bottomStack.frame.minY) + Self.composerGap
        let insets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        if scrollView.contentInset != insets {
            let previousOffset = scrollView.contentOffset.y
            scrollView.contentInset = insets
            scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
            if following, !scrollView.isTracking || dragPinsToComposer, !model.isTUI {
                // Rides the keyboard: the offset changes inside the keyboard's
                // animation; the surface covers both ends of it.
                let target = maxOffsetY
                if abs(target - previousOffset) > 0.5 {
                    updateViewport(visibleMinY: min(previousOffset, target))
                    scrollView.contentOffset.y = target
                    return
                }
            }
        }
        updateViewport(visibleMinY: scrollView.contentOffset.y)
    }

    private var maxOffsetY: CGFloat {
        TerminalDocumentLayout.bottomOffset(contentHeight: scrollView.contentSize.height, viewportHeight: scrollView.bounds.height,
                                            topInset: scrollView.contentInset.top, bottomInset: scrollView.contentInset.bottom)
    }

    /// Recomputes the document height from Ghostty's scrollbar and the cursor.
    private func updateDocument() {
        guard !model.isTUI, cell.height > 0 else { return }
        // The document only grows with output (the total changes); probing the
        // cursor moves Ghostty's viewport for a moment, so it is not repeated
        // for reports that only moved the viewport (scrolling).
        guard scrollbar.total != documentTotal || document == nil || outputSinceProbe else { return }
        // The scrollback shrank (`clear`, ESC [3J): the rows the user was
        // reading are gone. Follow the prompt again, like Terminal.
        follow.scrollbackChanged(from: documentTotal, to: scrollbar.total, screenRows: surface.grid.rows)
        let previousTotal = documentTotal
        documentTotal = scrollbar.total
        outputSinceProbe = false
        let cursor = surface.cursorAbsoluteRow(totalRows: scrollbar.total)
        var blank: Int? = document?.originRow
        if model.session.remoteRows == nil {
            // A local session writes from row 0: no mirror rows above it.
            blank = 0
        } else if placesFromReport || TerminalDocumentLayout.needsOriginScan(previous: document, previousTotal: previousTotal,
                                                                             totalRows: scrollbar.total, screenRows: surface.grid.rows) {
            // Back from a TUI (until the user scrolls) the primary screen is
            // being redrawn and resized: read the top again on every update,
            // so earlier output is never left above an origin read too early (R2-1).
            let last = min(scrollbar.total - 1, cursor ?? (scrollbar.total - 1))
            blank = surface.leadingBlankRows(through: max(0, last)) ?? blank
        }
        let next = TerminalDocumentLayout.make(totalRows: scrollbar.total, cursorRow: cursor, leadingBlankRows: blank)
        guard next != document else { return }
        let shift = CGFloat(next.originRow - originRow) * cell.height
        let hadDocument = document != nil
        document = next
        scrollView.contentSize = CGSize(width: view.bounds.width, height: next.contentHeight(cellHeight: cell.height))
        if hadDocument, shift != 0 {
            // The top moved (cleared, or found): keep the same rows on
            // screen and the frame on screen where its rows belong.
            place(atRow: presentedTop)
            if !following {
                scrollView.contentOffset.y = min(max(-scrollView.contentInset.top, scrollView.contentOffset.y - shift), maxOffsetY)
            }
        }
        // Pinned while following; a document that ends above the place on
        // screen (nothing left there but blank rows) follows again.
        if let target = follow.documentResized(offsetY: scrollView.contentOffset.y, maxOffsetY: maxOffsetY,
                                               userIsScrolling: scrollView.isTracking || scrollView.isDecelerating) {
            scrollView.contentOffset.y = target
        }
        updateViewport(visibleMinY: scrollView.contentOffset.y)
    }

    /// Input is about to go to the program: on the primary screen, follow
    /// the output again and jump to the prompt if the user scrolled away.
    /// (Output alone never moves someone who scrolled up; typing does.)
    private func revealCursorForInput() {
        guard cell.height > 0, let target = follow.input(isTUI: model.isTUI, offsetY: scrollView.contentOffset.y, maxOffsetY: maxOffsetY) else { return }
        fling?.stop()
        fling = nil
        scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        updateViewport(visibleMinY: scrollView.contentOffset.y)
    }

    /// Rows kept rendered above and below the visible rows. A frame for a new
    /// viewport takes a few display frames to arrive; a fling at 9000 pt/s
    /// moves about 5 rows per 120 Hz frame, so the previous frame must still
    /// cover the screen for several of them.
    static let marginRows = 48

    /// Leading and trailing padding of the grid inside the page (SPEC M5):
    /// the first and last columns clear the display's corner radius. The
    /// background still fills the page edge to edge.
    static let sidePadding: CGFloat = 6
    /// Space between the document's last row and the composer card.
    static let composerGap: CGFloat = 8

    /// Asks Ghostty for a viewport that covers the visible rows with margin on
    /// both sides, once the visible rows come within half a margin of the
    /// requested viewport's edges. The surface itself moves only when a frame
    /// for the new viewport is presented (`surfacePresented`).
    private func updateViewport(visibleMinY: CGFloat) {
        guard !model.isTUI, cell.height > 0, surfaceRows > 0 else { return }
        let maxTop = max(0, scrollbar.total - surfaceRows)
        let visibleTop = originRow + Int(floor(max(0, visibleMinY) / cell.height))
        let visibleBottom = originRow + Int(ceil((max(0, visibleMinY) + view.bounds.height) / cell.height))
        let margin = (surfaceRows - Int(ceil(view.bounds.height / cell.height))) / 2
        // Ghostty's viewport as last reported; it may follow the output on its
        // own (a request inside the active area keeps it at the bottom).
        let current = scrollbar.total > 0 ? scrollbar.offset : viewportTop
        let needsNew = current < 0
            || (visibleTop < current + margin / 2 && current > 0)
            || (visibleBottom > current + surfaceRows - margin / 2 && current < maxTop)
            || current > maxTop
        guard needsNew else { return }
        let top = min(max(0, visibleTop - margin), maxTop)
        guard top != current else { return }
        // Ghostty reports a viewport other than the one last asked for (a
        // cursor probe or a reset moved it): ask again rather than wait for a
        // report that will not come, which left the visible rows blank.
        if top != viewportTop {
            recentTops.append(viewportTop)
            if recentTops.count > 6 { recentTops.removeFirst() }
            viewportTop = top
        } else if scrollbar.total == 0 {
            return
        }
        #if DEBUG
        if CommandLine.arguments.contains("-CnxTermLog") { NSLog("cnxterm request %d (current %d visibleTop %d)", top, current, visibleTop) }
        #endif
        surface.scroll(toRow: top)
    }

    /// A frame was presented: put the surface where its rows belong, in the
    /// same transaction. Ghostty renders on its own thread and its viewport
    /// reports (scrollbar) and frames reach the main thread in either order,
    /// and a frame rendered before a request can arrive after it. So the
    /// frame's viewport is read from its pixels: its cell rows are matched
    /// against the previous frame's rows for the candidate shifts (none, the
    /// last report, the last request), and the best match places it.
    private func surfacePresented() {
        #if DEBUG
        TerminalBenchProbe.shared?.presented()
        #endif
        if freezeView != nil, freezeBatches > 0 { unfreeze() }
        guard !model.isTUI, cell.height > 0 else { return }
        let scale = view.window?.screen.scale ?? 3
        let rowPixels = Int((cell.height * scale).rounded())
        var top = scrollbar.offset
        #if DEBUG
        presentDebug = ""
        #endif
        if let rows = surface.presentedRowSignatures(rowHeight: rowPixels) {
            if let previous = presentedRows {
                // Shifts to every viewport a frame in flight may still show.
                // In order of likelihood; periodic output (a build log) can
                // match several shifts equally, and ties go to the earlier one.
                var candidates: [Int] = []
                let activeTop = max(0, scrollbar.total - surfaceRows)
                for top in [scrollbar.offset, viewportTop, presentedTop] + recentTops.reversed() + [activeTop]
                    where !candidates.contains(top - presentedTop) {
                    candidates.append(top - presentedTop)
                }
                var best: (shift: Int, score: Double)?
                for shift in candidates {
                    let score = Self.matchScore(previous, rows, shift: shift)
                    if score > (best?.score ?? -1) + 0.02 { best = (shift, score) }
                    #if DEBUG
                    presentDebug += String(format: " %d:%.2f", shift, score)
                    #endif
                }
                if let best, best.score >= 0.9 {
                    top = presentedTop + best.shift
                } else if recentTops.contains(scrollbar.offset) == false {
                    top = scrollbar.offset
                }
            }
            presentedRows = rows
        }
        #if DEBUG
        if CommandLine.arguments.contains("-CnxPresentLog") {
            presentLog.append(String(format: "%.4f wall=%.4f top=%d prev=%d sb=%d req=%d off=%.1f", CACurrentMediaTime(), Date().timeIntervalSince1970, top, presentedTop, scrollbar.offset, viewportTop, scrollView.contentOffset.y) + " " + presentDebug)
        }
        #endif
        place(atRow: placesFromReport ? scrollbar.offset : top)
    }

    private func place(atRow top: Int) {
        presentedTop = top
        let origin = CGPoint(x: Self.sidePadding, y: CGFloat(presentedTop - originRow) * cell.height)
        if surface.frame.origin != origin {
            UIView.performWithoutAnimation { surface.frame.origin = origin }
        }
    }

    /// Fraction of the new frame's non-blank rows equal to the previous
    /// frame's rows `shift` further down (1 = the same picture moved by `shift`).
    static func matchScore(_ previous: [UInt64], _ current: [UInt64], shift: Int) -> Double {
        let blank = current.isEmpty ? 0 : mostCommon(current)
        var compared = 0, equal = 0
        for index in current.indices {
            let other = index + shift
            guard other >= 0, other < previous.count, current[index] != blank else { continue }
            compared += 1
            if previous[other] == current[index] { equal += 1 }
        }
        return compared < 4 ? -1 : Double(equal) / Double(compared)
    }

    private static func mostCommon(_ values: [UInt64]) -> UInt64 {
        var counts: [UInt64: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key ?? 0
    }

    private func applyMode(tui: Bool) {
        presentedRows = nil
        // Moving the surface to another superview resigns first responder:
        // typing into vim, then `:q`, used to drop the keyboard's input on the
        // floor (the composer still said "Typing into terminal").
        let hadFocus = surface.isFirstResponder
        defer {
            if hadFocus, !surface.isFirstResponder { surface.becomeFirstResponder() }
        }
        if tui {
            tuiSizing.tuiStarted()
            scrollView.isScrollEnabled = false
            scrollView.topEdgeEffect.style = .hard
            placesFromReport = false
            statusScrim.isHidden = true
            tuiClip.isHidden = false
            tuiHost.addSubview(surface)
            surface.frame = CGRect(x: 0, y: 0, width: view.bounds.width - 2 * Self.sidePadding, height: CGFloat(surfaceRows) * cell.height)
            surface.scroll(toRow: 0)
            scrollButtonVisibility = JumpToBottomVisibility()
            setScrollButton(visible: false)
        } else {
            tuiSizing.tuiEnded()
            scrollView.isScrollEnabled = true
            scrollView.topEdgeEffect.style = .soft
            tuiClip.isHidden = true
            statusScrim.isHidden = false
            scrollView.addSubview(surface)
            viewportTop = -1
            following = true
            placesFromReport = true
            refreshAfterTUI = true
            // Direct typing outlives the TUI only while the terminal keeps focus.
            if !hadFocus { model.directTyping = false }
            document = nil
            updateDocument()
            scrollView.contentOffset.y = maxOffsetY
            updateViewport(visibleMinY: scrollView.contentOffset.y)
        }
        surface.drawNow()
        // The TUI's rows follow the settled keyboard (R1-1); the shell's do not.
        view.setNeedsLayout()
    }

    // MARK: Scrolling

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateBottomFade()
        guard !model.isTUI else { return }
        if scrollView.isTracking, !pinningDrag {
            dragPin.moved(fingerY: scrollView.panGestureRecognizer.location(in: view).y,
                          keyboardTop: view.keyboardLayoutGuide.layoutFrame.minY, following: following)
        }
        if dragPinsToComposer, scrollView.isTracking, !pinningDrag,
           scrollView.panGestureRecognizer.translation(in: view).y > 0 {
            // Dismissing the keyboard: the prompt stays on the composer.
            let target = maxOffsetY
            if abs(scrollView.contentOffset.y - target) > 0.5 {
                pinningDrag = true
                scrollView.contentOffset.y = target
                pinningDrag = false
            }
            updateViewport(visibleMinY: scrollView.contentOffset.y)
            return
        }
        updateViewport(visibleMinY: scrollView.contentOffset.y)
        if scrollView.isTracking || scrollView.isDecelerating || fling != nil {
            follow.userScrolled(offsetY: scrollView.contentOffset.y, maxOffsetY: maxOffsetY, rowHeight: cell.height)
        }
        // The rubber band past the top of a short scrollback is not a scroll
        // away from the prompt (verify/jump-button.md).
        setScrollButton(visible: scrollButtonVisibility.update(
            offsetY: scrollView.contentOffset.y, minOffsetY: -scrollView.contentInset.top, maxOffsetY: maxOffsetY))
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // A reader who already scrolled up keeps scrolling normally.
        // Pinned only once the touch reaches the keyboard (R3-1).
        dragPin.began(following: following, keyboardUp: model.keyboardVisible, isTUI: model.isTUI)
        placesFromReport = false
        fling?.stop()
        fling = nil
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard dragPinsToComposer else { dragPin.ended(); return }
        dragPin.ended()
        if following { scrollView.setContentOffset(CGPoint(x: 0, y: maxOffsetY), animated: false) }
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        // No fling away from the prompt after a pinned dismissal.
        if dragPinsToComposer { targetContentOffset.pointee = scrollView.contentOffset }
    }

    private func setScrollButton(visible: Bool) {
        guard model.isScrolledUp != visible else { return }
        model.isScrolledUp = visible
        UIView.animate(withDuration: 0.2) { self.scrollToBottomButton.alpha = visible ? 1 : 0 }
    }

    func scrollToBottom(animated: Bool) {
        following = true
        scrollView.setContentOffset(CGPoint(x: 0, y: maxOffsetY), animated: animated)
    }

    /// DEBUG demo: a decelerating fling with UIScrollView's normal rate, driven
    /// per display frame through the same delegate path as a finger fling.
    func fling(velocity: CGFloat) {
        placesFromReport = false
        fling?.stop()
        let animator = FlingAnimator(scrollView: scrollView, velocity: velocity, minY: -scrollView.contentInset.top, maxY: maxOffsetY)
        animator.onEnd = { [weak self] in self?.fling = nil }
        fling = animator
        animator.start()
    }

    // MARK: Keyboard

    @objc private func terminalTapped() {
        focusTerminal()
    }

    func focusTerminal() {
        model.directTyping = true
        surface.becomeFirstResponder()
    }

    func hideKeyboard() {
        view.window?.endEditing(true)
    }

    @objc private func keyboardWillShow(_ note: Notification) {
        let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
        let screen = view.window?.screen.bounds ?? UIScreen.main.bounds
        keyBarRule.keyboardWillShow(visibleHeight: max(0, screen.intersection(frame).height))
        applyKeyBarMode()
        setKeyBar(visible: keyBarRule.softKeyboard == .shown, note: note)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        keyBarRule.keyboardWillHide()
        setKeyBar(visible: false, note: note)
    }

    @objc private func keyboardDidHide() {
        keyBarRule.keyboardDidHide()
        applyKeyBarMode()
        keyboardDidChange()
    }

    @objc private func keyboardDidChange() {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        // The keyboard settled: a TUI gets the rows above the composer now,
        // one resize (R1-1).
        tuiSizing.keyboardSettled(stackTop: bottomStack.frame.minY, restingStackTop: restingStackTop, isTUI: model.isTUI)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        // The page changed without output (the keyboard came or went): the
        // saved frame for the next cold launch follows (R2-5).
        model.saveFrameSoon()
        updateViewport(visibleMinY: scrollView.contentOffset.y)
    }

    /// Keyboard state for the toolbar icon and the input target; layout
    /// follows the keyboard layout guide on its own.
    private func setKeyBar(visible: Bool, note: Notification) {
        guard model.keyboardVisible != visible else { return }
        model.keyboardVisible = visible
    }
}

/// The row shift's state, owned by the surface's output queue: every
/// `filter` call runs there, in feed order.
final class RowShiftBox: @unchecked Sendable {
    private var shift = TerminalRowShift()

    func filter(_ data: Data, offset: Int, remoteRows: Int) -> Data {
        shift.filter(data, offset: offset, remoteRows: remoteRows)
    }
}

/// A display link target that does not retain the controller.
@MainActor
final class DisplayLinkProxy: NSObject {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func step() {
        action()
    }
}

/// A view whose layer is a gradient.
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    var gradient: CAGradientLayer { layer as! CAGradientLayer }
}

/// Who owns the chrome around the terminal (see `TerminalViewController`).
public enum TerminalChrome: Sendable {
    /// `TerminalScreen` in a navigation stack: its own toolbar and the safe area.
    case standalone
    /// A workspace tab: CmuxTabsKit's status bar area and floating toolbar.
    case embedded
}

final class TerminalScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

/// Decelerates like UIScrollView (rate 0.998 per millisecond) on the display link.
@MainActor
final class FlingAnimator {
    private weak var scrollView: UIScrollView?
    private var velocity: CGFloat
    private let minY: CGFloat
    private let maxY: CGFloat
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    var onEnd: (() -> Void)?

    init(scrollView: UIScrollView, velocity: CGFloat, minY: CGFloat, maxY: CGFloat) {
        self.scrollView = scrollView
        self.velocity = velocity
        self.minY = minY
        self.maxY = maxY
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        onEnd?()
    }

    /// DEBUG pacing: display frames seen, frames that came later than 1.5
    /// display intervals (a hitch), the longest interval, and the main-thread
    /// time spent per step.
    static var pacing = (frames: 0, hitches: 0, longestMs: 0.0, stepMs: 0.0)
    private var previousTimestamp: CFTimeInterval = 0

    @objc private func step(_ link: CADisplayLink) {
        let began = CACurrentMediaTime()
        defer { Self.pacing.stepMs = max(Self.pacing.stepMs, (CACurrentMediaTime() - began) * 1000) }
        if previousTimestamp > 0 {
            let interval = link.timestamp - previousTimestamp
            let expected = link.targetTimestamp - link.timestamp
            Self.pacing.frames += 1
            Self.pacing.longestMs = max(Self.pacing.longestMs, interval * 1000)
            if expected > 0, interval > expected * 1.5 { Self.pacing.hitches += 1 }
        }
        previousTimestamp = link.timestamp
        guard let scrollView else { return stop() }
        if last == 0 { last = link.timestamp; return }
        let dt = link.targetTimestamp - last
        last = link.targetTimestamp
        velocity *= pow(0.998, dt * 1000)
        var y = scrollView.contentOffset.y + velocity * dt
        if y <= minY || y >= maxY {
            y = min(max(y, minY), maxY)
            velocity = 0
        }
        scrollView.contentOffset.y = y
        if abs(velocity) < 8 { stop() }
    }
}
#endif
