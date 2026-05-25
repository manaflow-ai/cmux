public import Foundation
public import Collections

/// Snapshot-style projection of the remote cmux server's state.
///
/// `ServerState` is what views subscribe to. Mutations come from two places:
///   1. The `CMUXClient` snapshot calls (after connect, after resume-gap).
///   2. The `EventReactor` applying events from the live stream.
///
/// All mutation goes through the actor; readers receive immutable snapshots
/// through `AsyncStream<Snapshot>`.
public actor ServerState {

    public struct Snapshot: Sendable, Equatable {
        public var generation: UInt64
        public var connectionPhase: ConnectionPhase
        public var windows: OrderedDictionary<WindowID, CmuxWindow>
        public var workspaces: OrderedDictionary<WorkspaceID, CmuxWorkspace>
        public var panes: OrderedDictionary<PaneID, CmuxPane>
        public var surfaces: OrderedDictionary<SurfaceID, CmuxSurface>
        public var notifications: OrderedDictionary<NotificationID, CmuxNotification>
        public var focusedWorkspaceID: WorkspaceID?
        public var focusedPaneID: PaneID?
        public var focusedSurfaceID: SurfaceID?
        public var cursor: CmuxEventCursor
        public var hostID: UUID?

        public init(
            generation: UInt64,
            connectionPhase: ConnectionPhase,
            windows: OrderedDictionary<WindowID, CmuxWindow>,
            workspaces: OrderedDictionary<WorkspaceID, CmuxWorkspace>,
            panes: OrderedDictionary<PaneID, CmuxPane>,
            surfaces: OrderedDictionary<SurfaceID, CmuxSurface>,
            notifications: OrderedDictionary<NotificationID, CmuxNotification>,
            focusedWorkspaceID: WorkspaceID? = nil,
            focusedPaneID: PaneID? = nil,
            focusedSurfaceID: SurfaceID? = nil,
            cursor: CmuxEventCursor,
            hostID: UUID? = nil
        ) {
            self.generation = generation
            self.connectionPhase = connectionPhase
            self.windows = windows
            self.workspaces = workspaces
            self.panes = panes
            self.surfaces = surfaces
            self.notifications = notifications
            self.focusedWorkspaceID = focusedWorkspaceID
            self.focusedPaneID = focusedPaneID
            self.focusedSurfaceID = focusedSurfaceID
            self.cursor = cursor
            self.hostID = hostID
        }

        public var unreadNotifications: Int {
            notifications.values.reduce(into: 0) { $0 += $1.isRead ? 0 : 1 }
        }

        public var workspacesByWindow: [WindowID: [CmuxWorkspace]] {
            var grouped: [WindowID: [CmuxWorkspace]] = [:]
            for workspace in workspaces.values.sorted(by: { $0.index < $1.index }) {
                grouped[workspace.windowID, default: []].append(workspace)
            }
            return grouped
        }
    }

    public enum ConnectionPhase: Sendable, Equatable {
        case disconnected(lastError: String?)
        case connecting
        case authenticating
        case syncing
        case live(latency: Duration?)
    }

    public init() {
        self.current = Snapshot(
            generation: 0,
            connectionPhase: .disconnected(lastError: nil),
            windows: [:],
            workspaces: [:],
            panes: [:],
            surfaces: [:],
            notifications: [:],
            focusedWorkspaceID: nil,
            focusedPaneID: nil,
            focusedSurfaceID: nil,
            cursor: CmuxEventCursor()
        )
    }

    public private(set) var current: Snapshot

    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    public func subscribe() -> AsyncStream<Snapshot> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.detach(id: id) }
            }
        }
    }

    private func detach(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func publish() {
        current.generation &+= 1
        for continuation in continuations.values {
            continuation.yield(current)
        }
    }

    private func hostMatches(_ hostID: UUID?) -> Bool {
        guard let hostID else { return true }
        return current.hostID == hostID
    }

    // MARK: - Phase

    public func setPhase(_ phase: ConnectionPhase, hostID: UUID? = nil) {
        guard hostMatches(hostID) else { return }
        current.connectionPhase = phase
        publish()
    }

    public func setHostID(_ hostID: UUID?) {
        current.hostID = hostID
        publish()
    }

    public func resetForHost(_ hostID: UUID?) {
        current = Snapshot(
            generation: current.generation,
            connectionPhase: .disconnected(lastError: nil),
            windows: [:],
            workspaces: [:],
            panes: [:],
            surfaces: [:],
            notifications: [:],
            focusedWorkspaceID: nil,
            focusedPaneID: nil,
            focusedSurfaceID: nil,
            cursor: CmuxEventCursor(),
            hostID: hostID
        )
        publish()
    }

    // MARK: - Snapshot ingestion

    public func ingestSnapshot(
        windows: [CmuxWindow],
        workspaces: [CmuxWorkspace],
        panes: [CmuxPane],
        surfaces: [CmuxSurface],
        notifications: [CmuxNotification],
        hostID: UUID? = nil
    ) {
        guard hostMatches(hostID) else { return }
        current.windows = OrderedDictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        current.workspaces = OrderedDictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        current.panes = OrderedDictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) })
        current.surfaces = OrderedDictionary(uniqueKeysWithValues: surfaces.map { ($0.id, $0) })
        current.notifications = OrderedDictionary(uniqueKeysWithValues: notifications.map { ($0.id, $0) })

        let selectedWorkspace = workspaces.first(where: { $0.isSelected })
        current.focusedWorkspaceID = selectedWorkspace?.id
        current.focusedPaneID = panes.first(where: { $0.isFocused })?.id
        current.focusedSurfaceID = surfaces.first(where: { $0.isFocused })?.id

        publish()
    }

    // MARK: - Event application

    public func apply(event: CmuxEventFrame.Event, hostID: UUID? = nil) {
        guard hostMatches(hostID) else { return }
        applyStateChanges(for: event)
        current.cursor.advance(to: event)
        publish()
    }

    /// Apply the visible state mutation for an event without advancing the
    /// replay cursor. `EventReactor` uses this split path so side effects
    /// like notifications and Live Activities complete before the cursor is
    /// persisted as delivered.
    public func applyWithoutCommittingCursor(event: CmuxEventFrame.Event, hostID: UUID? = nil) {
        guard hostMatches(hostID) else { return }
        applyStateChanges(for: event)
        publish()
    }

    public func commitCursor(event: CmuxEventFrame.Event, hostID: UUID? = nil) {
        guard hostMatches(hostID) else { return }
        current.cursor.advance(to: event)
        publish()
    }

    private func applyStateChanges(for event: CmuxEventFrame.Event) {
        switch event.category {
        case "workspace":
            applyWorkspaceEvent(event)
        case "window":
            applyWindowEvent(event)
        case "pane":
            applyPaneEvent(event)
        case "surface":
            applySurfaceEvent(event)
        case "notification":
            applyNotificationEvent(event)
        default:
            // Other categories (browser, feed, agent, sidebar, app, config)
            // do not currently affect the rendered iOS state. They flow
            // through ResumeJournal for later consumers (e.g. App Intents).
            break
        }
    }

    public func resetCursor(for ack: CmuxEventFrame.Ack, hostID: UUID? = nil) {
        guard hostMatches(hostID) else { return }
        current.cursor.reset(for: ack)
        publish()
    }

    /// Pre-seed the cursor from the persisted resume journal. Unlike
    /// `resetCursor(for:)` this preserves the `seq` so the next
    /// `events.stream` call resumes from the right point even before any
    /// real ack has been observed.
    public func seedCursor(_ cursor: CmuxEventCursor, hostID: UUID? = nil) {
        guard hostMatches(hostID) else { return }
        current.cursor = cursor
        publish()
    }

    // MARK: - Workspace events

    private func applyWorkspaceEvent(_ event: CmuxEventFrame.Event) {
        guard let workspaceID = event.workspaceID else { return }
        switch event.name {
        case "workspace.selected":
            current.focusedWorkspaceID = workspaceID
        case "workspace.closed":
            current.workspaces.removeValue(forKey: workspaceID)
        case "workspace.renamed":
            if let title = decodePayloadString(event.payload, key: "title") {
                if var workspace = current.workspaces[workspaceID] {
                    workspace = CmuxWorkspace(
                        id: workspace.id,
                        windowID: workspace.windowID,
                        index: workspace.index,
                        title: title,
                        cwd: workspace.cwd,
                        branch: workspace.branch,
                        isPinned: workspace.isPinned,
                        isSelected: workspace.isSelected,
                        unreadCount: workspace.unreadCount,
                        isRemote: workspace.isRemote,
                        remoteHost: workspace.remoteHost,
                        remoteStatus: workspace.remoteStatus,
                        listeningPorts: workspace.listeningPorts
                    )
                    current.workspaces[workspaceID] = workspace
                }
            }
        default:
            break
        }
    }

    private func applyWindowEvent(_ event: CmuxEventFrame.Event) {
        guard let windowID = event.windowID else { return }
        switch event.name {
        case "window.closed":
            current.windows.removeValue(forKey: windowID)
        case "window.keyed":
            // Promote the keyed window; touch the snapshot generation only.
            _ = windowID
        default:
            break
        }
    }

    private func applyPaneEvent(_ event: CmuxEventFrame.Event) {
        guard let paneID = event.paneID else { return }
        switch event.name {
        case "pane.closed":
            current.panes.removeValue(forKey: paneID)
        case "pane.focused":
            current.focusedPaneID = paneID
        default:
            break
        }
    }

    private func applySurfaceEvent(_ event: CmuxEventFrame.Event) {
        guard let surfaceID = event.surfaceID else { return }
        switch event.name {
        case "surface.closed":
            current.surfaces.removeValue(forKey: surfaceID)
        case "surface.focused":
            current.focusedSurfaceID = surfaceID
        case "surface.selected":
            if let paneID = event.paneID, var pane = current.panes[paneID] {
                pane = CmuxPane(
                    id: pane.id,
                    workspaceID: pane.workspaceID,
                    isFocused: pane.isFocused,
                    selectedSurfaceID: surfaceID,
                    frame: pane.frame
                )
                current.panes[paneID] = pane
            }
        default:
            break
        }
    }

    private func applyNotificationEvent(_ event: CmuxEventFrame.Event) {
        switch event.name {
        case "notification.created":
            guard let notificationID = decodePayloadString(event.payload, key: "notification_id")
            else { return }
            let notification = CmuxNotification(
                id: NotificationID(notificationID),
                workspaceID: event.workspaceID,
                surfaceID: event.surfaceID,
                title: decodePayloadString(event.payload, key: "title"),
                subtitle: decodePayloadString(event.payload, key: "subtitle"),
                body: decodePayloadString(event.payload, key: "body"),
                tabTitle: decodePayloadString(event.payload, key: "tab_title"),
                createdAt: event.occurredAt,
                isRead: false
            )
            current.notifications[NotificationID(notificationID)] = notification
        case "notification.read":
            for id in notificationIDs(from: event) {
                guard var n = current.notifications[id] else { continue }
                n = CmuxNotification(
                    id: n.id,
                    workspaceID: n.workspaceID,
                    surfaceID: n.surfaceID,
                    title: n.title,
                    subtitle: n.subtitle,
                    body: n.body,
                    tabTitle: n.tabTitle,
                    createdAt: n.createdAt,
                    isRead: true
                )
                current.notifications[id] = n
            }
        case "notification.removed":
            for id in notificationIDs(from: event) {
                current.notifications.removeValue(forKey: id)
            }
        case "notification.cleared":
            let ids = notificationIDs(from: event)
            if ids.isEmpty {
                current.notifications.removeAll()
            } else {
                for id in ids {
                    current.notifications.removeValue(forKey: id)
                }
            }
        default:
            break
        }
    }

    private func notificationIDs(from event: CmuxEventFrame.Event) -> [NotificationID] {
        if let ids = decodePayloadStringArray(event.payload, key: "notification_ids") {
            return ids.map { NotificationID($0) }
        }
        if let id = decodePayloadString(event.payload, key: "notification_id") {
            return [NotificationID(id)]
        }
        return []
    }

    private func decodePayloadString(_ payload: Data, key: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        return object[key] as? String
    }

    private func decodePayloadStringArray(_ payload: Data, key: String) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        return object[key] as? [String]
    }
}
