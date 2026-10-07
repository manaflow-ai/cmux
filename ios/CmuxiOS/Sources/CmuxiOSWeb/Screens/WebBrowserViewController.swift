import CmuxiOSDesign
import CmuxiOSFeatureKit
import CmuxiOSWebCore
import UIKit
import WebKit

/// A WKWebView on one machine's localhost (c14-web.md section 4): pages load
/// from the route's phone loopback proxy, so they run on the phone and only
/// TCP bytes cross the tunnel. Loopback navigations to another port open
/// that port's proxy first; other http(s) links open in the system browser,
/// so the tunnel's data store never holds a public site.
@MainActor
final class WebBrowserViewController: UIViewController, WKNavigationDelegate, UITextFieldDelegate {
    private let feature: WebFeature
    private let target: WebTarget
    private var address: WebAddress
    private var entry: WebRoutes.Entry?
    /// Phone ports this route serves, for synchronous navigation decisions.
    private var localPorts: [UInt16: UInt16] = [:]
    private var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    private let addressField = UITextField()
    private let statusLabel = UILabel()
    private let retryButton = UIButton(configuration: .bordered())
    private lazy var backItem = item("chevron.backward", WebText.back) { [weak self] in self?.webView?.goBack() }
    private lazy var forwardItem = item("chevron.forward", WebText.forward) { [weak self] in self?.webView?.goForward() }
    private lazy var reloadItem = item("arrow.clockwise", WebText.reload) { [weak self] in self?.reloadPage() }

    init(feature: WebFeature, target: WebTarget, address: WebAddress) {
        self.feature = feature
        self.target = target
        self.address = address
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "web.browser"
        configureAddressField()
        configureStatus()
        toolbarItems = [backItem, forwardItem, .flexibleSpace(), reloadItem]
        connect()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isMovingFromParent || navigationController?.isBeingDismissed == true, entry != nil else { return }
        observations.removeAll()
        webView?.stopLoading()
        entry = nil
        feature.routes.release(target.id)
    }

    // MARK: Layout

    private func configureAddressField() {
        addressField.borderStyle = .roundedRect
        addressField.placeholder = WebText.addressPlaceholder
        addressField.keyboardType = .URL
        addressField.returnKeyType = .go
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.clearButtonMode = .whileEditing
        addressField.font = .preferredFont(forTextStyle: .subheadline)
        addressField.adjustsFontForContentSizeCategory = true
        addressField.delegate = self
        addressField.text = address.display
        addressField.accessibilityIdentifier = "web.address"
        navigationItem.titleView = addressField
    }

    private func configureStatus() {
        statusLabel.font = .preferredFont(forTextStyle: .callout)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        retryButton.configuration?.title = WebText.retry
        retryButton.addAction(UIAction { [weak self] _ in self?.reloadPage() }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [statusLabel, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = ShellMetrics.headerSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
        ])
        showStatus(nil)
    }

    private func showStatus(_ text: String?) {
        statusLabel.text = text
        statusLabel.isHidden = text == nil
        retryButton.isHidden = text == nil
        webView?.isHidden = text != nil
    }

    private func item(_ symbol: String, _ label: String, _ action: @escaping @MainActor () -> Void) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction { _ in action() })
        item.accessibilityLabel = label
        return item
    }

    // MARK: Route

    private func connect() {
        let target = target
        Task { [weak self] in
            let dialer: any TunnelDialer
            do {
                dialer = try await target.dialer()
            } catch {
                self?.showStatus(WebText.offline)
                return
            }
            guard let self, self.entry == nil else { return }
            let entry = self.feature.routes.acquire(target, dialer: dialer)
            self.entry = entry
            // The token cookie must be in the store before the first request.
            if let cookie = entry.route.cookie.httpCookie { await entry.store.httpCookieStore.setCookie(cookie) }
            self.makeWebView(store: entry.store)
            self.load(self.address)
        }
    }

    private func makeWebView(store: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(webView, at: 0)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.urlChanged(view.url) }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.backItem.isEnabled = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.forwardItem.isEnabled = view.canGoForward }
            },
        ]
        self.webView = webView
    }

    /// Opens (or reuses) the proxy for `address.port` and loads it.
    private func load(_ address: WebAddress) {
        guard let entry else { return }
        self.address = address
        addressField.text = address.display
        showStatus(nil)
        Task { [weak self] in
            do {
                let url = try await entry.route.url(remotePort: address.port, path: address.path, query: address.query)
                guard let self, let local = url.port.flatMap({ UInt16(exactly: $0) }) else { return }
                self.localPorts[local] = address.port
                self.webView?.load(URLRequest(url: url))
            } catch {
                self?.showStatus(WebText.loadFailed)
            }
        }
    }

    private func reloadPage() {
        if webView?.url == nil || !statusLabel.isHidden {
            load(address)
        } else {
            webView?.reload()
        }
    }

    private func urlChanged(_ url: URL?) {
        guard !addressField.isEditing, let url, let local = url.port.flatMap({ UInt16(exactly: $0) }),
              let remote = localPorts[local] else { return }
        let path = url.path.isEmpty ? "/" : url.path
        address = WebAddress(port: remote, path: path, query: URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        addressField.text = address.display
    }

    // MARK: Navigation

    // Completion-handler form: Xcode 26.6's compiler crashes emitting the ObjC
    // thunk for async delegate methods.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(policy(for: navigationAction))
    }

    private func policy(for navigationAction: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if ["about", "blob", "data"].contains(scheme) { return .allow }
        if let local = url.port.flatMap({ UInt16(exactly: $0) }), localPorts[local] != nil,
           let host = url.host, WebAddress.isLoopbackHost(host) {
            return .allow
        }
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if let tunnel = WebAddress(url: url) {
            // A loopback page on a port this route has not opened yet: open it, then load.
            if mainFrame { load(tunnel) }
            return .cancel
        }
        if mainFrame, scheme == "http" || scheme == "https", navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        showStatus(WebText.loadFailed)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        showStatus(nil)
    }

    // MARK: Address field

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        guard let text = textField.text, let typed = WebAddress(text) else {
            textField.text = address.display
            showStatus(WebText.notLocal)
            return false
        }
        load(typed)
        return false
    }
}
