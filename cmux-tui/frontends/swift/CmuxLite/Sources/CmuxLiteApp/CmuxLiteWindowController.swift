import AppKit
import CmuxLiteCore

@MainActor
final class CmuxLiteWindowController: NSWindowController,
    NSWindowDelegate,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    private let frontend: CmuxFrontendSession
    private let terminalHost: CmuxTerminalHostViewController
    private let workspaceTable = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var workspaceNames: [String] = []
    private var connectionTask: Task<Void, Never>?

    init(frontend: CmuxFrontendSession) {
        self.frontend = frontend
        terminalHost = CmuxTerminalHostViewController(frontend: frontend)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "app.title", defaultValue: "cmux-lite")
        window.center()
        window.setFrameAutosaveName("cmux-lite-main")
        super.init(window: window)
        window.delegate = self
        configureContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func start(hostname: String) {
        statusLabel.stringValue = String(
            localized: "status.connecting",
            defaultValue: "Connecting…"
        )
        let frontend = frontend
        connectionTask = Task { [weak self] in
            do {
                let events = await frontend.events()
                let startup = try await frontend.connect(hostname: hostname)
                guard let self else { return }
                apply(startup)

                for await event in events {
                    guard !Task.isCancelled else { return }
                    await frontend.observe(event)
                    terminalHost.consume(event)
                    if case .detached = event {
                        statusLabel.stringValue = String(
                            localized: "status.detached",
                            defaultValue: "Surface detached"
                        )
                    }
                }
            } catch {
                guard let self else { return }
                statusLabel.stringValue = String(
                    format: String(
                        localized: "status.connection_failed",
                        defaultValue: "Connection failed: %@"
                    ),
                    String(describing: error)
                )
            }
        }
    }

    func numberOfRows(in _: NSTableView) -> Int {
        workspaceNames.count
    }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("workspace-name")
        let label: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            label = reused
        } else {
            label = NSTextField(labelWithString: "")
            label.identifier = identifier
            label.lineBreakMode = .byTruncatingTail
        }
        label.stringValue = workspaceNames[row]
        return label
    }

    func windowWillClose(_: Notification) {
        connectionTask?.cancel()
        connectionTask = nil
        let frontend = frontend
        Task { await frontend.close() }
    }

    private func apply(_ startup: CmuxFrontendStartup) {
        workspaceNames = startup.workspaceNames
        workspaceTable.reloadData()
        statusLabel.stringValue = String(
            format: String(
                localized: "status.connected",
                defaultValue: "Protocol %lld · surface %lld"
            ),
            Int64(startup.protocolVersion),
            Int64(startup.surface)
        )
    }

    private func configureContent() {
        guard let window else { return }

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin

        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let heading = NSTextField(
            labelWithString: String(
                localized: "sidebar.workspaces",
                defaultValue: "Workspaces"
            )
        )
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace"))
        workspaceTable.addTableColumn(column)
        workspaceTable.headerView = nil
        workspaceTable.dataSource = self
        workspaceTable.delegate = self
        workspaceTable.rowHeight = 24

        let scroll = NSScrollView()
        scroll.documentView = workspaceTable
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        sidebar.addSubview(heading)
        sidebar.addSubview(scroll)
        sidebar.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 14),
            heading.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            heading.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -6),
            statusLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -12),
        ])

        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(terminalHost.view)
        window.contentView = split
    }
}
