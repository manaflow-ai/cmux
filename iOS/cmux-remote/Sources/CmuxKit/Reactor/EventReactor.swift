public import Foundation
public import Logging

/// Drives the event stream lifecycle: subscribe → consume → on disconnect
/// reconnect → on resume-gap fetch a fresh snapshot.
///
/// This is the central state-sync engine. The app owns one of these per
/// active host. Cancel `start()` to stop.
public actor EventReactor {

    public struct Configuration: Sendable {
        public var hostID: UUID?
        public var categories: [String]
        public var pingInterval: Duration
        public var reconnectBackoff: ReconnectBackoff
        public var onAgentDecision: (@Sendable (AgentDecision) async throws -> Void)?
        public var onAgentDecisionResolved: (@Sendable (String) async -> Void)?
        public var watchdog: AgentWatchdog?

        public init(
            hostID: UUID? = nil,
            categories: [String] = [],
            pingInterval: Duration = .seconds(20),
            reconnectBackoff: ReconnectBackoff = .exponentialClamped(),
            onAgentDecision: (@Sendable (AgentDecision) async throws -> Void)? = nil,
            onAgentDecisionResolved: (@Sendable (String) async -> Void)? = nil,
            watchdog: AgentWatchdog? = nil
        ) {
            self.hostID = hostID
            self.categories = categories
            self.pingInterval = pingInterval
            self.reconnectBackoff = reconnectBackoff
            self.onAgentDecision = onAgentDecision
            self.onAgentDecisionResolved = onAgentDecisionResolved
            self.watchdog = watchdog
        }
    }

    public struct ReconnectBackoff: Sendable {
        public var initial: Duration
        public var multiplier: Double
        public var cap: Duration

        public static func exponentialClamped(
            initial: Duration = .milliseconds(500),
            multiplier: Double = 1.8,
            cap: Duration = .seconds(30)
        ) -> ReconnectBackoff {
            ReconnectBackoff(initial: initial, multiplier: multiplier, cap: cap)
        }

        public func next(after current: Duration?) -> Duration {
            guard let current else { return initial }
            let next = Duration.seconds(Double(current.components.seconds) * multiplier
                                        + Double(current.components.attoseconds) * multiplier / 1e18)
            if next > cap { return cap }
            return next
        }
    }

    private let client: CMUXClient
    private let state: ServerState
    private let config: Configuration
    private let log: Logger
    private var runningTask: Task<Void, Never>?
    private static let maxConcurrentWorkspaceSnapshotTasks = 4

    public init(
        client: CMUXClient,
        state: ServerState,
        configuration: Configuration = .init(),
        logger: Logger = CmuxLog.make("reactor")
    ) {
        self.client = client
        self.state = state
        self.config = configuration
        self.log = logger
    }

    /// Start the reactor. Returns immediately; the work runs detached. Call
    /// `stop()` to cancel.
    public func start() {
        guard runningTask == nil else { return }
        if let watchdog = config.watchdog {
            Task { await watchdog.start() }
        }
        runningTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func requestStop() {
        runningTask?.cancel()
    }

    public func stop() async {
        let task = runningTask
        runningTask = nil
        task?.cancel()
        if let watchdog = config.watchdog {
            await watchdog.stop()
        }
        await task?.value
        await state.setPhase(.disconnected(lastError: nil), hostID: config.hostID)
    }

    private func runLoop() async {
        var backoff: Duration? = nil
        while !Task.isCancelled {
            do {
                await state.setPhase(.connecting, hostID: config.hostID)
                try await refreshSnapshot()
                await state.setPhase(.live(latency: nil), hostID: config.hostID)
                try await consumeEvents()
                backoff = nil
            } catch is CancellationError {
                break
            } catch CmuxError.cancelled {
                break
            } catch {
                let waitFor = config.reconnectBackoff.next(after: backoff)
                backoff = waitFor
                log.warning("event loop failed; will reconnect", metadata: [
                    "error": .string(String(describing: error)),
                    "wait_ms": .stringConvertible(waitFor.components.seconds * 1000)
                ])
                await state.setPhase(.disconnected(lastError: error.localizedDescription), hostID: config.hostID)
                do {
                    try await Task.sleep(for: waitFor)
                } catch {
                    return
                }
            }
        }
    }

    private func refreshSnapshot(updatePhase: Bool = true) async throws {
        if updatePhase {
            await state.setPhase(.syncing, hostID: config.hostID)
        }
        async let windowsTask = client.listWindows()
        async let workspacesTask = client.listWorkspaces()
        async let notificationsTask = client.listNotifications()
        let windows = try await windowsTask
        let workspaces = try await workspacesTask
        let notifications = try await notificationsTask

        // Pane/surface lists are per-workspace and each RPC opens an SSH
        // session channel. Keep fan-out below common sshd MaxSessions limits
        // and fail the refresh instead of silently replacing failed workspace
        // state with empty panes/surfaces.
        var allPanes: [CmuxPane] = []
        var allSurfaces: [CmuxSurface] = []
        for batchStart in stride(
            from: 0,
            to: workspaces.count,
            by: Self.maxConcurrentWorkspaceSnapshotTasks
        ) {
            let batchEnd = min(
                batchStart + Self.maxConcurrentWorkspaceSnapshotTasks,
                workspaces.count
            )
            try await withThrowingTaskGroup(
                of: (workspaceID: WorkspaceID, panes: [CmuxPane], surfaces: [CmuxSurface]).self
            ) { group in
                for workspace in workspaces[batchStart..<batchEnd] {
                    group.addTask { [client] in
                        let panes = try await client.listPanes(workspaceID: workspace.id)
                        var surfaces: [CmuxSurface] = []
                        for pane in panes {
                            let s = try await client.listSurfaces(
                                paneID: pane.id,
                                workspaceID: workspace.id
                            )
                            surfaces.append(contentsOf: s)
                        }
                        return (workspace.id, panes, surfaces)
                    }
                }
                for try await result in group {
                    allPanes.append(contentsOf: result.panes)
                    allSurfaces.append(contentsOf: result.surfaces)
                }
            }
        }

        await state.ingestSnapshot(
            windows: windows,
            workspaces: workspaces,
            panes: allPanes,
            surfaces: allSurfaces,
            notifications: notifications,
            hostID: config.hostID
        )
    }

    private func consumeEvents() async throws {
        let cursor = await state.current.cursor
        let priorBootID = cursor.bootID
        let stream = client.eventStream(cursor: cursor, categories: config.categories)
        for try await frame in stream {
            try Task.checkCancellation()
            switch frame {
            case .ack(let ack):
                // CRITICAL: a boot-id change ALWAYS invalidates our local
                // state, even if the server says `gap: false`. The server
                // only computes `gap` against its in-memory replay; a
                // brand-new boot will silently accept our stale seq if
                // that seq is within the new boot's range, and we'd
                // apply the new boot's events on top of stale local
                // state. Refresh on any boot-id mismatch.
                let bootIDChanged = (priorBootID != nil) && (priorBootID != ack.bootID)
                await state.resetCursor(for: ack, hostID: config.hostID)
                if ack.resume.gap || bootIDChanged {
                    log.notice("resume gap or boot-id change — refreshing snapshot", metadata: [
                        "gap": .stringConvertible(ack.resume.gap),
                        "boot_id_changed": .stringConvertible(bootIDChanged)
                    ])
                    try await refreshSnapshot()
                    await state.setPhase(.live(latency: nil), hostID: config.hostID)
                }
            case .event(let event):
                try Task.checkCancellation()
                await state.applyWithoutCommittingCursor(event: event, hostID: config.hostID)
                if let watchdog = config.watchdog {
                    await watchdog.observe(event: event)
                }
                if event.category == "agent" {
                    if let decision = AgentDecisionMapper.decode(from: event),
                       let onAgentDecision = config.onAgentDecision {
                        try await onAgentDecision(await hydrateIfNeeded(decision))
                    }
                } else if event.category == "feed",
                          (event.name == "feed.item.resolved" || event.name == "feed.item.completed"),
                          let onAgentDecisionResolved = config.onAgentDecisionResolved,
                          let id = FeedDecisionIdentifier.extract(from: event.payload) {
                    await onAgentDecisionResolved(id)
                }
                if requiresSnapshotRefresh(after: event) {
                    try await refreshSnapshot(updatePhase: false)
                }
                try Task.checkCancellation()
                await state.commitCursor(event: event, hostID: config.hostID)
            case .heartbeat:
                // Heartbeats are operational only.
                break
            }
        }
    }

    private func hydrateIfNeeded(_ decision: AgentDecision) async -> AgentDecision {
        guard decision.itemID == nil || (decision.kind == .choice && decision.choices.isEmpty) else {
            return decision
        }
        do {
            for attempt in 0..<3 {
                let pending = try await client.listPendingAgentDecisions()
                if let hydrated = pending.first(where: { $0.id == decision.id }) {
                    return hydrated
                }
                if attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            return decision
        } catch {
            log.warning("could not hydrate redacted agent decision", metadata: [
                "decision_id": .string(decision.id),
                "error": .string(error.localizedDescription)
            ])
            return decision
        }
    }

    private func requiresSnapshotRefresh(after event: CmuxEventFrame.Event) -> Bool {
        switch event.name {
        case "window.created",
             "window.closed",
             "workspace.created",
             "workspace.closed",
             "workspace.reordered",
             "workspace.moved",
             "pane.created",
             "pane.closed",
             "pane.resized",
             "pane.swapped",
             "pane.broken",
             "pane.joined",
             "surface.created",
             "surface.closed",
             "surface.moved",
             "surface.reordered",
             "notification.created",
             "notification.read",
             "notification.removed",
             "notification.cleared",
             "browser.navigation":
            return true
        default:
            return false
        }
    }
}

enum FeedDecisionIdentifier {
    private static let decisionKeys = [
        "_opencode_request_id",
        "request_id",
        "decision_id"
    ]

    static func extract(from payload: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        return extract(from: object)
    }

    static func extract(from object: [String: Any]) -> String? {
        if let id = firstString(in: object, keys: decisionKeys) { return id }
        if let params = object["params"] as? [String: Any],
           let id = firstString(in: params, keys: decisionKeys) { return id }
        if let result = object["result"] as? [String: Any],
           let id = firstString(in: result, keys: decisionKeys) { return id }
        if let item = object["item"] as? [String: Any],
           let id = firstString(in: item, keys: decisionKeys) { return id }
        return nil
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
