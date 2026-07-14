import Foundation

/// Orchestrates local navigation, one disposable byte attachment, input, and sizing.
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
    private var surface: UInt64?
    private var attachmentClient: CmuxProtocolClient?
    private var attachmentGeneration: UInt64 = 0
    private var attachmentTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var pendingResizeSize: CmuxSurfaceSize?
    private var localSize: CmuxSurfaceSize?
    private var remoteSize: CmuxSurfaceSize?
    private var lastSentSize: CmuxSurfaceSize?
    private var sizeClaimed = false

    /// Creates a frontend session from injected protocol pieces.
    /// - Parameters:
    ///   - client: The long-lived command and tree-event client.
    ///   - attachmentClientFactory: A factory for one disposable client per surface attachment.
    ///   - configuration: Resolved transport endpoint and optional WebSocket token.
    ///   - resizeDebounce: The bounded window-resize coalescing delay.
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

    /// Connects, negotiates protocol 6+, initializes local selection, and attaches its PTY.
    /// - Parameters:
    ///   - hostname: The client name reported to cmux-tui.
    ///   - preferredSurface: An optional surface used to initialize local navigation.
    /// - Returns: The selected tree and attachment summary.
    public func connect(
        hostname: String,
        preferredSurface: UInt64? = nil
    ) async throws -> CmuxFrontendStartup {
        try await controlClient.connect(token: configuration.token)
        let identify = try await controlClient.identify()
        guard identify.app == "cmux-tui", identify.protocol >= 6 else {
            throw CmuxProtocolError.incompatibleServer(
                "expected cmux-tui protocol >= 6, got \(identify.app) protocol \(identify.protocol)"
            )
        }

        try await controlClient.setClientInfo(name: hostname, kind: "swift")
        let tree = try await controlClient.listWorkspaces()
        guard let selection = CmuxLocalSelection(tree: tree, preferredSurface: preferredSurface),
              let target = tree.surface(
                workspace: selection.workspaceID,
                screen: selection.screenID
              )
        else {
            throw CmuxProtocolError.noActivePTYSurface
        }

        self.hostname = hostname
        self.protocolVersion = identify.protocol
        sessionName = identify.session
        self.tree = tree
        self.selection = selection

        let controlEvents = await controlClient.events()
        try await controlClient.subscribe()
        startControlLoop(events: controlEvents)
        try await switchAttachment(to: target)

        guard let snapshot = currentSnapshot() else {
            throw CmuxProtocolError.transportState("frontend snapshot unavailable after connect")
        }
        return snapshot
    }

    /// Returns ordered frontend state and terminal events.
    /// - Returns: A stable stream spanning surface reattachments.
    public func events() -> AsyncStream<CmuxFrontendEvent> {
        eventStream
    }

    /// Selects a workspace only for this client and attaches its active screen surface.
    /// - Parameter workspace: The workspace identifier.
    /// - Returns: The updated local navigation snapshot.
    public func selectWorkspace(_ workspace: UInt64) async throws -> CmuxFrontendStartup {
        guard let tree, var selection, selection.selectWorkspace(workspace, in: tree) else {
            throw CmuxProtocolError.command("workspace \(workspace) is unavailable")
        }
        self.selection = selection
        return try await attachSelectionAndPublish()
    }

    /// Selects a screen only for this client and attaches its active surface.
    /// - Parameter screen: The screen identifier in the locally selected workspace.
    /// - Returns: The updated local navigation snapshot.
    public func selectScreen(_ screen: UInt64) async throws -> CmuxFrontendStartup {
        guard let tree, var selection, selection.selectScreen(screen, in: tree) else {
            throw CmuxProtocolError.command("screen \(screen) is unavailable")
        }
        self.selection = selection
        return try await attachSelectionAndPublish()
    }

    /// Creates a workspace, locates its returned surface, and follows it locally.
    /// - Returns: The updated local navigation snapshot.
    public func newWorkspace() async throws -> CmuxFrontendStartup {
        let created = try await controlClient.newWorkspace(size: localSize)
        return try await followCreatedSurface(created.surface)
    }

    /// Creates a screen in the locally selected workspace and follows it locally.
    /// - Returns: The updated local navigation snapshot.
    public func newScreen() async throws -> CmuxFrontendStartup {
        guard let selection else {
            throw CmuxProtocolError.transportState("no locally selected workspace")
        }
        let created = try await controlClient.newScreen(
            workspace: selection.workspaceID,
            size: localSize
        )
        return try await followCreatedSurface(created.surface)
    }

    /// Selects a tab through shared server state and follows its active PTY surface.
    /// - Parameters:
    ///   - pane: The selected screen's active pane identifier.
    ///   - index: The zero-based tab index.
    /// - Returns: The refreshed navigation and attachment snapshot.
    public func selectTab(pane: UInt64, index: Int) async throws -> CmuxFrontendStartup {
        guard let tree, let selection,
              let selectedPane = tree.pane(
                workspace: selection.workspaceID,
                screen: selection.screenID
              ),
              selectedPane.id == pane,
              selectedPane.tabs.indices.contains(index)
        else {
            throw CmuxProtocolError.command("tab \(index) in pane \(pane) is unavailable")
        }
        try await controlClient.selectTab(pane: pane, index: index)
        return try await refreshTreeAndPublish()
    }

    /// Creates a tab in the selected screen's active pane and follows it.
    /// - Parameter pane: The selected screen's active pane identifier.
    /// - Returns: The refreshed navigation and attachment snapshot.
    public func newTab(pane: UInt64) async throws -> CmuxFrontendStartup {
        guard let tree, let selection,
              tree.pane(
                workspace: selection.workspaceID,
                screen: selection.screenID
              )?.id == pane
        else {
            throw CmuxProtocolError.command("pane \(pane) is unavailable")
        }
        let created = try await controlClient.newTab(pane: pane, size: localSize)
        return try await followCreatedSurface(created.surface)
    }

    /// Records the grid derived from final bounds without claiming a foreign replay size.
    /// - Parameter measurement: Final container bounds and Ghostty cell metrics.
    public func recordTerminalMeasurement(_ measurement: CmuxTerminalMeasurement) {
        guard let measured = resizePolicy.grid(for: measurement) else { return }
        localSize = measured
    }

    /// Coalesces a final user-driven layout measurement before applying its grid.
    /// - Parameter measurement: Final container bounds and Ghostty cell metrics.
    public func scheduleResize(for measurement: CmuxTerminalMeasurement) {
        guard let requested = resizePolicy.grid(for: measurement) else { return }
        localSize = requested
        if requested == remoteSize {
            sizeClaimed = true
        }
        let action = resizePolicy.action(
            lastSent: lastSentSize,
            incomingResized: remoteSize,
            measurement: measurement
        )
        guard case let .resize(decided) = action else {
            if pendingResizeSize != nil, pendingResizeSize != requested {
                resizeTask?.cancel()
                resizeTask = nil
                pendingResizeSize = nil
            }
            return
        }
        guard decided == requested, pendingResizeSize != requested else { return }

        resizeTask?.cancel()
        pendingResizeSize = requested
        let delay = resizeDebounce
        let generation = attachmentGeneration
        resizeTask = Task { [weak self] in
            do {
                // A bounded delay is the intended debounce behavior and is cancelled by newer interactions.
                try await ContinuousClock().sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.resizeAfterDebounce(requested, generation: generation)
        }
    }

    /// Sends libghostty-generated input bytes after reclaiming a divergent surface size.
    /// - Parameter data: Raw terminal input bytes.
    public func sendInput(_ data: Data) async {
        await claimSizeBeforeInput()
        guard let surface, let attachmentClient else { return }
        try? await attachmentClient.sendBytes(data, surface: surface)
    }

    /// Sends UTF-8 text to the attached surface and waits for acknowledgement.
    /// - Parameter text: Text to write to the PTY.
    public func sendText(_ text: String) async throws {
        await claimSizeBeforeInput()
        guard let surface, let attachmentClient else {
            throw CmuxProtocolError.transportState("no attached surface")
        }
        try await attachmentClient.sendText(text, surface: surface)
    }

    /// Closes the control connection and the one active attachment stream.
    public func close() async {
        resizeTask?.cancel()
        resizeTask = nil
        pendingResizeSize = nil
        controlTask?.cancel()
        controlTask = nil
        attachmentTask?.cancel()
        attachmentTask = nil
        attachmentGeneration &+= 1
        let attachmentClient = attachmentClient
        self.attachmentClient = nil
        surface = nil
        await attachmentClient?.close()
        await controlClient.close()
        eventContinuation.finish()
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
        guard let tree, let selection,
              let target = tree.surface(
                workspace: selection.workspaceID,
                screen: selection.screenID
              )
        else {
            throw CmuxProtocolError.noActivePTYSurface
        }
        if target != surface {
            try await switchAttachment(to: target)
        }
        guard let snapshot = currentSnapshot() else {
            throw CmuxProtocolError.transportState("frontend snapshot unavailable")
        }
        eventContinuation.yield(.snapshot(snapshot))
        return snapshot
    }

    private func switchAttachment(to target: UInt64) async throws {
        attachmentGeneration &+= 1
        let generation = attachmentGeneration
        resizeTask?.cancel()
        resizeTask = nil
        pendingResizeSize = nil
        attachmentTask?.cancel()
        attachmentTask = nil
        let previous = attachmentClient
        attachmentClient = nil
        surface = nil
        remoteSize = nil
        lastSentSize = nil
        sizeClaimed = false
        await previous?.close()
        try Task.checkCancellation()

        let client = await attachmentClientFactory.makeClient()
        attachmentClient = client
        do {
            try await client.connect(token: configuration.token)
            if let hostname {
                try await client.setClientInfo(name: hostname, kind: "swift")
            }
            let events = await client.events()
            try await client.attachSurface(
                target,
                includeByteMode: (protocolVersion ?? 6) >= 7
            )
            guard generation == attachmentGeneration else {
                await client.close()
                throw CancellationError()
            }
            try Task.checkCancellation()
            surface = target
            attachmentTask = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { return }
                    await self?.receiveAttachment(event, generation: generation)
                }
            }
        } catch {
            if generation == attachmentGeneration {
                attachmentClient = nil
            }
            await client.close()
            throw error
        }
    }

    private func receiveAttachment(_ event: CmuxAttachEvent, generation: UInt64) {
        guard generation == attachmentGeneration else { return }
        switch event {
        case let .initialReplay(eventSurface, columns, rows, _, _):
            guard eventSurface == surface else { return }
            remoteSize = CmuxSurfaceSize(cols: columns, rows: rows)
            sizeClaimed = localSize == remoteSize
        case let .resizedReplay(eventSurface, columns, rows, _):
            guard eventSurface == surface else { return }
            remoteSize = CmuxSurfaceSize(cols: columns, rows: rows)
            // An exact echo preserves ownership. A foreign size is accepted
            // until the next local keystroke claims the recorded final grid.
            sizeClaimed = remoteSize == lastSentSize
        case let .output(eventSurface, _), let .detached(eventSurface):
            guard eventSurface == surface else { return }
            if case .detached = event {
                surface = nil
            }
        case let .colorsChanged(eventSurface, _):
            guard eventSurface == nil || eventSurface == surface else { return }
        case .other:
            return
        }
        eventContinuation.yield(.terminal(event))
    }

    private func claimSizeBeforeInput() async {
        guard !sizeClaimed else { return }
        resizeTask?.cancel()
        resizeTask = nil
        pendingResizeSize = nil
        if let localSize {
            await resizeNow(localSize)
        }
        sizeClaimed = true
    }

    private func resizeAfterDebounce(_ requested: CmuxSurfaceSize, generation: UInt64) async {
        guard generation == attachmentGeneration,
              pendingResizeSize == requested
        else { return }
        pendingResizeSize = nil
        resizeTask = nil
        await resizeNow(requested)
    }

    private func resizeNow(_ requested: CmuxSurfaceSize) async {
        guard requested != remoteSize, let surface, let attachmentClient else { return }
        do {
            try await attachmentClient.resizeSurface(
                surface,
                columns: requested.cols,
                rows: requested.rows
            )
            lastSentSize = requested
            remoteSize = requested
            sizeClaimed = true
        } catch {
            return
        }
    }

    private func currentSnapshot() -> CmuxFrontendStartup? {
        guard let tree, let selection, let surface,
              let protocolVersion, let sessionName
        else { return nil }
        return CmuxFrontendStartup(
            workspaces: tree.snapshots(selection: selection),
            selectedWorkspace: selection.workspaceID,
            selectedScreen: selection.screenID,
            surface: surface,
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
