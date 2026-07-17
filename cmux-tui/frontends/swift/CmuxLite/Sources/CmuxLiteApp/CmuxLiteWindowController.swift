import AppKit
import CmuxLiteCore

@MainActor
final class CmuxLiteWindowController: NSWindowController,
    NSWindowDelegate,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    private let frontend: CmuxFrontendSession
    private let ghosttyViewConfiguration: CmuxGhosttyViewConfiguration
    private let shortcutTable = CmuxShortcutTable()
    private let workspaceTable = NSTableView()
    private let screensStack = NSStackView()
    private let sessionBadge = NSTextField(labelWithString: "")
    private let paneLayoutHost = NSView()
    private var paneControllers: [UInt64: CmuxPaneViewController] = [:]
    private var snapshot: CmuxFrontendStartup?
    private var activePane: UInt64?
    private var pendingRatios: [CmuxSplitTarget: CmuxPendingRatio] = [:]
    private var nextRatioRequestID: UInt64 = 1
    private var connectionTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var applyingSelection = false

    init(
        frontend: CmuxFrontendSession,
        ghosttyViewConfiguration: CmuxGhosttyViewConfiguration
    ) {
        self.frontend = frontend
        self.ghosttyViewConfiguration = ghosttyViewConfiguration

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
        installEventMonitors()
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
                apply(startup, preferServerActivePane: true)

                for await event in events {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case let .snapshot(snapshot):
                        apply(snapshot)
                    case let .terminal(event):
                        route(event)
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
        runMutation(.workspace(snapshot.workspaces[workspaceTable.selectedRow].id))
    }

    func windowWillClose(_: Notification) {
        removeEventMonitors()
        mutationTask?.cancel()
        mutationTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        let frontend = frontend
        Task { await frontend.close() }
    }

    @objc
    private func newWorkspacePressed(_: NSButton) {
        perform(.newWorkspace)
    }

    @objc
    private func newScreenPressed(_: NSButton) {
        guard let activePane else { return }
        runMutation(.newScreen(pane: activePane))
    }

    @objc
    private func screenPressed(_ sender: NSButton) {
        guard let workspace = selectedWorkspace(),
              workspace.screens.indices.contains(sender.tag)
        else { return }
        runMutation(.screen(workspace.screens[sender.tag].id))
    }

    private func perform(_ action: CmuxShortcutAction) {
        switch action {
        case let .split(direction):
            guard let activePane else { return }
            runMutation(.split(pane: activePane, direction: direction))
        case .newTab:
            guard let activePane else { return }
            runMutation(.newTab(pane: activePane))
        case .closeTab:
            guard let pane = activePaneSnapshot(), let surface = pane.activeSurface else { return }
            runMutation(.closeTab(surface: surface))
        case .newWorkspace:
            guard let activePane else { return }
            runMutation(.newWorkspace(pane: activePane))
        case let .selectTab(index):
            guard let pane = activePaneSnapshot(), pane.tabs.indices.contains(index) else { return }
            runMutation(.selectTab(pane: pane.id, index: index))
        case let .selectScreen(index):
            guard let workspace = selectedWorkspace(), workspace.screens.indices.contains(index) else {
                return
            }
            runMutation(.screen(workspace.screens[index].id))
        case let .focusPane(direction):
            focusPane(toward: direction)
        case let .resizePane(direction):
            resizePane(toward: direction)
        }
    }

    private func runMutation(_ mutation: CmuxWindowMutation) {
        mutationTask?.cancel()
        let frontend = frontend
        mutationTask = Task { [weak self] in
            do {
                let updated: CmuxFrontendStartup
                switch mutation {
                case let .workspace(id):
                    updated = try await frontend.selectWorkspace(id)
                case let .screen(id):
                    updated = try await frontend.selectScreen(id)
                case let .newWorkspace(pane):
                    updated = try await frontend.newWorkspace(pane: pane)
                case let .newScreen(pane):
                    updated = try await frontend.newScreen(pane: pane)
                case let .selectTab(pane, index):
                    updated = try await frontend.selectTab(pane: pane, index: index)
                case let .newTab(pane):
                    updated = try await frontend.newTab(pane: pane)
                case let .split(pane, direction):
                    updated = try await frontend.split(pane: pane, direction: direction)
                case let .closeTab(surface):
                    updated = try await frontend.closeTab(surface: surface)
                case let .setRatio(target, ratio, _):
                    updated = try await frontend.setRatio(target: target, ratio: ratio)
                }
                guard let self, !Task.isCancelled else { return }
                apply(updated, preferServerActivePane: mutation.followsServerActivePane)
            } catch is CancellationError {
                guard let self else { return }
                rollbackPendingRatio(for: mutation)
            } catch {
                guard let self, !Task.isCancelled else { return }
                rollbackPendingRatio(for: mutation)
                showConnectionError(error)
            }
        }
    }

    private func apply(
        _ snapshot: CmuxFrontendStartup,
        preferServerActivePane: Bool = false
    ) {
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

        guard let screen = selectedScreen(in: snapshot) else {
            clearPaneLayout()
            rebuildScreens(snapshot)
            setSessionBadge(snapshot.sessionName)
            return
        }
        reconcilePendingRatios(with: screen.layout)
        let visible = screen.layout.paneIDs
        if preferServerActivePane, let serverPane = screen.activePane, visible.contains(serverPane) {
            activePane = serverPane
        } else if let activePane, visible.contains(activePane) {
            self.activePane = activePane
        } else if let serverPane = screen.activePane, visible.contains(serverPane) {
            activePane = serverPane
        } else {
            activePane = visible.first
        }
        rebuildPaneLayout(screen)
        rebuildScreens(snapshot)
        setSessionBadge(snapshot.sessionName)
    }

    private func rebuildPaneLayout(_ screen: CmuxScreenSnapshot) {
        let visible = Set(screen.layout.paneIDs)
        for pane in paneControllers.keys where !visible.contains(pane) {
            paneControllers[pane]?.view.removeFromSuperview()
            paneControllers.removeValue(forKey: pane)
        }
        for paneID in screen.layout.paneIDs {
            guard let pane = screen.panes.first(where: { $0.id == paneID }) else { continue }
            let controller: CmuxPaneViewController
            if let existing = paneControllers[paneID] {
                controller = existing
            } else {
                controller = CmuxPaneViewController(
                    snapshot: pane,
                    frontend: frontend,
                    ghosttyViewConfiguration: ghosttyViewConfiguration
                )
                controller.onActivate = { [weak self] pane in
                    self?.activatePane(pane)
                }
                controller.onSelectTab = { [weak self] pane, index in
                    self?.activatePane(pane, focus: false)
                    self?.perform(.selectTab(index))
                }
                controller.onNewTab = { [weak self] pane in
                    self?.activatePane(pane, focus: false)
                    self?.perform(.newTab)
                }
                paneControllers[paneID] = controller
            }
            controller.update(snapshot: pane, active: paneID == activePane)
        }

        paneLayoutHost.subviews.forEach { $0.removeFromSuperview() }
        guard let root = makeLayoutView(screen.layout) else { return }
        root.frame = paneLayoutHost.bounds
        root.autoresizingMask = [.width, .height]
        paneLayoutHost.addSubview(root)
        paneControllers[activePane ?? 0]?.focusTerminal()
    }

    private func makeLayoutView(_ layout: CmuxPaneLayoutView) -> NSView? {
        switch layout {
        case let .pane(pane):
            return paneControllers[pane]?.view
        case let .group(direction, ratio, first, second):
            guard let firstView = makeLayoutView(first),
                  let secondView = makeLayoutView(second)
            else { return nil }
            let target = layout.dividerTarget()
            let pending = target.flatMap { pendingRatios[$0] }
            let pendingValid = pending.map {
                abs(ratio - $0.previousRatio) <= 0.000_001
            } ?? false
            return CmuxSplitView(
                direction: direction,
                authoritativeRatio: ratio,
                displayedRatio: pendingValid ? (pending?.ratio ?? ratio) : ratio,
                target: target,
                pending: pendingValid,
                first: firstView,
                second: secondView,
                onCommit: { [weak self] target, previous, ratio in
                    self?.beginRatioCommit(
                        target: target,
                        previousRatio: previous,
                        ratio: ratio
                    )
                }
            )
        }
    }

    private func clearPaneLayout() {
        paneLayoutHost.subviews.forEach { $0.removeFromSuperview() }
        paneControllers.removeAll()
        activePane = nil
    }

    private func activatePane(_ pane: UInt64, focus: Bool = true) {
        guard let screen = selectedScreen(), screen.layout.paneIDs.contains(pane) else { return }
        activePane = pane
        for paneSnapshot in screen.panes where screen.layout.paneIDs.contains(paneSnapshot.id) {
            paneControllers[paneSnapshot.id]?.update(
                snapshot: paneSnapshot,
                active: paneSnapshot.id == pane
            )
        }
        if focus {
            paneControllers[pane]?.focusTerminal()
        }
    }

    private func focusPane(toward direction: CmuxPaneDirection) {
        guard let screen = selectedScreen(), let activePane else { return }
        let geometry = CmuxPaneGeometry(layout: screen.layout)
        guard let neighbor = geometry.neighbor(of: activePane, toward: direction) else { return }
        activatePane(neighbor)
    }

    private func resizePane(toward direction: CmuxPaneDirection) {
        guard let screen = selectedScreen(), let activePane,
              let nudge = screen.layout.ratioNudge(for: activePane, toward: direction),
              let previous = screen.layout.ratio(for: nudge.target),
              abs(previous - nudge.ratio) > 0.000_001
        else { return }
        beginRatioCommit(
            target: nudge.target,
            previousRatio: previous,
            ratio: nudge.ratio
        )
    }

    private func beginRatioCommit(
        target: CmuxSplitTarget,
        previousRatio: Double,
        ratio: Double
    ) {
        guard pendingRatios[target] == nil else { return }
        let requestID = nextRatioRequestID
        nextRatioRequestID &+= 1
        pendingRatios[target] = CmuxPendingRatio(
            requestID: requestID,
            previousRatio: previousRatio,
            ratio: ratio
        )
        if let screen = selectedScreen() {
            rebuildPaneLayout(screen)
        }
        runMutation(.setRatio(target: target, ratio: ratio, requestID: requestID))
    }

    private func reconcilePendingRatios(with layout: CmuxPaneLayoutView) {
        var reconciledTargets: [CmuxSplitTarget] = []
        for (target, pending) in pendingRatios {
            guard let authoritative = layout.ratio(for: target),
                  abs(authoritative - pending.previousRatio) <= 0.000_001
            else {
                reconciledTargets.append(target)
                continue
            }
        }
        for target in reconciledTargets {
            pendingRatios.removeValue(forKey: target)
        }
    }

    private func rollbackPendingRatio(for mutation: CmuxWindowMutation) {
        guard case let .setRatio(target, _, requestID) = mutation,
              pendingRatios[target]?.requestID == requestID
        else { return }
        pendingRatios.removeValue(forKey: target)
        if let screen = selectedScreen() {
            rebuildPaneLayout(screen)
        }
    }

    private func route(_ event: CmuxAttachEvent) {
        guard let surface = event.surface,
              let screen = selectedScreen(),
              let pane = screen.panes.first(where: { $0.activeSurface == surface })
        else { return }
        paneControllers[pane.id]?.consume(event)
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

        guard let workspace = selectedWorkspace(in: snapshot) else { return }
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

    private func selectedWorkspace(
        in value: CmuxFrontendStartup? = nil
    ) -> CmuxWorkspaceSnapshot? {
        guard let snapshot = value ?? snapshot else { return nil }
        return snapshot.workspaces.first(where: { $0.id == snapshot.selectedWorkspace })
    }

    private func selectedScreen(in value: CmuxFrontendStartup? = nil) -> CmuxScreenSnapshot? {
        guard let snapshot = value ?? snapshot,
              let workspace = selectedWorkspace(in: snapshot)
        else { return nil }
        return workspace.screens.first(where: { $0.id == snapshot.selectedScreen })
    }

    private func activePaneSnapshot() -> CmuxPaneSnapshot? {
        guard let screen = selectedScreen(), let activePane else { return nil }
        return screen.panes.first(where: { $0.id == activePane })
    }

    private func setSessionBadge(_ value: String) {
        sessionBadge.stringValue = "[\(value)]"
        sessionBadge.toolTip = value
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

    private func installEventMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === window,
                  let input = event.cmuxShortcutInput,
                  let action = shortcutTable.action(for: input)
            else { return event }
            perform(action)
            return nil
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, event.window === window else { return event }
            for (pane, controller) in paneControllers {
                if controller.containsTerminal(pointInWindow: event.locationInWindow) {
                    activatePane(pane, focus: false)
                    break
                }
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
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
        scroll.focusRingType = .none
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

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = palette.background.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false

        paneLayoutHost.wantsLayer = true
        paneLayoutHost.layer?.backgroundColor = palette.background.cgColor
        paneLayoutHost.translatesAutoresizingMaskIntoConstraints = false

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
        content.addSubview(paneLayoutHost)
        content.addSubview(status)
        root.addSubview(sidebar)
        root.addSubview(content)

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
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            paneLayoutHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            paneLayoutHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            paneLayoutHost.topAnchor.constraint(equalTo: content.topAnchor),
            paneLayoutHost.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 26),
            screensStack.leadingAnchor.constraint(equalTo: status.leadingAnchor),
            screensStack.topAnchor.constraint(equalTo: status.topAnchor),
            screensStack.bottomAnchor.constraint(equalTo: status.bottomAnchor),
            screensStack.trailingAnchor.constraint(
                lessThanOrEqualTo: sessionBadge.leadingAnchor,
                constant: -8
            ),
            sessionBadge.trailingAnchor.constraint(equalTo: status.trailingAnchor, constant: -8),
            sessionBadge.centerYAnchor.constraint(equalTo: status.centerYAnchor),
        ])

        window.contentView = root
    }
}
