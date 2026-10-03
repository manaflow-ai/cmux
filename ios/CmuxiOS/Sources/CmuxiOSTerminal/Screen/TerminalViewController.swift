public import UIKit

/// One terminal on the phone: a ghostty-next surface fed by a
/// `TerminalSessionSource`. Output bytes go to the renderer; typed input goes
/// to the source as ordered, attributed input (nothing queues offline).
@MainActor
public final class TerminalViewController: UIViewController {
    private let source: any TerminalSessionSource
    private let terminal: TerminalRef
    private let terminalView = GhosttyTerminalView(frame: .zero)
    private let badge = UILabel()
    private var stream: Task<Void, Never>?

    public init(source: any TerminalSessionSource, terminal: TerminalRef) {
        self.source = source
        self.terminal = terminal
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
        stream?.cancel()
        stream = nil
        let source = self.source
        let terminal = self.terminal
        Task { await source.detach(terminal) }
    }

    /// DEBUG diagnostics of the surface.
    public var diagnostics: [String: String] { terminalView.diagnostics }

    /// Shows the keyboard (user action only).
    public func focusInput() { terminalView.becomeFirstResponder() }

    private func attach() {
        guard stream == nil else { return }
        let source = self.source
        let terminal = self.terminal
        stream = Task { [weak self] in
            guard let events = try? await source.attach(terminal) else { return }
            for await event in events {
                guard let self else { return }
                self.apply(event)
            }
        }
        let grid = terminalView.fittingGrid
        Task { await source.setPresence(terminal, visible: true, cols: grid.cols, rows: grid.rows) }
    }

    private func apply(_ event: TerminalChannelEvent) {
        switch event {
        case .snapshot(let bytes, let cols, let rows):
            terminalView.reset(snapshot: bytes, cols: cols, rows: rows)
        case .bytes(let bytes):
            terminalView.feed(bytes)
        case .resized:
            break // the host follows every grid change with a snapshot
        case .path(let path, _):
            badge.text = path.label
            badge.sizeToFit()
        case .kicked(let name):
            badge.text = String(format: String(localized: "terminal.kicked", defaultValue: "Disconnected by %@", bundle: .module), name)
            badge.sizeToFit()
        case .closed:
            badge.text = String(localized: "terminal.closed", defaultValue: "Closed", bundle: .module)
            badge.sizeToFit()
        }
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
