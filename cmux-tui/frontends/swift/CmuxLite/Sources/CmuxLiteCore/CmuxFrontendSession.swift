import Foundation

/// Orchestrates local navigation, visible-pane render attachments, input, and sizing.
public actor CmuxFrontendSession {
    private let controlClient: CmuxProtocolClient
    private let attachmentClientFactory: any CmuxProtocolClientFactory
    private let configuration: CmuxConnectionConfiguration
    private let resizeDebounce: Duration
    private let resizePolicy = CmuxResizePolicy()
    private let eventStream: AsyncStream<CmuxFrontendEvent>
    private let eventContinuation: AsyncStream<CmuxFrontendEvent>.Continuation

    private var tree: CmuxWorkspaceTree?
    private var selection: CmuxLocalSelection?
    private var hostname: String?
    private var protocolVersion: UInt32?
    private var sessionName: String?
    private var attachments: [UInt64: CmuxPaneAttachment] = [:]
    private var nextAttachmentGeneration: UInt64 = 1
    private var controlTask: Task<Void, Never>?

    /// Creates a frontend session from injected protocol pieces.
    /// - Parameters:
    ///   - client: The long-lived command and tree-event client.
    ///   - attachmentClientFactory: A factory for one disposable client per surface attachment.
    ///   - configuration: Resolved transport endpoint and optional WebSocket token.
    ///   - resizeDebounce: The bounded per-pane resize coalescing delay.
    public init(
        client: CmuxProtocolClient,
        attachmentClientFactory: any CmuxProtocolClientFactory,
        configuration: CmuxConnectionConfiguration,
        resizeDebounce: Duration = .milliseconds(100)
    ) {
        controlClient = client
        self.attachmentClientFactory = attachmentClientFactory
        self.configuration = configuration
        self.resizeDebounce = resizeDebounce
        let pair = AsyncStream<CmuxFrontendEvent>.makeStream(bufferingPolicy: .unbounded)
        eventStream = pair.stream
        eventContinuation = pair.continuation
    }

    /// Connects, requires protocol 7+, and render-attaches every visible PTY pane.
    /// - Parameters:
    ///   - hostname: The client name reported to cmux-tui.
    ///   - preferredSurface: An optional surface used to initialize local navigation.
    /// - Returns: The selected tree and visible attachment summary.
    public func connect(
        hostname: String,
        preferredSurface: UInt64? = nil
    ) async throws -> CmuxFrontendStartup {
        try await controlClient.connect(token: configuration.token)
        let identify = try await controlClient.identify()
        guard identify.app == "cmux-tui", identify.protocol >= 7 else {
            throw CmuxProtocolError.incompatibleServer(
                String(
                    format: String(
                        localized: "frontend.error.render_protocol_required",
                        defaultValue: "Render mode requires cmux-tui protocol 7 or newer; server reported %@ protocol %lld",
                        bundle: .module
                    ),
                    identify.app,
                    Int64(identify.protocol)
                )
            )
        }

        try await controlClient.setClientInfo(name: hostname, kind: "swift")
        let tree = try await controlClient.listWorkspaces()
        guard let selection = CmuxLocalSelection(tree: tree, preferredSurface: preferredSurface),
              !tree.visiblePaneSurfaces(selection: selection).isEmpty
        else {
            throw CmuxProtocolError.noActivePTYSurface
        }

        self.hostname = hostname
        protocolVersion = identify.protocol
        sessionName = identify.session
        self.tree = tree
        self.selection = selection

        let controlEvents = await controlClient.events()
        try await controlClient.subscribe()
        startControlLoop(events: controlEvents)
        try await reconcileAttachments()

        guard let snapshot = currentSnapshot() else {
            throw CmuxProtocolError.transportState("frontend snapshot unavailable after connect")
        }
        return snapshot
    }

    /// Returns ordered frontend state and per-surface terminal events.
    /// - Returns: A stable stream spanning visible attachment changes.
    public func events() -> AsyncStream<CmuxFrontendEvent> {
        eventStream
    }

    /// Selects a workspace only for this client and reconciles its visible attachments.
    /// - Parameter workspace: The workspace identifier.
    /// - Returns: The updated local navigation snapshot.
    public func selectWorkspace(_ workspace: UInt64) async throws -> CmuxFrontendStartup {
        guard let tree, var selection, selection.selectWorkspace(workspace, in: tree) else {
            throw CmuxProtocolError.command("workspace \(workspace) is unavailable")
        }
        self.selection = selection
        return try await attachSelectionAndPublish()
    }

    /// Selects a screen only for this client and reconciles its visible attachments.
    /// - Parameter screen: The screen identifier in the locally selected workspace.
    /// - Returns: The updated local navigation snapshot.
    public func selectScreen(_ screen: UInt64) async throws -> CmuxFrontendStartup {
        guard let tree, var selection, selection.selectScreen(screen, in: tree) else {
            throw CmuxProtocolError.command("screen \(screen) is unavailable")
        }
        self.selection = selection
        return try await attachSelectionAndPublish()
    }

    /// Creates a workspace at the active pane's current grid and follows its returned surface.
    /// - Parameter pane: The active pane whose grid seeds the new surface.
    /// - Returns: The updated local navigation snapshot.
    public func newWorkspace(pane: UInt64) async throws -> CmuxFrontendStartup {
        let created = try await controlClient.newWorkspace(size: try creationSize(for: pane))
        return try await followCreatedSurface(created.surface)
    }

    /// Creates a screen at the active pane's current grid and follows it locally.
    /// - Parameter pane: The active pane whose grid seeds the new surface.
    /// - Returns: The updated local navigation snapshot.
    public func newScreen(pane: UInt64) async throws -> CmuxFrontendStartup {
        guard let selection else {
            throw CmuxProtocolError.transportState("no locally selected workspace")
        }
        let created = try await controlClient.newScreen(
            workspace: selection.workspaceID,
            size: try creationSize(for: pane)
        )
        return try await followCreatedSurface(created.surface)
    }

    /// Selects a tab in any visible pane and reconciles that pane's attachment.
    /// - Parameters:
    ///   - pane: The target pane identifier.
    ///   - index: The zero-based tab index.
    /// - Returns: The refreshed navigation and attachment snapshot.
    public func selectTab(pane: UInt64, index: Int) async throws -> CmuxFrontendStartup {
        guard let selectedPane = selectedPane(pane),
              selectedPane.tabs.indices.contains(index)
        else {
            throw CmuxProtocolError.command(String(
                format: String(
                    localized: "frontend.error.tab_unavailable",
                    defaultValue: "Tab %1$lld in pane %2$lld is unavailable",
                    bundle: .module
                ),
                Int64(index + 1),
                Int64(pane)
            ))
        }
        try await controlClient.selectTab(pane: pane, index: index)
        return try await refreshTreeAndPublish()
    }

    /// Creates a tab in a visible pane and follows its returned surface.
    /// - Parameter pane: The target pane identifier.
    /// - Returns: The refreshed navigation and attachment snapshot.
    public func newTab(pane: UInt64) async throws -> CmuxFrontendStartup {
        guard selectedPane(pane) != nil else {
            throw CmuxProtocolError.command(String(
                format: String(
                    localized: "frontend.error.pane_unavailable",
                    defaultValue: "Pane %lld is unavailable",
                    bundle: .module
                ),
                Int64(pane)
            ))
        }
        let created = try await controlClient.newTab(
            pane: pane,
            size: try creationSize(for: pane)
        )
        return try await followCreatedSurface(created.surface)
    }

    /// Splits a visible pane and follows the new pane's returned surface.
    /// - Parameters:
    ///   - pane: The target pane identifier.
    ///   - direction: The right or down split axis.
    /// - Returns: The refreshed navigation and attachment snapshot.
    public func split(
        pane: UInt64,
        direction: CmuxSplitDirection
    ) async throws -> CmuxFrontendStartup {
        guard selectedPane(pane) != nil else {
            throw CmuxProtocolError.command(String(
                format: String(
                    localized: "frontend.error.pane_unavailable",
                    defaultValue: "Pane %lld is unavailable",
                    bundle: .module
                ),
                Int64(pane)
            ))
        }
        let created = try await controlClient.split(
            pane: pane,
            direction: direction,
            size: try creationSize(for: pane)
        )
        return try await followCreatedSurface(created.surface)
    }

    /// Closes one tab surface; the server collapses its pane when it was last.
    /// - Parameter surface: The visible surface to close.
    /// - Returns: The refreshed local snapshot after server reconciliation.
    public func closeTab(surface: UInt64) async throws -> CmuxFrontendStartup {
        guard selectedSurfaceIsVisible(surface) else {
            throw CmuxProtocolError.command(String(
                format: String(
                    localized: "frontend.error.surface_unavailable",
                    defaultValue: "Surface %lld is unavailable",
                    bundle: .module
                ),
                Int64(surface)
            ))
        }
        try await controlClient.closeSurface(surface)
        return try await refreshTreeAndPublish()
    }

    /// Commits one split ratio and refreshes from the server-clamped layout.
    /// - Parameters:
    ///   - target: The pane and axis identifying the intended split.
    ///   - ratio: The requested first-child ratio.
    /// - Returns: The authoritative refreshed snapshot.
    public func setRatio(
        target: CmuxSplitTarget,
        ratio: Double
    ) async throws -> CmuxFrontendStartup {
        guard selectedPane(target.pane) != nil else {
            throw CmuxProtocolError.command(String(
                format: String(
                    localized: "frontend.error.pane_unavailable",
                    defaultValue: "Pane %lld is unavailable",
                    bundle: .module
                ),
                Int64(target.pane)
            ))
        }
        try await controlClient.setRatio(
            pane: target.pane,
            direction: target.direction,
            ratio: CmuxSplitRatio(clamping: ratio).value
        )
        return try await refreshTreeAndPublish()
    }

    /// Records a final grid for one visible surface without claiming a foreign replay size.
    /// - Parameters:
    ///   - measurement: Final container bounds and native cell metrics.
    ///   - surface: The measured surface identifier.
    public func recordTerminalMeasurement(
        _ measurement: CmuxTerminalMeasurement,
        surface: UInt64
    ) {
        guard let measured = resizePolicy.grid(for: measurement),
              let pane = paneID(for: surface),
              var attachment = attachments[pane]
        else { return }
        attachment.localSize = measured
        attachments[pane] = attachment
    }

    /// Records a final grid for the server-active or first visible surface.
    /// - Parameter measurement: Final container bounds and native cell metrics.
    public func recordTerminalMeasurement(_ measurement: CmuxTerminalMeasurement) {
        guard let surface = currentSnapshot()?.surface else { return }
        recordTerminalMeasurement(measurement, surface: surface)
    }

    /// Coalesces one pane's final user-driven layout measurement before applying its grid.
    /// - Parameters:
    ///   - measurement: Final container bounds and native cell metrics.
    ///   - surface: The measured surface identifier.
    public func scheduleResize(
        for measurement: CmuxTerminalMeasurement,
        surface: UInt64
    ) {
        guard let requested = resizePolicy.grid(for: measurement),
              let pane = paneID(for: surface),
              var attachment = attachments[pane]
        else { return }
        attachment.localSize = requested
        let action = resizePolicy.action(
            lastSent: attachment.lastSentSize,
            measurement: measurement
        )
        guard case let .resize(decided) = action else {
            if attachment.pendingResizeSize != nil,
               attachment.pendingResizeSize != requested
            {
                attachment.resizeTask?.cancel()
                attachment.resizeTask = nil
                attachment.pendingResizeSize = nil
            }
            attachments[pane] = attachment
            return
        }
        guard decided == requested, attachment.pendingResizeSize != requested else {
            attachments[pane] = attachment
            return
        }

        attachment.resizeTask?.cancel()
        attachment.pendingResizeSize = requested
        let delay = resizeDebounce
        let generation = attachment.generation
        attachment.resizeTask = Task { [weak self] in
            do {
                // A bounded delay is the intended debounce behavior and is cancelled by newer interactions.
                try await ContinuousClock().sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.resizeAfterDebounce(
                requested,
                pane: pane,
                generation: generation
            )
        }
        attachments[pane] = attachment
    }

    /// Schedules a resize for the server-active or first visible surface.
    /// - Parameter measurement: Final container bounds and native cell metrics.
    public func scheduleResize(for measurement: CmuxTerminalMeasurement) {
        guard let surface = currentSnapshot()?.surface else { return }
        scheduleResize(for: measurement, surface: surface)
    }

    /// Sends raw input bytes to one pane attachment.
    /// - Parameters:
    ///   - data: Raw terminal input bytes.
    ///   - surface: The destination surface identifier.
    public func sendInput(_ data: Data, surface: UInt64) async {
        guard let pane = paneID(for: surface) else { return }
        guard let attachment = attachments[pane], attachment.surface == surface else { return }
        try? await attachment.client.sendBytes(data, surface: surface)
    }

    /// Sends input to the server-active or first visible attachment.
    /// - Parameter data: Raw terminal input bytes.
    public func sendInput(_ data: Data) async {
        guard let surface = currentSnapshot()?.surface else { return }
        await sendInput(data, surface: surface)
    }

    /// Sends UTF-8 text to one attached surface and waits for acknowledgement.
    /// - Parameters:
    ///   - text: Text to write to the PTY.
    ///   - surface: The destination surface identifier.
    ///   - paste: Whether the server should apply bracketed-paste handling.
    public func sendText(_ text: String, surface: UInt64, paste: Bool = false) async throws {
        guard let pane = paneID(for: surface) else {
            throw CmuxProtocolError.transportState(String(
                format: String(
                    localized: "frontend.error.surface_not_attached",
                    defaultValue: "Surface %lld is not attached",
                    bundle: .module
                ),
                Int64(surface)
            ))
        }
        guard let attachment = attachments[pane], attachment.surface == surface else {
            throw CmuxProtocolError.transportState(String(
                format: String(
                    localized: "frontend.error.surface_not_attached",
                    defaultValue: "Surface %lld is not attached",
                    bundle: .module
                ),
                Int64(surface)
            ))
        }
        try await attachment.client.sendText(text, surface: surface, paste: paste)
    }

    /// Sends text to the server-active or first visible attachment.
    /// - Parameter text: Text to write to the PTY.
    public func sendText(_ text: String, paste: Bool = false) async throws {
        guard let surface = currentSnapshot()?.surface else {
            throw CmuxProtocolError.transportState("no attached surface")
        }
        try await sendText(text, surface: surface, paste: paste)
    }

    /// Sends one terminal-mode-aware named key to an attached surface.
    /// - Parameters:
    ///   - key: The lower-case protocol key chord.
    ///   - surface: The destination surface identifier.
    public func sendKey(_ key: String, surface: UInt64) async throws {
        guard let pane = paneID(for: surface) else {
            throw CmuxProtocolError.transportState(String(
                format: String(
                    localized: "frontend.error.surface_not_attached",
                    defaultValue: "Surface %lld is not attached",
                    bundle: .module
                ),
                Int64(surface)
            ))
        }
        guard let attachment = attachments[pane], attachment.surface == surface else { return }
        try await attachment.client.sendKey(key, surface: surface)
    }

    /// Reads one non-mutating styled scrollback page for an attached surface.
    /// - Parameters:
    ///   - request: The absolute retained-buffer range.
    ///   - surface: The destination surface identifier.
    /// - Returns: One atomic styled scrollback page.
    public func readScrollback(
        _ request: CmuxScrollbackRequest,
        surface: UInt64
    ) async throws -> CmuxReadScrollbackResponse {
        guard let pane = paneID(for: surface),
              let attachment = attachments[pane],
              attachment.surface == surface
        else {
            throw CmuxProtocolError.transportState(String(
                format: String(
                    localized: "frontend.error.surface_not_attached",
                    defaultValue: "Surface %lld is not attached",
                    bundle: .module
                ),
                Int64(surface)
            ))
        }
        return try await attachment.client.readScrollback(
            surface,
            start: request.start,
            count: request.count
        )
    }

    /// Closes the control connection and every visible attachment stream.
    public func close() async {
        controlTask?.cancel()
        controlTask = nil
        let oldAttachments = Array(attachments.values)
        attachments.removeAll()
        for attachment in oldAttachments {
            attachment.eventTask?.cancel()
            attachment.resizeTask?.cancel()
            await attachment.client.close()
        }
        await controlClient.close()
        eventContinuation.finish()
    }

    private func selectedPane(_ pane: UInt64) -> CmuxPane? {
        guard let tree, let selection else { return nil }
        return tree.pane(
            workspace: selection.workspaceID,
            screen: selection.screenID,
            pane: pane
        )
    }

    private func selectedSurfaceIsVisible(_ surface: UInt64) -> Bool {
        guard let tree, let selection else { return false }
        return tree.visiblePaneSurfaces(selection: selection).contains { $0.surface == surface }
    }

    private func creationSize(for pane: UInt64) throws -> CmuxSurfaceSize {
        if let localSize = attachments[pane]?.localSize {
            return localSize
        }
        guard let paneSnapshot = selectedPane(pane) else {
            throw CmuxProtocolError.command(String(
                format: String(
                    localized: "frontend.error.pane_unavailable",
                    defaultValue: "Pane %lld is unavailable",
                    bundle: .module
                ),
                Int64(pane)
            ))
        }
        let attachedSurface = attachments[pane]?.surface
        let attachedTab = attachedSurface.flatMap { surface in
            paneSnapshot.tabs.first(where: { $0.surface == surface })
        }
        let activeTab = paneSnapshot.tabs.indices.contains(paneSnapshot.activeTab)
            ? paneSnapshot.tabs[paneSnapshot.activeTab]
            : nil
        let source = attachedTab ?? activeTab
            .flatMap { $0.kind == "pty" && !$0.dead ? $0 : nil }
            ?? paneSnapshot.tabs.first(where: { $0.kind == "pty" && !$0.dead })
        guard let size = source?.size else {
            throw CmuxProtocolError.command(String(
                format: String(
                    localized: "frontend.error.pane_size_unavailable",
                    defaultValue: "Pane %lld has no terminal grid yet",
                    bundle: .module
                ),
                Int64(pane)
            ))
        }
        return size
    }

    private func startControlLoop(events: AsyncStream<CmuxAttachEvent>) {
        controlTask?.cancel()
        controlTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                guard case let .other(name) = event,
                      Self.treeRefreshEvents.contains(name)
                else { continue }
                _ = try? await self?.refreshTreeAndPublish()
            }
        }
    }

    private func refreshTreeAndPublish() async throws -> CmuxFrontendStartup {
        let refreshed = try await controlClient.listWorkspaces()
        guard var selection else {
            throw CmuxProtocolError.transportState("no local selection")
        }
        guard selection.reconcile(with: refreshed) else {
            throw CmuxProtocolError.noActivePTYSurface
        }
        tree = refreshed
        self.selection = selection
        return try await attachSelectionAndPublish()
    }

    private func followCreatedSurface(_ createdSurface: UInt64) async throws -> CmuxFrontendStartup {
        let refreshed = try await controlClient.listWorkspaces()
        guard let location = refreshed.location(of: createdSurface) else {
            throw CmuxProtocolError.malformedPayload(
                "created surface \(createdSurface) is missing from the workspace tree"
            )
        }
        tree = refreshed
        selection = CmuxLocalSelection(
            workspaceID: location.workspace,
            screenID: location.screen
        )
        return try await attachSelectionAndPublish()
    }

    private func attachSelectionAndPublish() async throws -> CmuxFrontendStartup {
        try await reconcileAttachments()
        guard let snapshot = currentSnapshot() else {
            throw CmuxProtocolError.transportState("frontend snapshot unavailable")
        }
        eventContinuation.yield(.snapshot(snapshot))
        return snapshot
    }

    private func reconcileAttachments() async throws {
        guard let tree, let selection else {
            throw CmuxProtocolError.transportState("no local selection")
        }
        let desired = tree.visiblePaneSurfaces(selection: selection)
        guard !desired.isEmpty else { throw CmuxProtocolError.noActivePTYSurface }
        let desiredByPane = Dictionary(uniqueKeysWithValues: desired.map { ($0.pane, $0.surface) })

        for pane in attachments.keys.sorted() where desiredByPane[pane] != attachments[pane]?.surface {
            await detachAttachment(pane: pane)
        }
        for target in desired where attachments[target.pane] == nil {
            try await attach(pane: target.pane, surface: target.surface)
        }
    }

    private func attach(pane: UInt64, surface: UInt64) async throws {
        let generation = nextAttachmentGeneration
        nextAttachmentGeneration &+= 1
        let client = await attachmentClientFactory.makeClient()
        do {
            try await client.connect(token: configuration.token)
            if let hostname {
                try await client.setClientInfo(name: hostname, kind: "swift")
            }
            let events = await client.events()
            try await client.attachRenderSurface(surface)
            try Task.checkCancellation()
            attachments[pane] = CmuxPaneAttachment(
                pane: pane,
                surface: surface,
                generation: generation,
                client: client
            )
            let task = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { return }
                    await self?.receiveAttachment(
                        event,
                        pane: pane,
                        generation: generation
                    )
                }
            }
            attachments[pane]?.eventTask = task
        } catch {
            await client.close()
            throw error
        }
    }

    private func detachAttachment(pane: UInt64) async {
        guard let attachment = attachments.removeValue(forKey: pane) else { return }
        attachment.eventTask?.cancel()
        attachment.resizeTask?.cancel()
        await attachment.client.close()
    }

    private func receiveAttachment(
        _ event: CmuxAttachEvent,
        pane: UInt64,
        generation: UInt64
    ) async {
        guard let attachment = attachments[pane],
              attachment.generation == generation
        else { return }
        let routedEvent: CmuxAttachEvent
        switch event {
        case let .renderState(state):
            guard state.surface == attachment.surface else { return }
            routedEvent = event
        case let .renderDelta(delta):
            guard delta.surface == attachment.surface else { return }
            routedEvent = event
        case let .detached(eventSurface):
            guard eventSurface == attachment.surface else { return }
            attachments.removeValue(forKey: pane)
            attachment.resizeTask?.cancel()
            eventContinuation.yield(.terminal(event))
            await attachment.client.close()
            return
        case .other:
            return
        }
        attachments[pane] = attachment
        eventContinuation.yield(.terminal(routedEvent))
    }

    private func paneID(for surface: UInt64) -> UInt64? {
        attachments.first(where: { $0.value.surface == surface })?.key
    }

    private func resizeAfterDebounce(
        _ requested: CmuxSurfaceSize,
        pane: UInt64,
        generation: UInt64
    ) async {
        guard var attachment = attachments[pane],
              attachment.generation == generation,
              attachment.pendingResizeSize == requested
        else { return }
        attachment.pendingResizeSize = nil
        attachment.resizeTask = nil
        attachments[pane] = attachment
        await resizeNow(requested, pane: pane, generation: generation)
    }

    private func resizeNow(
        _ requested: CmuxSurfaceSize,
        pane: UInt64,
        generation: UInt64
    ) async {
        guard let attachment = attachments[pane],
              attachment.generation == generation,
              requested != attachment.lastSentSize
        else { return }
        do {
            try await attachment.client.resizeSurface(
                attachment.surface,
                columns: requested.cols,
                rows: requested.rows
            )
            guard var current = attachments[pane], current.generation == generation else { return }
            current.lastSentSize = requested
            attachments[pane] = current
        } catch {
            return
        }
    }

    private func currentSnapshot() -> CmuxFrontendStartup? {
        guard let tree, let selection, let protocolVersion, let sessionName else { return nil }
        let visible = tree.visiblePaneSurfaces(selection: selection)
        let surfaces = visible.compactMap { target in
            attachments[target.pane]?.surface == target.surface ? target.surface : nil
        }
        guard let firstSurface = surfaces.first else { return nil }
        let activePane = tree.selectedScreen(selection: selection)?.activePane
        let activeSurface = activePane.flatMap { attachments[$0]?.surface } ?? firstSurface
        return CmuxFrontendStartup(
            workspaces: tree.snapshots(selection: selection),
            selectedWorkspace: selection.workspaceID,
            selectedScreen: selection.screenID,
            surface: activeSurface,
            surfaces: surfaces,
            protocolVersion: protocolVersion,
            sessionName: sessionName
        )
    }

    private static let treeRefreshEvents: Set<String> = [
        "tree-changed",
        "layout-changed",
        "surface-exited",
        "title-changed",
    ]
}
