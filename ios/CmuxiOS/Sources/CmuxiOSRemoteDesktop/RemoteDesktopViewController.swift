import CmuxBrowserStream
import CmuxiOSDesign
import CmuxiOSFeatureKit
import CmuxiOSRemoteDesktopCore
import CmuxRemoteDesktop
import UIKit

/// The remote desktop screen (c3-rd.md 3 to 6): the decoded video in a
/// pinch-zoom lens, a locally drawn trackpad cursor, gestures mapped to rd
/// input, a toolbar (keyboard, view or control, pointer style, displays,
/// clipboard) and the keyboard with its modifier bar. One `RemoteDesktopClient`
/// per screen; closing the screen closes the channel.
@MainActor
final class RemoteDesktopViewController: UIViewController, UIGestureRecognizerDelegate {
    private enum PointerStyle { case trackpad, direct }

    private let client: RemoteDesktopClient
    private let hostName: String
    /// Times the short notices (auto-dismiss), cancelled with the screen.
    private let clock: any Clock<Duration>
    private let videoView = H264VideoDisplayView()
    private let cursorView = UIImageView(image: UIImage(systemName: "cursorarrow"))
    private let keyInput = RemoteDesktopKeyInputView()
    private let modifierBar = ModifierBarView()
    private let statusStack = UIStackView()
    private let statusSpinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let statusButton = UIButton(configuration: .gray())

    private var opened: RemoteDesktopChannelOpened?
    private var viewport: RemoteDesktopViewport?
    private var pointer = TrackpadPointer(width: 1, height: 1)
    private var latch = ModifierLatch()
    private let gestures = RemoteDesktopGestureMapper()
    private var style = PointerStyle.trackpad
    private var mode = DesktopMode.view
    private var displays: [DesktopDisplay] = []
    private var shownView: DesktopView?
    private var lastRequest: (rect: DesktopRect, pixelWidth: Int, pixelHeight: Int)?
    private var failure: RemoteDesktopFailure?
    private var started = false
    private var tasks: [Task<Void, Never>] = []
    private var dragging = false
    private var lastPan = CGPoint.zero
    private var lastScroll = CGPoint.zero

    init(client: RemoteDesktopClient, hostName: String, title: String, clock: any Clock<Duration> = ContinuousClock()) {
        self.client = client
        self.hostName = hostName
        self.clock = clock
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "rd.screen"
        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoView.accessibilityLabel = RemoteDesktopText.screenLabel
        view.addSubview(videoView)
        cursorView.tintColor = .white
        cursorView.layer.shadowColor = UIColor.black.cgColor
        cursorView.layer.shadowOpacity = 0.8
        cursorView.layer.shadowRadius = 1.5
        cursorView.layer.shadowOffset = .zero
        cursorView.isHidden = true
        view.addSubview(cursorView)
        keyInput.frame = .zero
        keyInput.accessory = modifierBar
        view.addSubview(keyInput)
        configureStatus()
        configureInput()
        configureGestures()
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.closeScreen()
        })
        navigationItem.leftBarButtonItem?.accessibilityLabel = RemoteDesktopText.done
        showStatus(RemoteDesktopText.statusConnecting, spinning: true)
        updateToolbar()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.setToolbarHidden(false, animated: false)
        guard !started else { return }
        started = true
        start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true { shutDown() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard var viewport else { return }
        if viewport.bounds != view.bounds.size {
            viewport.setBounds(view.bounds.size)
            self.viewport = viewport
            layoutVideo()
            requestView()
        }
    }

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !keyInput.forward(presses, down: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !keyInput.forward(presses, down: false) { super.pressesEnded(presses, with: event) }
    }

    // MARK: Session

    private func start() {
        let client = client
        tasks.append(Task { [weak self] in
            do {
                let opened = try await client.open()
                self?.didOpen(opened)
            } catch let error as RemoteDesktopClientError {
                self?.fail(RemoteDesktopFailure(error))
            } catch {
                self?.fail(.unreachable)
            }
        })
        tasks.append(Task { [weak self] in
            for await event in client.events { self?.handle(event) }
        })
        tasks.append(Task { [weak self] in
            for await frame in client.frames { self?.show(frame) }
        })
    }

    private func didOpen(_ opened: RemoteDesktopChannelOpened) {
        self.opened = opened
        mode = opened.mode
        displays = opened.displays
        viewport = RemoteDesktopViewport(bounds: view.bounds.size, target: opened.target)
        pointer = TrackpadPointer(width: opened.target.width, height: opened.target.height)
        cursorView.isHidden = opened.cursor != .local
        updateToolbar()
        layoutVideo()
        requestView()
    }

    private func handle(_ event: RemoteDesktopEvent) {
        switch event {
        case .viewApplied:
            break
        case .target(let info):
            viewport?.setTarget(info)
            pointer.resize(width: info.width, height: info.height)
            lastRequest = nil
            layoutVideo()
            requestView()
        case .windows:
            break
        case .modeApplied(let applied, let reason):
            mode = applied
            updateToolbar()
            if reason == "accessibility" { flash(RemoteDesktopText.modeAccessibility) }
        case .clipboard(let text):
            guard viewIfLoaded?.window != nil else { return }
            UIPasteboard.general.string = text
            flash(RemoteDesktopText.copiedFromMac)
        case .state(let state, _):
            switch state {
            case .waitingConsent:
                showStatus(RemoteDesktopText.statusWaiting + "\n" + RemoteDesktopText.format(RemoteDesktopText.statusWaitingDetail, hostName),
                           spinning: true)
            case .authRequired:
                askPassword()
            case .live:
                hideStatus()
            case .paused:
                showStatus(RemoteDesktopText.statusPaused, spinning: false)
            }
        case .inputApplied, .datagramLane:
            break
        case .ended(let reason):
            failure = RemoteDesktopFailure(code: reason)
        case .closed(let reason):
            fail(failure ?? RemoteDesktopFailure(code: reason))
        }
    }

    private func show(_ frame: RemoteDesktopFrame) {
        if failure == nil { hideStatus() }
        shownView = frame.view
        layoutVideo()
        if !videoView.enqueue(frame.accessUnit, isKeyframe: frame.isKeyframe, captureMicros: frame.captureMicros) {
            let client = client
            Task { await client.requestRecovery() }
        }
    }

    private func fail(_ reason: RemoteDesktopFailure) {
        guard failure == nil || failure == reason else { return }
        failure = reason
        keyInput.resignFirstResponder()
        showStatus(reason.message, spinning: false, action: RemoteDesktopText.close)
        updateToolbar()
    }

    private func shutDown() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        let client = client
        Task { await client.close() }
    }

    private func closeScreen() {
        shutDown()
        dismiss(animated: true)
    }

    // MARK: Layout and view requests

    private func layoutVideo() {
        guard let viewport else { return }
        if let shownView { videoView.videoRect = viewport.screenRect(for: shownView) }
        let point = viewport.screenPoint(forTarget: pointer.position)
        cursorView.frame = CGRect(x: point.x - 4, y: point.y - 2, width: 20, height: 24)
    }

    /// Asks the Mac for what is on screen, at the screen's pixels.
    private func requestView() {
        guard let viewport, opened != nil, failure == nil else { return }
        let request = viewport.viewRequest(screenScale: traitCollection.displayScale)
        if let last = lastRequest, last.rect == request.rect, last.pixelWidth == request.pixelWidth,
           last.pixelHeight == request.pixelHeight { return }
        lastRequest = request
        let client = client
        Task { _ = try? await client.requestView(request.rect, pixelWidth: request.pixelWidth, pixelHeight: request.pixelHeight) }
    }

    // MARK: Input

    private func send(_ events: [RdInputEvent]) {
        guard mode == .control, !events.isEmpty, failure == nil else { return }
        let client = client
        Task { try? await client.send(events) }
    }

    private func configureInput() {
        keyInput.onText = { [weak self] text in
            guard let self else { return }
            send(latch.type(text))
            modifierBar.show(latch)
        }
        keyInput.onBackspace = { [weak self] in self?.pressKey(.backspace) }
        keyInput.onKey = { [weak self] usage, down in self?.send([.key(usage: usage.rawValue, down: down)]) }
        modifierBar.onKey = { [weak self] usage in self?.pressKey(usage) }
        modifierBar.onModifier = { [weak self] modifier in
            guard let self else { return }
            latch.toggle(modifier)
            modifierBar.show(latch)
        }
        modifierBar.onPaste = { [weak self] in self?.pasteToMac() }
    }

    private func pressKey(_ usage: HidUsage) {
        send(latch.press(usage))
        modifierBar.show(latch)
    }

    /// Pushes the phone's text, then the paste chord the target expects.
    private func pasteToMac() {
        guard mode == .control, let text = UIPasteboard.general.string, !text.isEmpty else { return }
        let client = client
        let chord = opened?.target.kind == .vnc ? HidUsage.leftControl : HidUsage.leftCommand
        let v = HidUsage.key(for: "v")!
        Task {
            try? await client.pushClipboard(text)
            try? await client.send([.key(usage: chord.rawValue, down: true), .key(usage: v.rawValue, down: true),
                                    .key(usage: v.rawValue, down: false), .key(usage: chord.rawValue, down: false)])
        }
    }

    private func toggleKeyboard() {
        if keyInput.isFirstResponder {
            keyInput.resignFirstResponder()
        } else {
            keyInput.becomeFirstResponder()
        }
    }

    // MARK: Gestures

    private func configureGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onePan(_:)))
        pan.maximumNumberOfTouches = 1
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        let twoTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTap(_:)))
        twoTap.numberOfTouchesRequired = 2
        let threeTap = UITapGestureRecognizer(target: self, action: #selector(threeFingerTap(_:)))
        threeTap.numberOfTouchesRequired = 3
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(hold(_:)))
        hold.minimumPressDuration = 0.35
        hold.allowableMovement = 12
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(twoFingerPan(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hover(_:)))
        for recognizer in [pan, tap, twoTap, threeTap, hold, pinch, scroll, hover] as [UIGestureRecognizer] {
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch and two-finger scroll run together, like a trackpad.
        (gestureRecognizer is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
            || (gestureRecognizer is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }

    @objc private func onePan(_ recognizer: UIPanGestureRecognizer) {
        guard let viewport else { return }
        switch style {
        case .trackpad:
            if recognizer.state == .began { lastPan = .zero }
            let translation = recognizer.translation(in: view)
            let delta = CGPoint(x: translation.x - lastPan.x, y: translation.y - lastPan.y)
            lastPan = translation
            let velocity = recognizer.velocity(in: view)
            let event = pointer.move(by: delta, speed: hypot(velocity.x, velocity.y), scale: viewport.scale)
            followCursor()
            send([event])
        case .direct:
            let event = pointer.moveTo(viewport.targetPoint(forScreen: recognizer.location(in: view)))
            switch recognizer.state {
            case .began: send([event, gestures.press()])
            case .changed: send([event])
            default: send([event, gestures.release()])
            }
            layoutVideo()
        }
        if recognizer.state == .ended || recognizer.state == .cancelled { requestView() }
    }

    @objc private func tap(_ recognizer: UITapGestureRecognizer) {
        guard let viewport else { return }
        switch style {
        case .trackpad: send(gestures.click())
        case .direct:
            send(gestures.tap(at: pointer.moveTo(viewport.targetPoint(forScreen: recognizer.location(in: view)))))
            layoutVideo()
        }
    }

    @objc private func twoFingerTap(_ recognizer: UITapGestureRecognizer) {
        send(gestures.click(button: RemoteDesktopGestureMapper.secondary))
    }

    @objc private func threeFingerTap(_ recognizer: UITapGestureRecognizer) {
        toggleKeyboard()
    }

    /// Trackpad: hold, then drag with the button down. Direct: secondary click.
    @objc private func hold(_ recognizer: UILongPressGestureRecognizer) {
        guard let viewport else { return }
        switch style {
        case .direct:
            if recognizer.state == .began {
                send(gestures.tap(at: pointer.moveTo(viewport.targetPoint(forScreen: recognizer.location(in: view))),
                                  button: RemoteDesktopGestureMapper.secondary))
                layoutVideo()
            }
        case .trackpad:
            switch recognizer.state {
            case .began:
                dragging = true
                lastPan = recognizer.location(in: view)
                send([gestures.press()])
            case .changed:
                let location = recognizer.location(in: view)
                let delta = CGPoint(x: location.x - lastPan.x, y: location.y - lastPan.y)
                lastPan = location
                send([pointer.move(by: delta, speed: 0, scale: viewport.scale)])
                followCursor()
            default:
                if dragging { send([gestures.release()]) }
                dragging = false
                requestView()
            }
        }
    }

    @objc private func pinch(_ recognizer: UIPinchGestureRecognizer) {
        guard var viewport else { return }
        viewport.pinch(by: recognizer.scale, around: recognizer.location(in: view))
        recognizer.scale = 1
        self.viewport = viewport
        layoutVideo()
        if recognizer.state == .ended || recognizer.state == .cancelled { requestView() }
    }

    @objc private func twoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        guard let viewport else { return }
        if recognizer.state == .began { lastScroll = .zero }
        let translation = recognizer.translation(in: view)
        let delta = CGPoint(x: translation.x - lastScroll.x, y: translation.y - lastScroll.y)
        lastScroll = translation
        if let event = gestures.scroll(byScreen: delta, scale: viewport.scale) { send([event]) }
    }

    /// iPad pointer: the remote cursor follows the hover in both styles.
    @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
        guard let viewport, recognizer.state == .changed else { return }
        send([pointer.moveTo(viewport.targetPoint(forScreen: recognizer.location(in: view)))])
        layoutVideo()
    }

    private func followCursor() {
        guard var viewport else { return }
        viewport.follow(pointer.position)
        self.viewport = viewport
        layoutVideo()
    }

    // MARK: Chrome

    private func updateToolbar() {
        let keyboard = UIBarButtonItem(image: UIImage(systemName: "keyboard"), primaryAction: UIAction { [weak self] _ in
            self?.toggleKeyboard()
        })
        keyboard.accessibilityLabel = RemoteDesktopText.keyboard
        let modeItem = UIBarButtonItem(
            title: mode == .control ? RemoteDesktopText.modeControl : RemoteDesktopText.modeView,
            image: UIImage(systemName: mode == .control ? "cursorarrow.rays" : "eye"),
            primaryAction: UIAction { [weak self] _ in self?.toggleMode() })
        let styleMenu = UIMenu(title: RemoteDesktopText.inputTitle, children: [
            UIAction(title: RemoteDesktopText.inputTrackpad, image: UIImage(systemName: "rectangle.and.hand.point.up.left"),
                     state: style == .trackpad ? .on : .off) { [weak self] _ in self?.setStyle(.trackpad) },
            UIAction(title: RemoteDesktopText.inputDirect, image: UIImage(systemName: "hand.point.up.left"),
                     state: style == .direct ? .on : .off) { [weak self] _ in self?.setStyle(.direct) },
        ])
        let styleItem = UIBarButtonItem(image: UIImage(systemName: "hand.point.up.left"), menu: styleMenu)
        styleItem.accessibilityLabel = RemoteDesktopText.inputTitle
        let clipboard = UIBarButtonItem(image: UIImage(systemName: "doc.on.clipboard"), menu: UIMenu(children: [
            UIAction(title: RemoteDesktopText.pasteToMac, image: UIImage(systemName: "doc.on.clipboard"),
                     attributes: mode == .control ? [] : .disabled) { [weak self] _ in self?.pasteToMac() },
            UIAction(title: RemoteDesktopText.copyFromMac, image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                guard let client = self?.client else { return }
                Task { try? await client.pullClipboard() }
            },
        ]))
        clipboard.accessibilityLabel = RemoteDesktopText.clipboard
        var items: [UIBarButtonItem] = [keyboard, .flexibleSpace(), modeItem, .flexibleSpace(), styleItem, .flexibleSpace(), clipboard]
        if displays.count > 1 {
            let current = opened?.target.name
            let menu = UIMenu(title: RemoteDesktopText.displays, children: displays.map { display in
                UIAction(title: display.name, state: display.name == current ? .on : .off) { [weak self] _ in
                    guard let client = self?.client else { return }
                    Task { try? await client.selectDisplay(display.id) }
                }
            })
            let item = UIBarButtonItem(image: UIImage(systemName: "display.2"), menu: menu)
            item.accessibilityLabel = RemoteDesktopText.displays
            items += [.flexibleSpace(), item]
        }
        let enabled = opened != nil && failure == nil
        for item in items { item.isEnabled = enabled }
        setToolbarItems(items, animated: false)
    }

    private func toggleMode() {
        let next: DesktopMode = mode == .control ? .view : .control
        let client = client
        Task { try? await client.setMode(next) }
    }

    private func setStyle(_ next: PointerStyle) {
        style = next
        updateToolbar()
    }

    private func configureStatus() {
        statusStack.axis = .vertical
        statusStack.alignment = .center
        statusStack.spacing = 12
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusSpinner.color = .white
        statusButton.addAction(UIAction { [weak self] _ in self?.closeScreen() }, for: .primaryActionTriggered)
        statusButton.isHidden = true
        for item in [statusSpinner, statusLabel, statusButton] as [UIView] { statusStack.addArrangedSubview(item) }
        view.addSubview(statusStack)
        NSLayoutConstraint.activate([
            statusStack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            statusStack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            statusStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            statusStack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
    }

    private func showStatus(_ text: String, spinning: Bool, action: String? = nil) {
        statusStack.isHidden = false
        statusLabel.text = text
        if spinning { statusSpinner.startAnimating() } else { statusSpinner.stopAnimating() }
        statusButton.configuration?.title = action
        statusButton.isHidden = action == nil
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func hideStatus() {
        guard !statusStack.isHidden else { return }
        statusStack.isHidden = true
        statusSpinner.stopAnimating()
    }

    /// A short notice in the navigation prompt (accessibility, clipboard).
    private func flash(_ text: String) {
        navigationItem.prompt = text
        UIAccessibility.post(notification: .announcement, argument: text)
        let clock = clock
        tasks.append(Task { [weak self] in
            try? await clock.sleep(for: .seconds(3))
            guard !Task.isCancelled, self?.navigationItem.prompt == text else { return }
            self?.navigationItem.prompt = nil
        })
    }

    private func askPassword() {
        let alert = UIAlertController(title: RemoteDesktopText.authTitle,
                                      message: RemoteDesktopText.format(RemoteDesktopText.authMessage, title ?? hostName),
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.placeholder = RemoteDesktopText.authPassword
            field.textContentType = .password
        }
        alert.addAction(UIAlertAction(title: RemoteDesktopText.cancel, style: .cancel) { [weak self] _ in self?.closeScreen() })
        alert.addAction(UIAlertAction(title: RemoteDesktopText.vncConnect, style: .default) { [weak self, weak alert] _ in
            guard let self, let password = alert?.textFields?.first?.text else { return }
            let client = client
            Task { try? await client.authenticate(password: password) }
        })
        present(alert, animated: true)
    }
}
