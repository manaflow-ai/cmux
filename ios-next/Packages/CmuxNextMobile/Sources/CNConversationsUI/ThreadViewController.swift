#if os(iOS)
import CNCore
import UIKit

/// Passes touches through except where a subview is hit.
final class PassthroughView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        subviews.contains { !$0.isHidden && $0.alpha > 0.01 && $0.isUserInteractionEnabled && $0.point(inside: convert(point, to: $0), with: event) }
    }
}

/// A conversation thread (reference §4–§6): centered avatar + name pill
/// header, bubbles with tails, receipts, typing indicator, swipe-to-reveal
/// timestamps, tapback menu, glass composer and the send flight.
@MainActor
final class ThreadViewController: UIViewController, UICollectionViewDelegate, UIGestureRecognizerDelegate, ConvTransitionHeader {
    enum Mode { case full, preview }

    let store: ConversationsStore
    private(set) var conversation: Conversation
    let mode: Mode
    var focusComposerOnAppear = false
    var blocksBackGesture: Bool { tapback != nil || revealDriver.value != 0 }

    private let style = ConvStyle.shared
    private var observer: UUID?
    private var collectionView: UICollectionView!
    private let layout = TranscriptLayout()
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var rowsById: [String: TranscriptRow] = [:]
    private var didInitialLoad = false

    private let headerContainer = PassthroughView()
    private let backGlass = makeGlass()
    private let backButton = UIButton(type: .system)
    private let headerAvatar = AvatarView()
    private let pillGlass = makeGlass()
    private let pillLabel = UILabel()
    private let pillChevron = UIImageView()

    private let composer = ComposerView()
    private var composerBottom: NSLayoutConstraint?
    private var composerHeight: NSLayoutConstraint?
    private var keyboardShown = false

    private struct PendingSend {
        var text: String
        var fieldRect: CGRect
        var first: Bool
    }
    private var pendingSend: PendingSend?
    private var flights: [AnyObject] = []

    private lazy var revealDriver = SpringDriver(value: 0, spring: .timestampReturn, label: "reveal") { [weak self] v in self?.setReveal(v) }
    private lazy var revealPan = UIPanGestureRecognizer(target: self, action: #selector(handleReveal(_:)))
    private lazy var pressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
    private lazy var menuGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleMenuPress(_:)))
    private weak var pressedCell: TranscriptCell?
    private var tapback: TapbackOverlay?

    init(store: ConversationsStore, conversation: Conversation, mode: Mode = .full) {
        self.store = store
        self.conversation = conversation
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        MainActor.assumeIsolated {
            if let observer { store.removeObserver(observer) }
        }
    }

    var transitionHeaderViews: [UIView] { [headerContainer] }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = style.background
        buildTranscript()
        if mode == .full {
            buildComposer()
            buildHeader()
        }
        observer = store.observe { [weak self] change in
            guard let self else { return }
            switch change {
            case .thread(let id), .typing(let id):
                guard id == conversation.id else { return }
                rebuild()
                // Incoming messages read while the thread is on screen.
                if mode == .full, view.window != nil, let c = store.conversation(id), c.unread > 0 { store.markRead(id) }
            case .removed(let id):
                if id == conversation.id, mode == .full { navigationController?.popToRootViewController(animated: true) }
            case .list:
                if let c = store.conversation(conversation.id) { conversation = c; updateHeader() }
            }
        }
        rebuild()
        let id = conversation.id
        Task { [store] in await store.loadHistory(id) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard mode == .full else { return }
        if store.isUnread(conversation) { store.markRead(conversation.id) }
        if focusComposerOnAppear {
            focusComposerOnAppear = false
            composer.textView.becomeFirstResponder()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        dismissTapback(animated: false)
    }

    // MARK: Transcript

    private func buildTranscript() {
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self
        collectionView.topEdgeEffect.style = .soft
        collectionView.register(TranscriptCell.self, forCellWithReuseIdentifier: TranscriptCell.reuse)
        view.addSubview(collectionView)
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] cv, ip, id in
            let cell = cv.dequeueReusableCell(withReuseIdentifier: TranscriptCell.reuse, for: ip) as! TranscriptCell
            if let row = self?.rowsById[id] { cell.configure(row) }
            return cell
        }
        layout.idForIndexPath = { [weak self] ip in self?.dataSource.itemIdentifier(for: ip) }
        if mode == .full {
            revealPan.delegate = self
            collectionView.addGestureRecognizer(revealPan)
            pressGesture.minimumPressDuration = 0.12
            pressGesture.delegate = self
            menuGesture.minimumPressDuration = 1.0
            menuGesture.delegate = self
            collectionView.addGestureRecognizer(pressGesture)
            collectionView.addGestureRecognizer(menuGesture)
        } else {
            collectionView.isUserInteractionEnabled = false
        }
    }

    private var topInset: CGFloat { mode == .full ? view.safeAreaInsets.top + 111 : 20 }

    private func bottomOffset(contentHeight: CGFloat? = nil) -> CGFloat {
        let h = contentHeight ?? layout.contentHeight
        return max(-collectionView.contentInset.top, h + collectionView.contentInset.bottom - collectionView.bounds.height)
    }

    private var isNearBottom: Bool { collectionView.contentOffset.y >= bottomOffset() - 60 }

    private func rebuild() {
        guard isViewLoaded else { return }
        let messages = store.histories[conversation.id] ?? []
        let builder = TranscriptBuilder(width: view.bounds.width, isGroup: conversation.kind == .group,
                                        introTitle: introTitle, introSubtitle: conversation.subtitle ?? conversation.title)
        let (rows, height) = builder.build(messages: messages, typing: store.isTyping(conversation.id))
        let old = rowsById
        let wasAtBottom = !didInitialLoad || isNearBottom
        let oldBottom = bottomOffset()
        var flying: TranscriptRow?
        if let p = pendingSend {
            flying = rows.first { row in
                if case .bubble(let m, _) = row.kind, m.sender.isMe, old[row.id] == nil, m.text == p.text { return true }
                return false
            }
        }
        rowsById = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let newIds = rows.map(\.id).filter { old[$0] == nil }
        layout.fadeInIds = Set(newIds.filter { $0.hasPrefix("time-") || $0 == "receipt" || $0.hasPrefix("name-") })
        layout.popInIds = Set(rows.filter { old[$0.id] == nil && ($0.id == "typing" || (!$0.outgoing && $0.id.hasPrefix("msg-"))) }.map(\.id))
        if let flying { layout.hiddenIds.insert(flying.id) }
        layout.setRows(rows, height: height)

        var snap = NSDiffableDataSourceSnapshot<Int, String>()
        snap.appendSections([0])
        snap.appendItems(rows.map(\.id))
        let changed = rows.filter { r in old[r.id].map { $0.kind != r.kind } ?? false }.map(\.id)
        snap.reconfigureItems(changed)

        guard didInitialLoad, view.window != nil, !messages.isEmpty || !old.isEmpty else {
            dataSource.apply(snap, animatingDifferences: false)
            collectionView.layoutIfNeeded()
            if !messages.isEmpty { didInitialLoad = true }
            collectionView.contentOffset.y = bottomOffset()
            return
        }
        let receiptMoved = old["receipt"]?.frame != rowsById["receipt"]?.frame && newIds.allSatisfy { !$0.hasPrefix("msg-") }
        let spring: ConvSpring = receiptMoved ? .receiptMove : .transcriptShift
        let target = wasAtBottom ? bottomOffset(contentHeight: height) : collectionView.contentOffset.y
        let animations = {
            self.dataSource.apply(snap, animatingDifferences: true)
            if wasAtBottom, abs(target - oldBottom) > 0.1 || abs(self.collectionView.contentOffset.y - target) > 0.1 {
                self.collectionView.contentOffset.y = target
            }
            self.collectionView.layoutIfNeeded()
        }
        if UIAccessibility.isReduceMotionEnabled {
            UIView.performWithoutAnimation(animations)
        } else {
            UIView.animate(springDuration: spring.response, bounce: 1 - spring.damping, initialSpringVelocity: 0,
                           delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: animations)
        }
        if let flying { startFlight(flying, contentOffset: target) }
    }

    private var introTitle: String {
        switch conversation.kind {
        case .chief: String(localized: "Chief")
        case .agent: String(localized: "Agent")
        case .group: String(localized: "Group")
        case .unknown: String(localized: "Conversation")
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard collectionView != nil else { return }
        let bottomInset: CGFloat
        if mode == .full {
            let composerTop = composer.convert(composer.fieldFrame, to: view).minY
            bottomInset = max(0, view.bounds.height - composerTop) + 10
        } else {
            bottomInset = 16
        }
        let insets = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        if collectionView.contentInset != insets {
            let stick = isNearBottom || !didInitialLoad
            collectionView.contentInset = insets
            collectionView.verticalScrollIndicatorInsets = insets
            if stick { collectionView.contentOffset.y = bottomOffset() }
        }
        if abs((layout.rows.first?.frame.width ?? view.bounds.width) - view.bounds.width) > 0.5 { rebuild() }
    }

    // MARK: Header

    private func buildHeader() {
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerContainer)
        let edge = UIScrollEdgeElementContainerInteraction()
        edge.scrollView = collectionView
        edge.edge = .top
        headerContainer.addInteraction(edge)
        backButton.setImage(UIImage(systemName: "chevron.backward", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        backButton.tintColor = style.primary
        backButton.accessibilityLabel = String(localized: "Back")
        backButton.addTarget(self, action: #selector(back), for: .touchUpInside)
        backGlass.contentView.addSubview(backButton)
        pillLabel.font = .sf(17, .semibold)
        pillLabel.textColor = style.primary
        pillChevron.image = UIImage(systemName: "chevron.forward", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        pillChevron.tintColor = style.secondary
        pillChevron.contentMode = .center
        pillGlass.contentView.addSubview(pillLabel)
        pillGlass.contentView.addSubview(pillChevron)
        for v in [backGlass, headerAvatar, pillGlass] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            headerContainer.addSubview(v)
        }
        for v in [backButton, pillLabel, pillChevron] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false }
        let safe = view.safeAreaLayoutGuide.topAnchor
        NSLayoutConstraint.activate([
            headerContainer.topAnchor.constraint(equalTo: view.topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerContainer.bottomAnchor.constraint(equalTo: safe, constant: 92),
            backGlass.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            backGlass.topAnchor.constraint(equalTo: safe),
            backGlass.widthAnchor.constraint(equalToConstant: style.backButton),
            backGlass.heightAnchor.constraint(equalToConstant: style.backButton),
            backButton.leadingAnchor.constraint(equalTo: backGlass.leadingAnchor),
            backButton.trailingAnchor.constraint(equalTo: backGlass.trailingAnchor),
            backButton.topAnchor.constraint(equalTo: backGlass.topAnchor),
            backButton.bottomAnchor.constraint(equalTo: backGlass.bottomAnchor),
            headerAvatar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            headerAvatar.topAnchor.constraint(equalTo: safe),
            headerAvatar.widthAnchor.constraint(equalToConstant: style.headerAvatar),
            headerAvatar.heightAnchor.constraint(equalToConstant: style.headerAvatar),
            pillGlass.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pillGlass.topAnchor.constraint(equalTo: safe, constant: 55),
            pillGlass.heightAnchor.constraint(equalToConstant: 32.33),
            pillGlass.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -150),
            pillLabel.leadingAnchor.constraint(equalTo: pillGlass.leadingAnchor, constant: 13),
            pillLabel.centerYAnchor.constraint(equalTo: pillGlass.centerYAnchor),
            pillChevron.leadingAnchor.constraint(equalTo: pillLabel.trailingAnchor, constant: 4),
            pillChevron.centerYAnchor.constraint(equalTo: pillGlass.centerYAnchor),
            pillChevron.widthAnchor.constraint(equalToConstant: 8),
            pillChevron.trailingAnchor.constraint(equalTo: pillGlass.trailingAnchor, constant: -12),
        ])
        pillLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateHeader()
    }

    private func updateHeader() {
        guard mode == .full else { return }
        headerAvatar.configure(conversation)
        pillLabel.text = conversation.title
        pillGlass.accessibilityLabel = conversation.title
    }

    @objc private func back() {
        navigationController?.popViewController(animated: true)
    }

    // MARK: Composer and keyboard

    private func buildComposer() {
        composer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composer)
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        let bottom = composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -style.composerMarginIdle)
        let height = composer.heightAnchor.constraint(equalToConstant: composer.fieldHeight)
        composerBottom = bottom
        composerHeight = height
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottom, height,
        ])
        let edge = UIScrollEdgeElementContainerInteraction()
        edge.scrollView = collectionView
        edge.edge = .bottom
        composer.addInteraction(edge)
        composer.onSend = { [weak self] text in self?.send(text) }
        composer.onHeightChange = { [weak self] in
            guard let self else { return }
            composerHeight?.constant = composer.fieldHeight
            UIView.animate(springDuration: 0.25, bounce: 0) { self.view.layoutIfNeeded() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardWillChange(_ n: Notification) {
        guard view.window != nil, composer.textView.isFirstResponder || n.name == UIResponder.keyboardWillHideNotification else { return }
        let showing = n.name == UIResponder.keyboardWillShowNotification
        guard showing != keyboardShown else { return }
        keyboardShown = showing
        let margin = showing ? style.composerMarginKeyboard : style.composerMarginIdle
        let duration = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (n.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? 7
        composerBottom?.constant = -margin
        composer.margin = margin
        UIView.animate(withDuration: duration, delay: 0, options: [UIView.AnimationOptions(rawValue: UInt(curveRaw) << 16), .beginFromCurrentState]) {
            self.composer.layoutIfNeeded()
            self.view.layoutIfNeeded()
        }
    }

    private func send(_ text: String) {
        let fieldRect = composer.convert(composer.fieldFrame, to: view)
        pendingSend = PendingSend(text: text, fieldRect: fieldRect, first: (store.histories[conversation.id] ?? []).isEmpty)
        composer.clear()
        store.send(text, to: conversation.id)
        if pendingSend != nil { pendingSend = nil }
    }

    /// The send flight (reference §6): the bubble fills the field for ~110 ms,
    /// then squashes, lifts and flies to its slot on spring(0.45, 0.84)
    /// (0.50 / 0.72 for the first message), while the transcript shifts on
    /// spring(0.30, 1.0).
    private func startFlight(_ row: TranscriptRow, contentOffset: CGFloat) {
        guard let p = pendingSend, case .bubble(let m, let tail) = row.kind else { return }
        pendingSend = nil
        let final = CGRect(x: row.body.minX + collectionView.frame.minX,
                           y: row.body.minY - contentOffset + collectionView.frame.minY,
                           width: row.body.width, height: row.body.height)
        let start = p.fieldRect
        let flyer = BubbleView(frame: start)
        flyer.outgoing = true
        flyer.tail = tail
        flyer.fill = style.outgoing
        flyer.label.attributedText = TranscriptMetrics.bubbleText(m.text, color: style.outgoingText)
        flyer.shape.opacity = 0
        view.addSubview(flyer)
        let id = row.id
        let finish = { [weak self, weak flyer] in
            flyer?.removeFromSuperview()
            guard let self else { return }
            layout.hiddenIds.remove(id)
            layout.invalidateLayout()
        }
        if UIAccessibility.isReduceMotionEnabled {
            finish()
            return
        }
        let fill = TimedDriver(duration: 0.11) { t in flyer.shape.opacity = Float(t) }
        flights.append(fill)
        let spring: ConvSpring = p.first ? .firstSendFlight : .sendFlight
        let flight = SpringDriver(value: 0, spring: spring, label: "send") { t in
            let w = lerp(start.width, final.width, t)
            let fullH = lerp(start.height, final.height, t)
            let squash = 1 - 0.55 * sin(.pi * clamp01(t / 0.55))
            let h = max(14, fullH * squash)
            let maxX = lerp(start.maxX, final.maxX, t)
            let midY = lerp(start.midY, final.midY, t)
            flyer.frame = CGRect(x: maxX - w, y: midY - h / 2, width: w, height: h)
            flyer.textScaleY = h / max(fullH, 1)
            flyer.layoutIfNeeded()
        }
        flights.append(flight)
        fill.run { [weak self, weak flight] in
            flight?.animate(to: 1) { _ in
                finish()
                self?.flights.removeAll()
            }
        }
    }

    // MARK: Timestamp reveal

    private func setReveal(_ v: CGFloat) {
        layout.reveal = v
        layout.invalidateLayout()
    }

    @objc private func handleReveal(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            revealDriver.stop()
            collectionView.panGestureRecognizer.isEnabled = false
            collectionView.panGestureRecognizer.isEnabled = true
        case .changed:
            let d = max(0, -g.translation(in: view).x)
            // ~0.3 x finger travel, saturating around 60-70 pt (reference §6).
            let raw = d * 0.3
            let v = raw < 54 ? raw : min(70, 54 + (raw - 54) * 0.3)
            revealDriver.set(v)
        default:
            revealDriver.animate(to: 0, spring: .timestampReturn, velocity: 0)
        }
    }

    // MARK: Tapback

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === revealPan {
            let v = revealPan.velocity(in: view)
            return v.x < 0 && abs(v.x) > abs(v.y) * 1.2 && tapback == nil
        }
        if g === pressGesture || g === menuGesture {
            return tapback == nil && bubbleCell(at: g.location(in: collectionView)) != nil
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g === pressGesture && other === menuGesture) || (g === menuGesture && other === pressGesture)
    }

    private func bubbleCell(at point: CGPoint) -> TranscriptCell? {
        guard let ip = collectionView.indexPathForItem(at: point), let cell = collectionView.cellForItem(at: ip) as? TranscriptCell,
              let row = cell.row else { return nil }
        switch row.kind {
        case .bubble, .emoji:
            return row.body.insetBy(dx: -4, dy: -4).contains(point) ? cell : nil
        default:
            return nil
        }
    }

    private func pressTarget(_ cell: TranscriptCell) -> UIView {
        guard let row = cell.row else { return cell }
        if case .emoji = row.kind { return cell.slider }
        return cell.bubble
    }

    @objc private func handlePress(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            guard let cell = bubbleCell(at: g.location(in: collectionView)) else { return }
            pressedCell = cell
            let target = pressTarget(cell)
            // Linear scale-up to ~1.08 over the rest of the first 500 ms.
            UIView.animate(withDuration: 0.38, delay: 0, options: [.curveLinear, .allowUserInteraction]) {
                target.transform = CGAffineTransform(scaleX: 1.08, y: 1.08)
            }
        case .ended, .cancelled, .failed:
            if tapback == nil, let cell = pressedCell {
                let target = pressTarget(cell)
                UIView.animate(withDuration: 0.1, delay: 0, options: [.beginFromCurrentState]) { target.transform = .identity }
                pressedCell = nil
            }
        default:
            break
        }
    }

    @objc private func handleMenuPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let cell = pressedCell ?? bubbleCell(at: g.location(in: collectionView)), let row = cell.row else { return }
        let message: Message
        switch row.kind {
        case .bubble(let m, _), .emoji(let m): message = m
        default: return
        }
        let target = pressTarget(cell)
        UIView.animate(withDuration: 0.1, delay: 0, options: [.beginFromCurrentState]) { target.transform = .identity }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let body = collectionView.convert(row.body.offsetBy(dx: -layout.reveal, dy: 0), to: view)
        let snapshot = target.snapshotView(afterScreenUpdates: false)
        let overlay = TapbackOverlay(frame: view.bounds, bubbleFrame: body, outgoing: row.outgoing, snapshot: snapshot, safeTop: view.safeAreaInsets.top,
                                     safeBottom: view.bounds.height - composer.frame.minY)
        overlay.onCopy = { UIPasteboard.general.string = message.text }
        overlay.onShare = { [weak self] in
            let vc = UIActivityViewController(activityItems: [message.text], applicationActivities: nil)
            self?.present(vc, animated: true)
        }
        overlay.onDismiss = { [weak self] in self?.dismissTapback(animated: true) }
        view.addSubview(overlay)
        tapback = overlay
        pressedCell = nil
        overlay.present()
    }

    private func dismissTapback(animated: Bool) {
        guard let t = tapback else { return }
        tapback = nil
        t.dismiss(animated: animated)
    }
}
#endif
