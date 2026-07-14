import AppKit
import CmuxLiteCore

@MainActor
final class CmuxLiteWindowController: NSWindowController,
    NSWindowDelegate,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    private enum NavigationRequest {
        case workspace(UInt64)
        case screen(UInt64)
        case tab(pane: UInt64, index: Int)
        case newWorkspace
        case newScreen
        case newTab(pane: UInt64)
    }

    private let frontend: CmuxFrontendSession
    private let terminalHost: CmuxTerminalHostViewController
    private let workspaceTable = NSTableView()
    private let tabsStack = NSStackView()
    private let screensStack = NSStackView()
    private let sessionBadge = NSTextField(labelWithString: "")
    private var snapshot: CmuxFrontendStartup?
    private var connectionTask: Task<Void, Never>?
    private var navigationTask: Task<Void, Never>?
    private var applyingSelection = false

    init(
        frontend: CmuxFrontendSession,
        ghosttyViewConfiguration: CmuxGhosttyViewConfiguration,
        ghosttyConfigPath: String?
    ) {
        self.frontend = frontend
        terminalHost = CmuxTerminalHostViewController(
            frontend: frontend,
            ghosttyViewConfiguration: ghosttyViewConfiguration,
            ghosttyConfigPath: ghosttyConfigPath
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "app.title",
            defaultValue: "cmux-lite",
            bundle: .module
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = CmuxPalette.tui.background
        window.minSize = NSSize(width: 720, height: 420)
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
        setSessionBadge(
            String(
                localized: "status.connecting",
                defaultValue: "Connecting…",
                bundle: .module
            )
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
                    switch event {
                    case let .snapshot(snapshot):
                        apply(snapshot)
                    case let .terminal(event):
                        terminalHost.consume(event)
                        if case .detached = event {
                            setSessionBadge(
                                String(
                                    localized: "status.detached",
                                    defaultValue: "Surface detached",
                                    bundle: .module
                                )
                            )
                        }
                    }
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                showConnectionError(error)
            }
        }
    }

    func numberOfRows(in _: NSTableView) -> Int {
        snapshot?.workspaces.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard let workspace = snapshot?.workspaces[row] else { return nil }
        let view = tableView.makeView(
            withIdentifier: CmuxWorkspaceRowView.identifier,
            owner: self
        ) as? CmuxWorkspaceRowView ?? CmuxWorkspaceRowView(frame: .zero)
        view.configure(
            name: workspace.name,
            subtitle: workspace.subtitle ?? String(
                localized: "terminal.shell",
                defaultValue: "shell",
                bundle: .module
            ),
            active: workspace.id == snapshot?.selectedWorkspace
        )
        return view
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard !applyingSelection,
              let snapshot,
              workspaceTable.selectedRow >= 0,
              snapshot.workspaces.indices.contains(workspaceTable.selectedRow)
        else { return }
        runNavigation(.workspace(snapshot.workspaces[workspaceTable.selectedRow].id))
    }

    func windowWillClose(_: Notification) {
        navigationTask?.cancel()
        navigationTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        let frontend = frontend
        Task { await frontend.close() }
    }

    @objc
    private func newWorkspacePressed(_: NSButton) {
        runNavigation(.newWorkspace)
    }

    @objc
    private func newScreenPressed(_: NSButton) {
        runNavigation(.newScreen)
    }

    @objc
    private func newTabPressed(_: NSButton) {
        guard let pane = selectedScreen()?.pane else { return }
        runNavigation(.newTab(pane: pane))
    }

    @objc
    private func screenPressed(_ sender: NSButton) {
        guard let snapshot,
              let workspace = snapshot.workspaces.first(where: {
                $0.id == snapshot.selectedWorkspace
              }),
              workspace.screens.indices.contains(sender.tag)
        else { return }
        runNavigation(.screen(workspace.screens[sender.tag].id))
    }

    @objc
    private func tabPressed(_ sender: NSButton) {
        guard let screen = selectedScreen(), let pane = screen.pane,
              screen.tabs.indices.contains(sender.tag)
        else { return }
        runNavigation(.tab(pane: pane, index: sender.tag))
    }

    private func runNavigation(_ request: NavigationRequest) {
        navigationTask?.cancel()
        let frontend = frontend
        navigationTask = Task { [weak self] in
            do {
                let snapshot: CmuxFrontendStartup
                switch request {
                case let .workspace(id):
                    snapshot = try await frontend.selectWorkspace(id)
                case let .screen(id):
                    snapshot = try await frontend.selectScreen(id)
                case let .tab(pane, index):
                    snapshot = try await frontend.selectTab(pane: pane, index: index)
                case .newWorkspace:
                    snapshot = try await frontend.newWorkspace()
                case .newScreen:
                    snapshot = try await frontend.newScreen()
                case let .newTab(pane):
                    snapshot = try await frontend.newTab(pane: pane)
                }
                guard let self, !Task.isCancelled else { return }
                apply(snapshot)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                showConnectionError(error)
            }
        }
    }

    private func apply(_ snapshot: CmuxFrontendStartup) {
        self.snapshot = snapshot
        workspaceTable.reloadData()
        applyingSelection = true
        if let selectedRow = snapshot.workspaces.firstIndex(where: {
            $0.id == snapshot.selectedWorkspace
        }) {
            workspaceTable.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        } else {
            workspaceTable.deselectAll(nil)
        }
        applyingSelection = false
        rebuildTabs(snapshot)
        rebuildScreens(snapshot)
        setSessionBadge(snapshot.sessionName)
    }

    private func rebuildTabs(_ snapshot: CmuxFrontendStartup) {
        for view in tabsStack.arrangedSubviews {
            tabsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard let screen = selectedScreen(in: snapshot) else { return }
        for (index, tab) in screen.tabs.enumerated() {
            let number = String(index + 1)
            let accessibilityLabel = String(
                format: String(
                    localized: "tabs.unnamed",
                    defaultValue: "Tab %lld",
                    bundle: .module
                ),
                Int64(index + 1)
            )
            let button = CmuxTabButton(frame: .zero)
            button.tag = index
            button.target = self
            button.action = #selector(tabPressed(_:))
            button.setAccessibilityLabel(accessibilityLabel)
            button.toolTip = tab.label
            button.configure(label: number, active: screen.activeTab == index)
            tabsStack.addArrangedSubview(button)
        }

        guard screen.pane != nil else { return }
        let newTab = CmuxHoverButton(frame: .zero)
        newTab.target = self
        newTab.action = #selector(newTabPressed(_:))
        newTab.setAccessibilityLabel(
            String(localized: "tabs.new", defaultValue: "New tab", bundle: .module)
        )
        newTab.configure(
            title: "+",
            font: .systemFont(ofSize: 16),
            normalBackground: CmuxPalette.tui.statusBackground,
            normalForeground: CmuxPalette.tui.dim
        )
        newTab.translatesAutoresizingMaskIntoConstraints = false
        newTab.widthAnchor.constraint(equalToConstant: 34).isActive = true
        tabsStack.addArrangedSubview(newTab)
    }

    private func rebuildScreens(_ snapshot: CmuxFrontendStartup) {
        for view in screensStack.arrangedSubviews {
            screensStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let label = NSTextField(
            labelWithString: String(
                localized: "status.screens",
                defaultValue: "screens",
                bundle: .module
            )
        )
        label.font = .systemFont(ofSize: 11)
        label.textColor = CmuxPalette.tui.dim
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        screensStack.addArrangedSubview(label)

        guard let workspace = snapshot.workspaces.first(where: {
            $0.id == snapshot.selectedWorkspace
        }) else { return }

        for (index, screen) in workspace.screens.enumerated() {
            let button = CmuxHoverButton(frame: .zero)
            button.tag = index
            button.target = self
            button.action = #selector(screenPressed(_:))
            button.setAccessibilityLabel(
                String(
                    format: String(
                        localized: "status.screen_accessibility",
                        defaultValue: "Screen %lld",
                        bundle: .module
                    ),
                    Int64(index + 1)
                )
            )
            button.configure(
                title: String(index + 1),
                active: screen.id == snapshot.selectedScreen,
                font: .systemFont(
                    ofSize: 11,
                    weight: screen.id == snapshot.selectedScreen ? .bold : .regular
                ),
                normalForeground: CmuxPalette.tui.foreground
            )
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
            screensStack.addArrangedSubview(button)
        }

        let newScreen = CmuxHoverButton(frame: .zero)
        newScreen.target = self
        newScreen.action = #selector(newScreenPressed(_:))
        newScreen.setAccessibilityLabel(
            String(
                localized: "status.new_screen",
                defaultValue: "New screen",
                bundle: .module
            )
        )
        newScreen.configure(title: "+")
        newScreen.translatesAutoresizingMaskIntoConstraints = false
        newScreen.widthAnchor.constraint(equalToConstant: 30).isActive = true
        screensStack.addArrangedSubview(newScreen)
    }

    private func setSessionBadge(_ value: String) {
        sessionBadge.stringValue = "[\(value)]"
        sessionBadge.toolTip = value
    }

    private func selectedScreen(in value: CmuxFrontendStartup? = nil) -> CmuxScreenSnapshot? {
        guard let snapshot = value ?? snapshot,
              let workspace = snapshot.workspaces.first(where: {
                $0.id == snapshot.selectedWorkspace
              })
        else { return nil }
        return workspace.screens.first(where: { $0.id == snapshot.selectedScreen })
    }

    private func showConnectionError(_ error: Error) {
        let message = String(
            format: String(
                localized: "status.connection_failed",
                defaultValue: "Connection failed: %@",
                bundle: .module
            ),
            String(describing: error)
        )
        setSessionBadge(message)
    }

    private func configureContent() {
        guard let window else { return }
        let palette = CmuxPalette.tui
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = palette.background.cgColor

        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = palette.background.cgColor
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let sidebarBorder = NSView()
        sidebarBorder.wantsLayer = true
        sidebarBorder.layer?.backgroundColor = palette.border.cgColor
        sidebarBorder.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(
            labelWithString: String(
                localized: "sidebar.workspaces",
                defaultValue: "workspaces",
                bundle: .module
            )
        )
        heading.font = .systemFont(ofSize: 12)
        heading.textColor = palette.sidebarDim
        heading.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace"))
        column.resizingMask = .autoresizingMask
        workspaceTable.addTableColumn(column)
        workspaceTable.headerView = nil
        workspaceTable.dataSource = self
        workspaceTable.delegate = self
        workspaceTable.backgroundColor = palette.background
        workspaceTable.style = .plain
        workspaceTable.selectionHighlightStyle = .none
        workspaceTable.intercellSpacing = .zero
        workspaceTable.rowHeight = 36
        workspaceTable.focusRingType = .none

        let scroll = NSScrollView()
        scroll.documentView = workspaceTable
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let newWorkspace = CmuxHoverButton(frame: .zero)
        newWorkspace.target = self
        newWorkspace.action = #selector(newWorkspacePressed(_:))
        newWorkspace.configure(
            title: String(
                localized: "sidebar.new_workspace",
                defaultValue: "+ new workspace",
                bundle: .module
            ),
            alignment: .left,
            font: .systemFont(ofSize: 11),
            normalForeground: palette.sidebarDim,
            horizontalPadding: 6
        )
        newWorkspace.translatesAutoresizingMaskIntoConstraints = false

        let newWorkspaceBorder = NSView()
        newWorkspaceBorder.wantsLayer = true
        newWorkspaceBorder.layer?.backgroundColor = palette.hoverBackground.cgColor
        newWorkspaceBorder.translatesAutoresizingMaskIntoConstraints = false

        sidebar.addSubview(heading)
        sidebar.addSubview(scroll)
        sidebar.addSubview(newWorkspaceBorder)
        sidebar.addSubview(newWorkspace)
        sidebar.addSubview(sidebarBorder)

        let pane = NSView()
        pane.wantsLayer = true
        pane.layer?.backgroundColor = palette.background.cgColor
        pane.translatesAutoresizingMaskIntoConstraints = false

        let tabBar = NSView()
        tabBar.wantsLayer = true
        tabBar.layer?.backgroundColor = palette.statusBackground.cgColor
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        tabsStack.orientation = .horizontal
        tabsStack.alignment = .centerY
        tabsStack.spacing = 0
        tabsStack.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(tabsStack)

        let status = NSView()
        status.wantsLayer = true
        status.layer?.backgroundColor = palette.statusBackground.cgColor
        status.translatesAutoresizingMaskIntoConstraints = false

        screensStack.orientation = .horizontal
        screensStack.alignment = .centerY
        screensStack.spacing = 0
        screensStack.translatesAutoresizingMaskIntoConstraints = false

        sessionBadge.font = .systemFont(ofSize: 11)
        sessionBadge.textColor = palette.dim
        sessionBadge.lineBreakMode = .byTruncatingMiddle
        sessionBadge.alignment = .right
        sessionBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        sessionBadge.translatesAutoresizingMaskIntoConstraints = false

        status.addSubview(screensStack)
        status.addSubview(sessionBadge)
        pane.addSubview(tabBar)
        pane.addSubview(terminalHost.view)
        pane.addSubview(status)
        terminalHost.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        root.addSubview(pane)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 236),
            sidebarBorder.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarBorder.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            sidebarBorder.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarBorder.widthAnchor.constraint(equalToConstant: 1),
            heading.topAnchor.constraint(equalTo: sidebar.topAnchor),
            heading.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 6),
            heading.trailingAnchor.constraint(equalTo: sidebarBorder.leadingAnchor),
            heading.heightAnchor.constraint(equalToConstant: 24),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebarBorder.leadingAnchor),
            scroll.bottomAnchor.constraint(equalTo: newWorkspaceBorder.topAnchor),
            newWorkspaceBorder.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            newWorkspaceBorder.trailingAnchor.constraint(equalTo: sidebarBorder.leadingAnchor),
            newWorkspaceBorder.bottomAnchor.constraint(equalTo: newWorkspace.topAnchor),
            newWorkspaceBorder.heightAnchor.constraint(equalToConstant: 1),
            newWorkspace.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            newWorkspace.trailingAnchor.constraint(equalTo: sidebarBorder.leadingAnchor),
            newWorkspace.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            newWorkspace.heightAnchor.constraint(equalToConstant: 28),
            pane.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            pane.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pane.topAnchor.constraint(equalTo: root.topAnchor),
            pane.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: pane.topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 28),
            tabsStack.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor),
            tabsStack.topAnchor.constraint(equalTo: tabBar.topAnchor),
            tabsStack.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            tabsStack.trailingAnchor.constraint(lessThanOrEqualTo: tabBar.trailingAnchor),
            terminalHost.view.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            terminalHost.view.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            terminalHost.view.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            terminalHost.view.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 26),
            screensStack.leadingAnchor.constraint(equalTo: status.leadingAnchor),
            screensStack.topAnchor.constraint(equalTo: status.topAnchor),
            screensStack.bottomAnchor.constraint(equalTo: status.bottomAnchor),
            screensStack.trailingAnchor.constraint(lessThanOrEqualTo: sessionBadge.leadingAnchor, constant: -8),
            sessionBadge.trailingAnchor.constraint(equalTo: status.trailingAnchor, constant: -8),
            sessionBadge.centerYAnchor.constraint(equalTo: status.centerYAnchor),
        ])

        window.contentView = root
    }
}
