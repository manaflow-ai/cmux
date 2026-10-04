public import UIKit

/// One terminal on the phone: a ghostty-next surface fed by a
/// `TerminalSessionSource` under `terminal-snapshot-v1` (snapshot first, then
/// live bytes; see `TerminalStreamPipeline`). Typed input goes to the source
/// as ordered, attributed input (nothing queues offline).
@MainActor
public final class TerminalViewController: UIViewController {
    let source: any TerminalSessionSource
    let terminal: TerminalRef
    let terminalView = GhosttyTerminalView(frame: .zero)
    let badge = UILabel()
    /// Throttle retries sleep on this clock (injected; tests use a manual one).
    let clock: any Clock<Duration>
    var stream: Task<Void, Never>?
    var retry: Task<Void, Never>?
    /// The pending READY deadline (cancelled by a newer one or detach).
    var readyDeadline: Task<Void, Never>?
    var pipeline: TerminalStreamPipeline?
    var pathText: String?
    var notice: String?
    var streamStats = TerminalStreamStats()

    public init(source: any TerminalSessionSource, terminal: TerminalRef,
                clock: any Clock<Duration> = ContinuousClock()) {
        self.source = source
        self.terminal = terminal
        self.clock = clock
        super.init(nibName: nil, bundle: nil)
        title = terminal.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)
        badge.font = .preferredFont(forTextStyle: .caption2)
        badge.adjustsFontForContentSizeCategory = true
        badge.textColor = .secondaryLabel
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: badge)
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            // The keyboard never changes the grid's rows (ghostty-next section 6);
            // the view keeps its height and the keyboard covers the bottom.
            terminalView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        let source = self.source
        let terminal = self.terminal
        terminalView.onInput = { data in
            Task { try? await source.send(data, to: terminal) }
        }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        attach()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        detach()
    }

    /// DEBUG diagnostics of the surface and the stream.
    public var diagnostics: [String: String] {
        terminalView.diagnostics.merging(streamStats.diagnostics) { _, stream in stream }
    }

    /// Shows the keyboard (user action only).
    public func focusInput() { terminalView.becomeFirstResponder() }
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
