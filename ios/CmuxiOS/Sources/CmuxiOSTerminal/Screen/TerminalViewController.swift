public import CmuxTerminalRenderCore
public import CmuxTheme
public import UIKit

/// One terminal on the phone: a ghostty-next surface fed by any
/// `TerminalByteSource` through a `TerminalSession` (the cmux session host
/// under `terminal-snapshot-v1`, an SSH channel, a fixture). Typed input goes
/// to the source as ordered, attributed input (nothing queues offline).
@MainActor
public final class TerminalViewController: UIViewController {
    public let session: TerminalSession
    var terminalView: GhosttyTerminalView { session.view }
    let badge = UILabel()
    let banner = TerminalConnectionBanner()
    /// The More menu's button (rebuilt when the history state changes).
    var moreButton: UIBarButtonItem?
    /// Invisible; its bottom is the keyboard's top. A view, so a keyboard
    /// move runs `viewDidLayoutSubviews` inside the keyboard's animation.
    private let keyboardTop = UIView()
    /// The device's terminal settings (theme, font, cursor, key bar); nil
    /// keeps the renderer defaults.
    private let appearanceOwner: (any TerminalAppearanceProviding)?
    /// The theme the terminal was opened with; Settings' "Match Mac" keeps it.
    private let openedTheme: ThemeInput?
    private var appearanceTask: Task<Void, Never>?
    /// The composer bar's maker (E4); nil offers no composer.
    public var composerProvider: (any TerminalComposerProviding)? {
        didSet { if isViewLoaded { setComposerVisible(showsComposer) } }
    }
    /// The More menu toggled the bar: the owner writes the setting.
    public var onComposerToggle: ((Bool) -> Void)?
    /// Whether composed input is accepted changed (the bar's Send state).
    public var onComposedInputAvailabilityChange: ((Bool) -> Void)?
    /// The setting's value (or the menu's), applied once the view loads.
    var showsComposer = false
    var composerController: UIViewController?

    /// A terminal of a cmux session host through the transport seam.
    public convenience init(source: any TerminalSessionSource, terminal: TerminalRef,
                            appearance: (any TerminalAppearanceProviding)? = nil,
                            clock: any Clock<Duration> = ContinuousClock()) {
        self.init(source: SessionTerminalByteSource(source: source, terminal: terminal), title: terminal.title,
                  appearance: appearance, clock: clock)
    }

    /// A terminal fed by any byte source.
    public init(source: any TerminalByteSource, title: String?, theme: ThemeInput? = nil,
                appearance: (any TerminalAppearanceProviding)? = nil,
                clock: any Clock<Duration> = ContinuousClock()) {
        let view = GhosttyTerminalView(authority: source.authority)
        view.theme = theme
        openedTheme = theme
        appearanceOwner = appearance
        session = TerminalSession(source: source, view: view, clock: clock)
        super.init(nibName: nil, bundle: nil)
        self.title = title
        if let appearance { apply(appearance.appearance) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = terminalView.backgroundColor
        view.accessibilityIdentifier = "terminal.screen"
        terminalView.accessibilityIdentifier = "terminal.view"
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)
        badge.font = .preferredFont(forTextStyle: .caption2)
        badge.adjustsFontForContentSizeCategory = true
        badge.textColor = .secondaryLabel
        navigationItem.rightBarButtonItems = [moreItem(), UIBarButtonItem(customView: badge)]
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            // The keyboard never changes the grid's rows (ghostty-next section 6);
            // the view keeps its height and the keyboard covers the bottom.
            terminalView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        banner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])
        keyboardTop.isHidden = true
        keyboardTop.isUserInteractionEnabled = false
        keyboardTop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardTop)
        NSLayoutConstraint.activate([
            keyboardTop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardTop.widthAnchor.constraint(equalToConstant: 1),
            keyboardTop.heightAnchor.constraint(equalToConstant: 1),
            keyboardTop.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        // A tap that is not a link shows the keyboard (a user action; nothing else focuses the terminal).
        terminalView.onTap = { [weak self] in self?.focusInput() }
        terminalView.onDraw = { [weak self] in self?.panToCursor() }
        session.onStatus = { [weak self] status in self?.show(status) }
        setComposerVisible(showsComposer)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        session.start()
        followAppearance()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session.stop()
        appearanceTask?.cancel()
        appearanceTask = nil
    }

    /// Follows Settings while visible, so a change made in another tab
    /// reaches this terminal when it shows again (and live on iPad).
    private func followAppearance() {
        guard let appearanceOwner, appearanceTask == nil else { return }
        let updates = appearanceOwner.appearanceUpdates()
        appearanceTask = Task { [weak self] in
            for await appearance in updates {
                self?.apply(appearance)
            }
        }
    }

    /// Applies the device's terminal settings to the surface.
    public func apply(_ appearance: TerminalAppearance) {
        terminalView.theme = appearance.theme ?? openedTheme
        terminalView.fontFamily = appearance.fontFamily
        terminalView.cursorStyle = appearance.cursorStyle
        terminalView.cursorBlink = appearance.cursorBlink
        terminalView.followsDynamicType = appearance.followsDynamicType
        let sizing = appearance.fontSizing(from: terminalView.fontSizing)
        if sizing != terminalView.fontSizing { terminalView.fontSizing = sizing }
        terminalView.keyBarKeys = TerminalKeyBarKey.keys(fromSetting: appearance.keyBarKeyIDs)
        if isViewLoaded { view.backgroundColor = terminalView.backgroundColor }
        if appearance.showsComposer != showsComposer { setComposerVisible(appearance.showsComposer) }
    }

    public override var keyCommands: [UIKeyCommand]? { terminalKeyCommands() }

    /// DEBUG diagnostics of the surface and the stream.
    public var diagnostics: [String: String] { session.diagnostics }

    /// Shows the keyboard (user action only).
    public func focusInput() { terminalView.becomeFirstResponder() }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        panToCursor()
    }

    /// The keyboard never changes the grid (D8): while it covers the cursor
    /// row, the terminal moves up just enough to show that row above the
    /// keyboard and its key bar. Inside the keyboard's animation the move
    /// rides its curve; after output it is immediate.
    private func panToCursor() {
        let cursor = terminalView.cursorRect
        guard cursor.height > 0 else { return }
        // The resting top (center and bounds ignore the transform).
        let restingTop = terminalView.center.y - terminalView.bounds.height / 2
        let cursorBottom = restingTop + cursor.maxY + Self.cursorMargin
        let coverTop = min(keyboardTop.frame.maxY, bottomObstructionTop ?? .greatestFiniteMagnitude)
        let shift = max(0, cursorBottom - coverTop)
        let transform = CGAffineTransform(translationX: 0, y: -shift)
        if terminalView.transform != transform { terminalView.transform = transform }
    }

    static let cursorMargin: CGFloat = 4

    private func show(_ status: TerminalSessionStatus) {
        let notice: String? = switch status.notice {
        case .kicked(let name):
            String(format: String(localized: "terminal.kicked", defaultValue: "Disconnected by %@", bundle: .module), name)
        case .closed: String(localized: "terminal.closed", defaultValue: "Closed", bundle: .module)
        case .byteReplay: String(localized: "terminal.replay", defaultValue: "Byte replay", bundle: .module)
        case nil: nil
        }
        let chrome = status.chrome
        badge.text = [chrome.badge.map(Self.badgeText), notice].compactMap { $0 }.joined(separator: " · ")
        badge.textColor = chrome.badge?.isEmphasized == true ? .label : .secondaryLabel
        badge.accessibilityLabel = chrome.badge.map(Self.badgeAccessibilityText)
        badge.sizeToFit()
        banner.show(chrome.banner)
        refreshMenu()
        notifyComposerAvailability()
        if let title = status.title, !title.isEmpty { self.title = title }
    }
}

extension TerminalViewController {
    /// "Direct", or "Relayed · 140 ms" when the path is relayed or slow.
    static func badgeText(_ badge: TerminalChrome.Badge) -> String {
        guard let rtt = badge.rttMilliseconds else { return badge.path.label }
        let format = String(localized: "terminal.badge.rtt", defaultValue: "%1$@ · %2$lld ms", bundle: .module)
        return String(format: format, badge.path.label, rtt)
    }

    static func badgeAccessibilityText(_ badge: TerminalChrome.Badge) -> String {
        guard let rtt = badge.rttMilliseconds else {
            let format = String(localized: "terminal.badge.a11y", defaultValue: "%@ path", bundle: .module)
            return String(format: format, badge.path.label)
        }
        let format = String(localized: "terminal.badge.a11y.rtt", defaultValue: "%1$@ path, %2$lld milliseconds", bundle: .module)
        return String(format: format, badge.path.label, rtt)
    }
}

extension TerminalPath {
    /// The badge text; a relayed path never reads as direct.
    var label: String {
        switch self {
        case .lan: String(localized: "terminal.path.lan", defaultValue: "LAN", bundle: .module)
        case .direct: String(localized: "terminal.path.direct", defaultValue: "Direct", bundle: .module)
        case .viaCloudRegion: String(localized: "terminal.path.cloud", defaultValue: "Via cloud region", bundle: .module)
        case .relayed: String(localized: "terminal.path.relayed", defaultValue: "Relayed", bundle: .module)
        }
    }
}
