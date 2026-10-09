public import CmuxiOSFeatureKit
import CmuxiOSBrowserCore
import CmuxiOSDesign
public import UIKit

/// The phone browser screen (lane C2): the Mac tab's video with touch and
/// keyboard input, a URL bar, back/forward/reload, paste and a tab switcher.
/// The stream runs only while the screen is visible.
@MainActor
public final class BrowserStreamViewController: UIViewController, UITextFieldDelegate {
    private let source: any BrowserStreamSource
    private let host: HostID
    private let isMock: Bool
    private let chrome: BrowserStreamChrome
    private var currentTab: BrowserTabInfo
    private var session: (any BrowserStreamSession)?
    private var tasks: [Task<Void, Never>] = []
    private var decoder: BrowserVideoDecoder?
    private var viewport: BrowserViewport?
    private var zoomBucket = 1
    private var page: BrowserPageInfo?
    private var lastTap: TimeInterval = 0
    private var editingAddress = false

    private let canvas = BrowserCanvasView()
    private let textInput = BrowserTextInputView()
    private let addressField = UITextField()
    private let statusLabel = UILabel()
    private let statusSpinner = UIActivityIndicatorView(style: .medium)
    private let reconnectButton = UIButton(configuration: .bordered())
    private lazy var backItem = item("chevron.backward", BrowserText.back) { [weak self] in self?.navigate(.back) }
    private lazy var forwardItem = item("chevron.forward", BrowserText.forward) { [weak self] in self?.navigate(.forward) }
    private lazy var reloadItem = item("arrow.clockwise", BrowserText.reload) { [weak self] in self?.reloadOrStop() }
    private lazy var keyboardItem = item("keyboard", BrowserText.keyboard) { [weak self] in self?.toggleKeyboard() }
    private lazy var pasteItem = item("doc.on.clipboard", BrowserText.paste) { [weak self] in self?.pasteToMac() }
    private lazy var tabsItem = item("square.on.square", BrowserText.tabs) { [weak self] in self?.showTabs() }

    public init(source: any BrowserStreamSource, tab: BrowserTabInfo, host: HostID, isMock: Bool,
                chrome: BrowserStreamChrome = .page) {
        self.chrome = chrome
        self.source = source
        self.currentTab = tab
        self.host = host
        self.isMock = isMock
        super.init(nibName: nil, bundle: nil)
        title = tab.title
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "browser.stream"
        configureCanvas()
        configureStatus()
        switch chrome {
        case .page:
            configureAddressField()
            toolbarItems = [backItem, forwardItem, reloadItem, .flexibleSpace(), keyboardItem, pasteItem, tabsItem]
        case .device:
            canvas.directTouch = true
            toolbarItems = [.flexibleSpace(), keyboardItem, pasteItem]
        }
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
        if session == nil { connect() }
    }

    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        disconnect()
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        reportViewport()
    }

    // MARK: Layout

    private func configureAddressField() {
        addressField.borderStyle = .roundedRect
        addressField.placeholder = BrowserText.addressPlaceholder
        addressField.keyboardType = .URL
        addressField.returnKeyType = .go
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.clearButtonMode = .whileEditing
        addressField.textContentType = .URL
        addressField.font = .preferredFont(forTextStyle: .subheadline)
        addressField.adjustsFontForContentSizeCategory = true
        addressField.delegate = self
        addressField.text = currentTab.url?.absoluteString
        addressField.accessibilityIdentifier = "browser.address"
        navigationItem.titleView = addressField
    }

    private func configureCanvas() {
        canvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas)
        textInput.frame = CGRect(x: -10, y: -10, width: 1, height: 1)
        view.addSubview(textInput)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        canvas.onInput = { [weak self] input in self?.send(input) }
        canvas.onTap = { [weak self] in self?.lastTap = ProcessInfo.processInfo.systemUptime }
        canvas.onZoomBucket = { [weak self] bucket in
            self?.zoomBucket = bucket
            self?.reportViewport()
        }
        textInput.onInput = { [weak self] input in self?.send(input) }
    }

    private func configureStatus() {
        statusLabel.font = .preferredFont(forTextStyle: .callout)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        reconnectButton.configuration?.title = BrowserText.reconnect
        reconnectButton.addAction(UIAction { [weak self] _ in self?.connect() }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [statusSpinner, statusLabel, reconnectButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = ShellMetrics.headerSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
        ])
        showStatus(BrowserText.connecting, spinning: true, reconnect: false)
    }

    private func showStatus(_ text: String?, spinning: Bool, reconnect: Bool) {
        statusLabel.text = text
        statusLabel.isHidden = text == nil
        spinning ? statusSpinner.startAnimating() : statusSpinner.stopAnimating()
        reconnectButton.isHidden = !reconnect
    }

    private func item(_ symbol: String, _ label: String, _ action: @escaping @MainActor () -> Void) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction { _ in action() })
        item.accessibilityLabel = label
        return item
    }

    // MARK: Session

    private func connect() {
        disconnect()
        showStatus(BrowserText.connecting, spinning: true, reconnect: false)
        let tabID = currentTab.id
        let host = host
        let source = source
        tasks.append(Task { [weak self] in
            do {
                let session = try await source.open(tabID, on: host)
                self?.attach(session)
            } catch FeatureSourceError.notFound {
                self?.showStatus(BrowserText.tabGone, spinning: false, reconnect: false)
            } catch {
                self?.showStatus(BrowserText.offline, spinning: false, reconnect: true)
            }
        })
    }

    private func attach(_ session: any BrowserStreamSession) {
        guard view.window != nil else {
            Task { await session.close() }
            return
        }
        self.session = session
        viewport = nil
        let decoder = BrowserVideoDecoder(
            output: { [weak self] frame in Task { @MainActor in self?.canvas.videoView.show(frame) } },
            needKeyframe: { Task { await session.requestKeyframe() } })
        self.decoder = decoder
        tasks.append(Task { [weak self] in
            for await state in await session.states() { self?.apply(state) }
        })
        tasks.append(Task { [weak self] in
            for await update in await session.pageUpdates() { self?.apply(update) }
        })
        tasks.append(Task {
            for await sample in await session.videoSamples() { await decoder.decode(sample) }
        })
        reportViewport()
    }

    private func disconnect() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        if let session { Task { await session.close() } }
        session = nil
        if let decoder { Task { await decoder.reset() } }
        decoder = nil
        canvas.videoView.clear()
        textInput.resignFirstResponder()
    }

    private func apply(_ state: BrowserStreamState) {
        switch state {
        case .connecting: showStatus(BrowserText.connecting, spinning: true, reconnect: false)
        case .streaming: showStatus(isMock ? BrowserText.noVideo : nil, spinning: false, reconnect: false)
        case .paused: showStatus(BrowserText.paused, spinning: false, reconnect: false)
        case .ended(let reason):
            showStatus(reason == "browser.tab_closed" ? BrowserText.tabGone : BrowserText.ended, spinning: false, reconnect: true)
        }
    }

    private func apply(_ update: BrowserPageUpdate) {
        switch update {
        case .page(let page):
            self.page = page
            if !editingAddress { addressField.text = page.url }
            title = page.title
            backItem.isEnabled = page.canGoBack
            forwardItem.isEnabled = page.canGoForward
            reloadItem.image = UIImage(systemName: page.isLoading ? "xmark" : "arrow.clockwise")
            reloadItem.accessibilityLabel = page.isLoading ? BrowserText.stop : BrowserText.reload
        case .pageSize(let width, let height):
            canvas.setPageSize(CGSize(width: width, height: height))
        case .cursor(let cursor):
            canvas.cursor = cursor
        case .textFocus(let focused):
            if focused, ProcessInfo.processInfo.systemUptime - lastTap < 1.5 {
                textInput.becomeFirstResponder()
            } else if !focused {
                textInput.resignFirstResponder()
            }
        case .clipboard(let text):
            if view.window != nil { UIPasteboard.general.string = text }
        }
    }

    private func reportViewport() {
        guard let session, canvas.bounds.width > 0 else { return }
        let next = BrowserViewport(width: Int(canvas.bounds.width), height: Int(canvas.bounds.height),
                                   scale: traitCollection.displayScale, zoomBucket: zoomBucket,
                                   refreshHz: view.window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
        guard next != viewport else { return }
        viewport = next
        Task { await session.setViewport(next) }
    }

    // MARK: Actions

    private func send(_ input: BrowserInput) {
        guard let session else { return }
        Task { await session.send(input) }
    }

    private func navigate(_ navigation: BrowserNavigation) {
        guard let session else { return }
        Task { [weak self] in
            let receipt = try? await session.navigate(navigation, key: IntentKey())
            if case .refused(_, let reason)? = receipt { self?.showRefusal(reason) }
        }
    }

    private func reloadOrStop() {
        navigate(page?.isLoading == true ? .stop : .reload)
    }

    private func toggleKeyboard() {
        if textInput.isFirstResponder {
            textInput.resignFirstResponder()
        } else {
            textInput.becomeFirstResponder()
        }
    }

    private func pasteToMac() {
        guard let session, let text = UIPasteboard.general.string, !text.isEmpty else { return }
        Task {
            await session.paste(text)
            await session.send(.key(BrowserKeyEvent(down: true, code: "KeyV", key: "v", modifiers: .command)))
            await session.send(.key(BrowserKeyEvent(down: false, code: "KeyV", key: "v", modifiers: .command)))
        }
    }

    private func showTabs() {
        let switcher = BrowserTabSwitcherViewController(source: source, host: host, current: currentTab.id) { [weak self] tab in
            self?.switchTo(tab)
        }
        let navigation = UINavigationController(rootViewController: switcher)
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        present(navigation, animated: true)
    }

    private func switchTo(_ next: BrowserTabInfo) {
        guard next.id != currentTab.id else { return }
        currentTab = next
        title = next.title
        addressField.text = next.url?.absoluteString
        connect()
    }

    private func showRefusal(_ reason: String) {
        let alert = UIAlertController(title: BrowserText.refusedTitle, message: BrowserText.refusal(reason), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: BrowserText.ok, style: .default))
        present(alert, animated: true)
    }

    // MARK: UITextFieldDelegate

    public func textFieldDidBeginEditing(_ textField: UITextField) {
        editingAddress = true
        textField.selectAll(nil)
    }

    public func textFieldDidEndEditing(_ textField: UITextField) {
        editingAddress = false
        if let page { textField.text = page.url }
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        switch BrowserAddressInput().url(from: textField.text ?? "") {
        case .success(let url):
            textField.resignFirstResponder()
            navigate(.load(url))
        case .failure(let refusal):
            showRefusal(refusal.rawValue)
        }
        return false
    }
}
