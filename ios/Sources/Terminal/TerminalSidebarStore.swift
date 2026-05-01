import Combine
import Foundation
import Network
import OSLog
import SwiftUI
import UIKit

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "terminal.store")

enum TerminalSessionUpdate {
    case phase(TerminalConnectionPhase, String?)
    case preview(String, Date)
    case bell(Date)
    case trustedHostKey(String)
    case pendingHostKey(String)
    case remoteDaemonResumeState(TerminalRemoteDaemonResumeState?)
}

enum TerminalWorkspaceOpenSource: String, Sendable {
    case terminals
    case inbox
    case push
}

struct TerminalNetworkPathState: Equatable, Sendable {
    var isReachable: Bool
    var signature: String
}

protocol TerminalNetworkPathMonitoring {
    var currentState: TerminalNetworkPathState? { get }
    var statePublisher: AnyPublisher<TerminalNetworkPathState, Never> { get }
}

final class TerminalNetworkPathMonitor: TerminalNetworkPathMonitoring {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "TerminalNetworkPathMonitor.queue")
    private let subject = CurrentValueSubject<TerminalNetworkPathState?, Never>(nil)

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            self?.subject.send(Self.makeState(from: path))
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    var currentState: TerminalNetworkPathState? {
        subject.value
    }

    var statePublisher: AnyPublisher<TerminalNetworkPathState, Never> {
        subject
            .compactMap { $0 }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private static func makeState(from path: NWPath) -> TerminalNetworkPathState {
        let usedInterfaces = [
            NWInterface.InterfaceType.wifi,
            .cellular,
            .wiredEthernet,
            .loopback,
            .other,
        ]
        .filter { path.usesInterfaceType($0) }
        .map(interfaceLabel(_:))
        .joined(separator: ",")

        let statusLabel: String = switch path.status {
        case .satisfied:
            "satisfied"
        case .requiresConnection:
            "requires-connection"
        case .unsatisfied:
            "unsatisfied"
        @unknown default:
            "unknown"
        }

        let signature = [
            statusLabel,
            usedInterfaces,
            path.isExpensive ? "expensive" : "standard",
            path.isConstrained ? "constrained" : "unconstrained",
        ]
        .joined(separator: "|")

        return TerminalNetworkPathState(
            isReachable: path.status == .satisfied,
            signature: signature
        )
    }

    private static func interfaceLabel(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi:
            return "wifi"
        case .cellular:
            return "cellular"
        case .wiredEthernet:
            return "wired"
        case .loopback:
            return "loopback"
        case .other:
            return "other"
        @unknown default:
            return "unknown"
        }
    }
}

@MainActor
private func makeTerminalSurface(delegate: GhosttySurfaceViewDelegate) throws -> any TerminalSurfaceHosting {
    let runtime = try GhosttyRuntime.shared()
    return GhosttySurfaceView(runtime: runtime, delegate: delegate)
}

typealias TerminalSessionControllerFactory = @MainActor (
    TerminalWorkspace,
    TerminalHost,
    TerminalCredentialsStoring,
    TerminalTransportFactory
) -> TerminalSessionController

typealias TerminalWorkspaceListFetcher = @Sendable (TerminalHost) async throws -> TerminalRemoteDaemonWorkspaceListResult
typealias TerminalWorkspaceSubscriptionStarter = @Sendable (
    TerminalHost,
    @escaping @Sendable (TerminalDaemonConnectionEvent) -> Void
) async -> Bool

@MainActor
protocol TerminalRemoteWorkspaceReadMarking {
    func markRead(item: UnifiedInboxItem) async throws
}

@MainActor
struct LiveTerminalRemoteWorkspaceReadMarker: TerminalRemoteWorkspaceReadMarking {
    private let routeClient: MobileWorkspaceReadRouteClient

    init(routeClient: MobileWorkspaceReadRouteClient? = nil) {
        self.routeClient = routeClient ?? MobileWorkspaceReadRouteClient()
    }

    func markRead(item: UnifiedInboxItem) async throws {
        try await routeClient.markRead(item: item)
    }
}

@MainActor
@Observable
final class TerminalSidebarStore {
    private(set) var hosts: [TerminalHost]
    private(set) var workspaces: [TerminalWorkspace]
    var selectedWorkspaceID: TerminalWorkspace.ID?

    private let snapshotStore: TerminalSnapshotPersisting
    private let credentialsStore: TerminalCredentialsStoring
    private let transportFactory: TerminalTransportFactory
    private let workspaceIdentityService: TerminalWorkspaceIdentityReserving?
    private let workspaceMetadataService: TerminalWorkspaceMetadataStreaming?
    private let serverDiscovery: TerminalServerDiscovering?
    private let networkPathMonitor: TerminalNetworkPathMonitoring?
    private let remoteWorkspaceReadMarker: TerminalRemoteWorkspaceReadMarking?
    private let analyticsTracker: MobileAnalyticsTracking?
    private let eagerlyRestoreSessions: Bool
    private let controllerFactory: TerminalSessionControllerFactory
    private let workspaceListFetcher: TerminalWorkspaceListFetcher
    private let workspaceSubscriptionStarter: TerminalWorkspaceSubscriptionStarter

    private var controllers: [TerminalWorkspace.ID: TerminalSessionController] = [:]
    private var workspaceIdentityTasks: [TerminalWorkspace.ID: Task<Void, Never>] = [:]
    private var workspaceMetadataCancellables: [TerminalWorkspace.ID: AnyCancellable] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var notificationObservers: [NSObjectProtocol] = []
    private var lastNetworkPathState: TerminalNetworkPathState?
    private var attachAttemptStartedAt: [TerminalWorkspace.ID: Date] = [:]
    private var reportedAttachResults: [TerminalWorkspace.ID: String] = [:]
    private var workspaceIDReplacements: [TerminalWorkspace.ID: TerminalWorkspace.ID] = [:]
    private var lastKnownWorkspacesByID: [TerminalWorkspace.ID: TerminalWorkspace] = [:]
    private var lastAppliedWorkspaceChangeSeqByStableID: [String: UInt64] = [:]
    private var pendingWorkspaceSnapshotSeqByStableID: [String: UInt64] = [:]
    private var visibleWorkspaceIDs: Set<TerminalWorkspace.ID> = []

    init(
        snapshotStore: TerminalSnapshotPersisting = TerminalSnapshotStore(),
        credentialsStore: TerminalCredentialsStoring = TerminalKeychainStore(),
        transportFactory: TerminalTransportFactory = DefaultTerminalTransportFactory(),
        workspaceIdentityService: TerminalWorkspaceIdentityReserving? = nil,
        workspaceMetadataService: TerminalWorkspaceMetadataStreaming? = nil,
        serverDiscovery: TerminalServerDiscovering? = nil,
        networkPathMonitor: TerminalNetworkPathMonitoring? = TerminalNetworkPathMonitor(),
        remoteWorkspaceReadMarker: TerminalRemoteWorkspaceReadMarking? = nil,
        analyticsTracker: MobileAnalyticsTracking? = nil,
        eagerlyRestoreSessions: Bool = true,
        controllerFactory: TerminalSessionControllerFactory? = nil,
        workspaceListFetcher: TerminalWorkspaceListFetcher? = nil,
        workspaceSubscriptionStarter: TerminalWorkspaceSubscriptionStarter? = nil
    ) {
        self.snapshotStore = snapshotStore
        self.credentialsStore = credentialsStore
        self.transportFactory = transportFactory
        self.workspaceIdentityService = workspaceIdentityService
        self.workspaceMetadataService = workspaceMetadataService
        self.serverDiscovery = serverDiscovery
        self.networkPathMonitor = networkPathMonitor
        self.remoteWorkspaceReadMarker = remoteWorkspaceReadMarker ?? LiveTerminalRemoteWorkspaceReadMarker()
        self.analyticsTracker = analyticsTracker ?? MobileAnalyticsClient()
        self.eagerlyRestoreSessions = eagerlyRestoreSessions
        self.controllerFactory = controllerFactory ?? { workspace, host, credentialsStore, transportFactory in
            TerminalSessionController(
                workspace: workspace,
                host: host,
                credentialsStore: credentialsStore,
                transportFactory: transportFactory
            )
        }
        self.workspaceListFetcher = workspaceListFetcher ?? { host in
            guard let wsPort = host.wsPort else {
                throw TerminalWebSocketTransportError.invalidURL
            }
            let connection = TerminalDaemonConnectionPool.shared.connection(
                stableID: host.stableID,
                hostname: host.hostname,
                port: wsPort,
                secret: host.wsSecret ?? ""
            )
            return try await connection.fetchWorkspaceList()
        }
        self.workspaceSubscriptionStarter = workspaceSubscriptionStarter ?? { host, onEvent in
            guard let wsPort = host.wsPort else { return false }
            let connection = TerminalDaemonConnectionPool.shared.connection(
                stableID: host.stableID,
                hostname: host.hostname,
                port: wsPort,
                secret: host.wsSecret ?? ""
            )
            return await connection.startWorkspaceSubscription(onEvent: onEvent)
        }

        let snapshot = snapshotStore.load()
        self.hosts = snapshot.hosts.sorted(by: { $0.sortIndex < $1.sortIndex })
        self.workspaces = snapshot.workspaces.sorted(by: { $0.lastActivity > $1.lastActivity })
        self.selectedWorkspaceID = snapshot.selectedWorkspaceID ?? self.workspaces.first?.id
        rememberWorkspaces(self.workspaces)

        observeServerDiscovery()
        observeNetworkPath()
        observeWorkspaceMetadata()
        if eagerlyRestoreSessions {
            rebuildControllers()
        }
        observeLifecycle()
    }

    deinit {
        MainActor.assumeIsolated {
            workspaceIdentityTasks.values.forEach { $0.cancel() }
            workspaceMetadataCancellables.values.forEach { $0.cancel() }
            notificationObservers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    func server(for id: TerminalHost.ID) -> TerminalHost? {
        hosts.first(where: { $0.id == id })
    }

    func workspace(with id: TerminalWorkspace.ID) -> TerminalWorkspace? {
        workspaces.first(where: { $0.id == id })
    }

    func workspaceResolvingReplacement(with id: TerminalWorkspace.ID) -> TerminalWorkspace? {
        if let workspace = workspace(with: id) {
            return workspace
        }
        let resolvedID = resolvedWorkspaceID(for: id)
        if let workspace = workspace(with: resolvedID) {
            return workspace
        }
        guard let previous = lastKnownWorkspacesByID[id] else {
            return nil
        }
        return replacementWorkspace(for: previous)
    }

    private func resolvedWorkspaceID(for id: TerminalWorkspace.ID) -> TerminalWorkspace.ID {
        var current = id
        var seen = Set<TerminalWorkspace.ID>()
        while let next = workspaceIDReplacements[current], !seen.contains(next) {
            seen.insert(current)
            current = next
        }
        return current
    }

    func workspaceCount(for host: TerminalHost) -> Int {
        workspaces.filter { $0.hostID == host.id }.count
    }

    func isConfigured(_ host: TerminalHost) -> Bool {
        guard host.isConfigured else { return false }
        if !host.requiresSavedSSHPassword {
            if !host.requiresSavedSSHPrivateKey {
                return true
            }
        }
        return credentialsStore.sshCredentials(for: host.id).hasCredential(for: host.sshAuthenticationMethod)
    }

    @discardableResult
    func openWorkspace(
        _ workspace: TerminalWorkspace,
        source: TerminalWorkspaceOpenSource = .terminals,
        unreadCount: Int? = nil
    ) -> TerminalWorkspace.ID {
        selectedWorkspaceID = workspace.id
        setUnread(false, for: workspace.id)
        persist()
        ensureBackendIdentityIfNeeded(for: workspace.id)
        startWorkspaceMetadataObservationIfNeeded(for: workspace.id)
        trackWorkspaceOpened(workspaceID: workspace.id, source: source, unreadCount: unreadCount)
        return workspace.id
    }

    @discardableResult
    func openInboxWorkspace(
        _ item: UnifiedInboxItem,
        source: TerminalWorkspaceOpenSource = .inbox
    ) -> TerminalWorkspace.ID? {
        guard item.kind == .workspace,
              let machineID = item.machineID,
              let tmuxSessionName = item.tmuxSessionName else {
            return nil
        }

        let host = upsertRemoteHost(for: item, machineID: machineID)
        let workspaceID: TerminalWorkspace.ID

        if let existingIndex = workspaces.firstIndex(where: {
            if item.workspaceID != nil, !$0.isRemoteWorkspace {
                return false
            }
            return $0.remoteWorkspaceID == item.workspaceID ||
                ($0.hostID == host.id && $0.tmuxSessionName == tmuxSessionName)
        }) {
            workspaces[existingIndex].hostID = host.id
            workspaces[existingIndex].title = item.title
            workspaces[existingIndex].tmuxSessionName = tmuxSessionName
            workspaces[existingIndex].preview = item.preview
            workspaces[existingIndex].lastActivity = item.sortDate
            workspaces[existingIndex].unread = item.isUnread
            workspaces[existingIndex].remoteWorkspaceID = item.workspaceID
            workspaceID = workspaces[existingIndex].id
            sortWorkspaces()
        } else {
            let workspace = TerminalWorkspace(
                hostID: host.id,
                title: item.title,
                tmuxSessionName: tmuxSessionName,
                preview: item.preview,
                lastActivity: item.sortDate,
                unread: item.isUnread,
                remoteWorkspaceID: item.workspaceID
            )
            workspaces.insert(workspace, at: 0)
            workspaceID = workspace.id
        }

        if item.isUnread {
            Task { [remoteWorkspaceReadMarker] in
                do {
                    try await remoteWorkspaceReadMarker?.markRead(item: item)
                } catch {
                    #if DEBUG
                    log.error("Failed to mark remote workspace read: \(error.localizedDescription, privacy: .public)")
                    #endif
                }
            }
        }

        guard let workspace = self.workspace(with: workspaceID) else {
            return nil
        }
        return openWorkspace(workspace, source: source, unreadCount: item.unreadCount)
    }

    @discardableResult
    func startWorkspace(on host: TerminalHost) -> TerminalWorkspace.ID {
        let nextIndex = workspaceCount(for: host) + 1
        let title = nextIndex == 1 ? "\(host.name)" : "\(host.name) \(nextIndex)"
        // Insert a placeholder workspace immediately so the UI updates
        // without waiting for a daemon round-trip. The placeholder
        // tmuxSessionName is replaced below with the daemon-minted
        // session_id once `workspace.create` + `workspace.open_pane`
        // returns, which is the value iOS + any other attached client
        // (mac, another phone) will use to attach.
        let placeholderSession = "cmux-pending-\(UUID().terminalShortID)"
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: title,
            tmuxSessionName: placeholderSession,
            preview: host.subtitle,
            lastActivity: .now,
            unread: false,
            phase: .connecting
        )
        workspaces.insert(workspace, at: 0)
        selectedWorkspaceID = workspace.id
        persist()
        ensureBackendIdentityIfNeeded(for: workspace.id)
        startWorkspaceMetadataObservationIfNeeded(for: workspace.id)

        // Daemon-authoritative path: if the host speaks remote-daemon,
        // ask the daemon to mint the workspace + pane and swap in the
        // returned session_id. This is what lets mac + other clients
        // see and attach to the same shell.
        if host.transportPreference == .remoteDaemon, let connection = daemonConnection(for: host) {
            let workspaceID = workspace.id
            let workspaceTitle = title
            let directory = host.subtitle
            Task { [weak self] in
                do {
                    let created = try await connection.acquireClient().0.workspaceCreate(
                        title: workspaceTitle,
                        directory: directory.isEmpty ? nil : directory
                    )
                    let opened = try await connection.acquireClient().0.workspaceOpenPane(
                        workspaceID: created.workspaceID,
                        command: "TERM=xterm-256color COLORTERM=truecolor /bin/zsh -l",
                        cols: 80,
                        rows: 24
                    )
                    await MainActor.run {
                        self?.applyDaemonMintedIdentity(
                            workspaceID: workspaceID,
                            remoteWorkspaceID: created.workspaceID,
                            sessionID: opened.sessionID
                        )
                    }
                } catch {
                    log.error("startWorkspace: daemon open_pane failed: \((error as NSError).localizedDescription, privacy: .public)")
                    await MainActor.run { self?.markWorkspaceFailed(workspaceID: workspaceID) }
                }
            }
        }
        return workspace.id
    }

    /// Called on the main actor once `workspace.create` +
    /// `workspace.open_pane` returns. Swaps the placeholder
    /// `tmuxSessionName` for the daemon-minted `session_id` and
    /// records the `remoteWorkspaceID` so the UI row maps to the
    /// daemon's workspace entry.
    private func applyDaemonMintedIdentity(
        workspaceID: TerminalWorkspace.ID,
        remoteWorkspaceID: String,
        sessionID: String
    ) {
        guard let idx = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        var updated = workspaces[idx]
        updated.tmuxSessionName = sessionID
        updated.remoteWorkspaceID = remoteWorkspaceID
        updated.phase = .idle
        workspaces[idx] = updated
        persist()
    }

    /// Mark a workspace that failed to materialize on the daemon so
    /// the UI shows a distinct state instead of a silent hang.
    private func markWorkspaceFailed(workspaceID: TerminalWorkspace.ID) {
        guard let idx = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        var updated = workspaces[idx]
        updated.phase = .failed
        workspaces[idx] = updated
        persist()
    }

    func closeWorkspace(_ workspace: TerminalWorkspace) {
        cancelWorkspaceIdentityReservation(for: workspace.id)
        cancelWorkspaceMetadataObservation(for: workspace.id)
        controllers[workspace.id]?.disconnect()
        controllers.removeValue(forKey: workspace.id)
        workspaces.removeAll { $0.id == workspace.id }
        visibleWorkspaceIDs.remove(workspace.id)
        if selectedWorkspaceID == workspace.id {
            selectedWorkspaceID = workspaces.first?.id
        }
        syncVisibleControllerLifecycle()
        persist()
    }

    func toggleUnread(for workspaceID: TerminalWorkspace.ID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[index].unread.toggle()
        persist()
    }

    func renameWorkspace(_ workspaceID: TerminalWorkspace.ID, to name: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let workspace = workspaces[index]
        workspaces[index].title = name
        persist()

        // Send rename to server for remote workspaces so other devices pick it up
        if let remoteID = workspace.remoteWorkspaceID,
           let host = server(for: workspace.hostID),
           let connection = daemonConnection(for: host) {
            Task.detached {
                try? await connection.workspaceRename(workspaceID: remoteID, title: name)
            }
        }
    }

    func togglePinned(for workspaceID: TerminalWorkspace.ID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[index].pinned.toggle()
        persist()

        // Sync pinned state back to the daemon so macOS and other clients
        // pick it up via workspace.changed push.
        let workspace = workspaces[index]
        if let remoteID = workspace.remoteWorkspaceID,
           let host = server(for: workspace.hostID),
           let connection = daemonConnection(for: host) {
            let pinned = workspace.pinned
            Task.detached {
                try? await connection.workspacePin(workspaceID: remoteID, pinned: pinned)
            }
        }
    }

    func controller(for workspace: TerminalWorkspace) -> TerminalSessionController {
        if let existing = controllers[workspace.id] {
            if var host = server(for: workspace.hostID) {
                applyDebugWebSocketConfig(&host)
                existing.refreshHost(host)
            }
            existing.refreshWorkspace(workspace)
            return existing
        }

        guard var host = server(for: workspace.hostID) else {
            let controller = TerminalSessionController.unavailable(workspaceID: workspace.id)
            controllers[workspace.id] = controller
            return controller
        }

        applyDebugWebSocketConfig(&host)
        if let idx = hosts.firstIndex(where: { $0.id == host.id }), hosts[idx].wsPort != host.wsPort {
            hosts[idx] = host
        }
        #if DEBUG
        log.debug("controller(for:) host=\(host.hostname, privacy: .public) wsPort=\(String(describing: host.wsPort), privacy: .public) hasWS=\(host.hasWebSocketEndpoint, privacy: .public)")
        #endif

        let controller = makeController(for: workspace, host: host)
        controllers[workspace.id] = controller
        return controller
    }

    func saveHost(_ host: TerminalHost, credentials: TerminalSSHCredentials) {
        var host = host
        host.trustedHostKey = host.trustedHostKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        host.pendingHostKey = host.pendingHostKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.trustedHostKey?.isEmpty == true {
            host.trustedHostKey = nil
        }
        if host.pendingHostKey?.isEmpty == true || host.pendingHostKey == host.trustedHostKey {
            host.pendingHostKey = nil
        }
        host.directTLSPins = host.directTLSPins.normalizedTerminalPins

        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            host.sortIndex = hosts.count
            hosts.append(host)
        }

        try? credentialsStore.setSSHCredentials(credentials, for: host.id)
        hosts.sort(by: { $0.sortIndex < $1.sortIndex })

        for workspace in workspaces where workspace.hostID == host.id {
            controllers[workspace.id]?.refreshHost(host)
        }

        persist()

        // If this host has a wsPort, make sure the main sidebar starts a
        // workspace subscription for it immediately. Without this, a host
        // added via the Find Servers sheet would appear as a pin with zero
        // workspaces until the next background discovery tick (which may
        // not cover it at all if its hostname isn't in the probe range).
        ensureWorkspaceSync(for: host)
        // Also hand it to the discovery so its periodic probe starts
        // watching it for reachability changes.
        if let discovery = serverDiscovery as? TailscaleServerDiscovery {
            discovery.addHost(host)
        }
    }

    func deleteHost(_ host: TerminalHost) {
        hosts.removeAll { $0.id == host.id }
        try? credentialsStore.setSSHCredentials(TerminalSSHCredentials(password: nil, privateKey: nil), for: host.id)

        let removedWorkspaceIDs = Set(workspaces.filter { $0.hostID == host.id }.map(\.id))
        removedWorkspaceIDs.forEach { cancelWorkspaceIdentityReservation(for: $0) }
        removedWorkspaceIDs.forEach { cancelWorkspaceMetadataObservation(for: $0) }
        removedWorkspaceIDs.forEach { controllers[$0]?.disconnect() }
        removedWorkspaceIDs.forEach { controllers.removeValue(forKey: $0) }
        workspaces.removeAll { removedWorkspaceIDs.contains($0.id) }
        visibleWorkspaceIDs.subtract(removedWorkspaceIDs)

        if let selectedWorkspaceID, removedWorkspaceIDs.contains(selectedWorkspaceID) {
            self.selectedWorkspaceID = workspaces.first?.id
        }

        syncVisibleControllerLifecycle()
        persist()
    }

    func password(for host: TerminalHost) -> String {
        credentialsStore.password(for: host.id) ?? ""
    }

    func credentials(for host: TerminalHost) -> TerminalSSHCredentials {
        credentialsStore.sshCredentials(for: host.id)
    }

    func newHostDraft() -> TerminalHost {
        TerminalHost(
            name: TerminalStoreStrings.newServerName,
            hostname: "",
            username: "",
            symbolName: "server.rack",
            palette: TerminalHostPalette.allCases[hosts.count % TerminalHostPalette.allCases.count],
            sortIndex: hosts.count
        )
    }

    nonisolated static func debugLog(_ msg: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        let path = NSHomeDirectory() + "/Documents/cmux-ios-debug.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
    }

    func applyDiscoveredHosts(_ discoveredHosts: [TerminalHost]) {
        Self.debugLog("applyDiscoveredHosts: \(discoveredHosts.count) hosts")
        for h in discoveredHosts {
            Self.debugLog("  host: \(h.stableID) status=\(String(describing: h.machineStatus)) seq=\(String(describing: h.daemonWorkspaceChangeSeq)) name=\(h.name)")
        }
        let existingHostsByID = Dictionary(hosts.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var mergedHosts = TerminalServerCatalog.merge(discovered: discoveredHosts, local: hosts)
        let mergedHostIDs = Set(mergedHosts.map(\.id))
        let workspaceHostIDs = Set(workspaces.map(\.hostID))
        let missingWorkspaceHostIDs = workspaceHostIDs.subtracting(mergedHostIDs)
        let removedWorkspaceIDs = Set<TerminalWorkspace.ID>()

        for hostID in missingWorkspaceHostIDs {
            guard let preservedHost = existingHostsByID[hostID] else { continue }
            if preservedHost.source == .discovered {
                var offlineHost = preservedHost
                offlineHost.machineStatus = .offline
                mergedHosts.append(offlineHost)
                for index in workspaces.indices where workspaces[index].hostID == hostID {
                    workspaces[index].phase = .disconnected
                }
            } else {
                mergedHosts.append(preservedHost)
            }
        }

        if !removedWorkspaceIDs.isEmpty {
            for workspaceID in removedWorkspaceIDs {
                cancelWorkspaceIdentityReservation(for: workspaceID)
                cancelWorkspaceMetadataObservation(for: workspaceID)
                controllers[workspaceID]?.disconnect()
                controllers.removeValue(forKey: workspaceID)
            }
            workspaces.removeAll { removedWorkspaceIDs.contains($0.id) }
            if let selectedWorkspaceID, removedWorkspaceIDs.contains(selectedWorkspaceID) {
                self.selectedWorkspaceID = workspaces.first?.id
            }
        }

        for index in mergedHosts.indices {
            applyDebugWebSocketConfig(&mergedHosts[index])
        }

        hosts = mergedHosts.sorted(by: { $0.sortIndex < $1.sortIndex })

        for host in hosts where host.wsPort != nil {
            ensureWorkspaceSync(for: host)
        }

        for index in workspaces.indices {
            guard let host = server(for: workspaces[index].hostID) else { continue }
            invalidateBackendLinkIfNeeded(for: index, host: host)
            let workspace = workspaces[index]
            controllers[workspace.id]?.refreshHost(host)
            ensureBackendIdentityIfNeeded(for: workspace.id)
            startWorkspaceMetadataObservationIfNeeded(for: workspace.id)
        }

        persist()
    }

    private func invalidateBackendLinkIfNeeded(for workspaceIndex: Int, host: TerminalHost) {
        let workspace = workspaces[workspaceIndex]
        guard let identity = workspace.backendIdentity else { return }

        let hostTeamID = normalizedTeamID(host.teamID)
        let identityTeamID = normalizedTeamID(identity.teamID)
        guard hostTeamID != identityTeamID else { return }

        cancelWorkspaceIdentityReservation(for: workspace.id)
        cancelWorkspaceMetadataObservation(for: workspace.id)
        workspaces[workspaceIndex].backendIdentity = nil
        workspaces[workspaceIndex].backendMetadata = nil
    }

    private func rebuildControllers() {
        controllers.removeAll()
        for workspace in workspaces {
            guard var host = server(for: workspace.hostID) else { continue }
            applyDebugWebSocketConfig(&host)
            if let idx = hosts.firstIndex(where: { $0.id == host.id }), hosts[idx].wsPort != host.wsPort {
                hosts[idx] = host
            }
            controllers[workspace.id] = makeController(for: workspace, host: host)
        }
    }

    func setWorkspaceDetailVisible(_ workspaceID: TerminalWorkspace.ID, visible: Bool) {
        let resolvedID = resolvedWorkspaceID(for: workspaceID)
        if visible {
            visibleWorkspaceIDs.insert(resolvedID)
        } else {
            visibleWorkspaceIDs.remove(workspaceID)
            visibleWorkspaceIDs.remove(resolvedID)
        }
        syncVisibleControllerLifecycle()
    }

    private func syncVisibleControllerLifecycle() {
        visibleWorkspaceIDs = Set(visibleWorkspaceIDs.compactMap { visibleID in
            let resolvedID = resolvedWorkspaceID(for: visibleID)
            return workspaces.contains(where: { $0.id == resolvedID }) ? resolvedID : nil
        })

        for (workspaceID, controller) in controllers where !visibleWorkspaceIDs.contains(workspaceID) {
            controller.suspendPreservingState()
        }

        for workspaceID in visibleWorkspaceIDs {
            guard let workspace = workspace(with: workspaceID) else { continue }
            controller(for: workspace).resumeIfNeeded()
            ensureBackendIdentityIfNeeded(for: workspace.id)
        }
    }

    private func observeServerDiscovery() {
        guard let serverDiscovery else { return }
        serverDiscovery.hostsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hosts in
                Self.debugLog("observeServerDiscovery: received \(hosts.count) hosts")
                self?.applyDiscoveredHosts(hosts)
            }
            .store(in: &cancellables)
    }

    /// Pooled daemon connections live in TerminalDaemonConnectionPool.shared,
    /// keyed by host stableID. Sidebar workspace subscription and terminal
    /// sessions share one URLSessionWebSocketTask + TerminalRemoteDaemonClient
    /// per daemon.
    fileprivate func daemonConnection(for host: TerminalHost) -> TerminalDaemonConnection? {
        guard let wsPort = host.wsPort else { return nil }
        return TerminalDaemonConnectionPool.shared.connection(
            stableID: host.stableID,
            hostname: host.hostname,
            port: wsPort,
            secret: host.wsSecret ?? ""
        )
    }

    private func ensureWorkspaceSync(for host: TerminalHost) {
        guard host.wsPort != nil else { return }
        startWorkspaceSubscription(for: host)
        refreshWorkspaceSnapshotIfNeeded(for: host)
    }

    /// Start a persistent WebSocket subscription for workspace changes.
    /// The TerminalDaemonConnection owns reconnect/backoff; we just consume
    /// the event stream and apply updates to the workspace store.
    private func startWorkspaceSubscription(for host: TerminalHost) {
        let stableID = host.stableID
        let hostname = host.hostname
        let port = host.wsPort ?? 0
        let starter = workspaceSubscriptionStarter

        Task { [weak self, starter, host, stableID, hostname, port] in
            let didStart = await starter(host) { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handleDaemonConnectionEvent(
                        event,
                        stableID: stableID,
                        hostname: hostname,
                        port: port
                    )
                }
            }
            if didStart {
                Self.debugLog("subscription: starting for \(hostname):\(port)")
            }
        }
    }

    private func refreshWorkspaceSnapshotIfNeeded(for host: TerminalHost) {
        guard let targetSeq = host.daemonWorkspaceChangeSeq else { return }
        let stableID = host.stableID
        if lastAppliedWorkspaceChangeSeqByStableID[stableID] == targetSeq {
            return
        }
        if pendingWorkspaceSnapshotSeqByStableID[stableID] == targetSeq {
            return
        }
        pendingWorkspaceSnapshotSeqByStableID[stableID] = targetSeq
        let hostID = host.id
        let hostname = host.hostname
        let port = host.wsPort ?? 0
        let fetcher = workspaceListFetcher

        Task { [weak self, host, stableID, hostID, hostname, port, targetSeq, fetcher] in
            do {
                let result = try await fetcher(host)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard let currentHost = self.hosts.first(where: {
                        $0.id == hostID ||
                            ($0.stableID == stableID && $0.hostname == hostname && $0.wsPort == port)
                    }) else {
                        self.pendingWorkspaceSnapshotSeqByStableID[stableID] = nil
                        return
                    }
                    self.applyRemoteWorkspaceList(result, hostID: currentHost.id, host: currentHost)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if self.pendingWorkspaceSnapshotSeqByStableID[stableID] == targetSeq {
                        self.pendingWorkspaceSnapshotSeqByStableID[stableID] = nil
                    }
                    Self.debugLog("subscription: workspace snapshot failed for \(hostname):\(port) seq=\(targetSeq) error=\(error.localizedDescription)")
                }
            }
        }
    }

    private func handleDaemonConnectionEvent(
        _ event: TerminalDaemonConnectionEvent,
        stableID: String,
        hostname: String,
        port: Int
    ) {
        switch event {
        case .connected:
            if let hostIdx = hosts.firstIndex(where: { $0.stableID == stableID }) {
                let previousStatus = hosts[hostIdx].machineStatus
                hosts[hostIdx].machineStatus = .online
                let didUpdateWorkspaces = markKnownRemoteWorkspacesConnected(for: hosts[hostIdx])
                if previousStatus != .online || didUpdateWorkspaces {
                    persist()
                }
            }
        case .connectFailed(let consecutive):
            Self.debugLog("subscription: connect failed (\(consecutive)) for \(hostname):\(port)")
            if consecutive >= 3 {
                if let hostIdx = hosts.firstIndex(where: { $0.stableID == stableID }) {
                    hosts[hostIdx].machineStatus = .offline
                }
                if let hostID = hosts.first(where: { $0.stableID == stableID })?.id {
                    for i in workspaces.indices where workspaces[i].hostID == hostID {
                        workspaces[i].phase = .disconnected
                    }
                }
            }
        case .workspacesJSON(let line):
            handleWorkspaceResponse(line, hostname: hostname, port: port, secret: "")
        case .disconnected:
            Self.debugLog("subscription: disconnected from \(hostname):\(port), connection will reconnect")
        }
    }

    @discardableResult
    private func markKnownRemoteWorkspacesConnected(for host: TerminalHost) -> Bool {
        guard host.transportPreference == .remoteDaemon, host.wsPort != nil else {
            return false
        }

        var didChange = false
        for index in workspaces.indices where workspaces[index].hostID == host.id {
            guard workspaces[index].isRemoteWorkspace,
                  Self.stableDaemonSessionID(workspaces[index].tmuxSessionName) != nil else {
                continue
            }

            switch workspaces[index].phase {
            case .idle, .disconnected:
                workspaces[index].phase = .connected
                workspaces[index].lastError = nil
                controllers[workspaces[index].id]?.refreshWorkspace(workspaces[index])
                didChange = true
            case .needsConfiguration, .connecting, .connected, .reconnecting, .failed:
                break
            }
        }

        if didChange {
            rememberWorkspaces(workspaces)
        }
        return didChange
    }

    private func handleWorkspaceResponse(_ response: String, hostname: String, port: Int, secret: String) {
        guard let jsonData = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let resultObj = json["result"] as? [String: Any],
              let workspaces = resultObj["workspaces"] as? [[String: Any]] else {
            ScannerLog.shared.log("subscription.parse_failed hostname=\(hostname) port=\(port)")
            return
        }
        let changeSeq = Self.uint64Value(resultObj["change_seq"]) ?? Self.uint64Value(json["change_seq"])

        ScannerLog.shared.log("subscription.workspaces hostname=\(hostname) port=\(port) count=\(workspaces.count)")
        for ws in workspaces {
            let sid = (ws["session_id"] as? String) ?? "none"
            let title = (ws["title"] as? String) ?? "?"
            ScannerLog.shared.log("  ws title=\(title) session_id=\(sid)")
        }

        // Match host by hostname+port since stableID format varies (localhost vs IP)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let resolvedHostID = self.hosts.first(where: {
                $0.hostname == hostname && $0.wsPort == port
            })?.id ?? self.hosts.first(where: {
                $0.stableID == "\(hostname)-\(port)"
            })?.id ?? self.hosts.first(where: {
                $0.stableID == "localhost-\(port)"
            })?.id
            guard let hostID = resolvedHostID else {
                ScannerLog.shared.log("subscription.host_not_found hostname=\(hostname) port=\(port) known=\(self.hosts.map(\.stableID))")
                return
            }
            let host = self.hosts.first(where: { $0.id == hostID }) ?? TerminalHost(
                stableID: "\(hostname)-\(port)", name: hostname, hostname: hostname,
                port: 22, username: "cmux", symbolName: "desktopcomputer",
                palette: .sky, source: .discovered, transportPreference: .remoteDaemon
            )
            self.applyRemoteWorkspaces(workspaces, hostID: hostID, host: host, changeSeq: changeSeq)
        }
    }

    private func applyRemoteWorkspaceList(
        _ result: TerminalRemoteDaemonWorkspaceListResult,
        hostID: UUID,
        host: TerminalHost
    ) {
        applyRemoteWorkspaces(
            Self.workspaceDictionaries(from: result),
            hostID: hostID,
            host: host,
            changeSeq: result.changeSeq
        )
    }

    func applyRemoteWorkspaces(
        _ data: [[String: Any]],
        hostID: UUID,
        host: TerminalHost,
        changeSeq: UInt64? = nil
    ) {
        let remoteIds = data.compactMap { $0["id"] as? String }
        let previousIDBySession = Dictionary(
            workspaces
                .filter { $0.hostID == hostID }
                .compactMap { workspace -> (String, TerminalWorkspace.ID)? in
                    guard let sessionID = Self.stableDaemonSessionID(workspace.tmuxSessionName) else {
                        return nil
                    }
                    return (sessionID, workspace.id)
                },
            uniquingKeysWith: { first, _ in first }
        )
        rememberWorkspaces(workspaces)
        let previousHostWorkspaces = workspaces.filter { $0.hostID == hostID }
        let previousTitleCounts = previousHostWorkspaces.reduce(into: [String: Int]()) { counts, workspace in
            let title = Self.normalizedWorkspaceTitle(workspace.title)
            guard !title.isEmpty else { return }
            counts[title, default: 0] += 1
        }
        let previousIDByUniqueTitle = Dictionary(
            previousHostWorkspaces.compactMap { workspace -> (String, TerminalWorkspace.ID)? in
                let title = Self.normalizedWorkspaceTitle(workspace.title)
                guard previousTitleCounts[title] == 1 else { return nil }
                return (title, workspace.id)
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Remove stale workspaces for this host. Two flavors to prune:
        //   1. remoteWorkspaceID set but not in the snapshot -> bound to a
        //      previous daemon instance whose workspace was removed or
        //      replaced (e.g. mac app restarted, daemon respawned).
        //   2. remoteWorkspaceID nil -> a locally-created placeholder whose
        //      daemon bind never succeeded, or pre-dates remoteWorkspaceID
        //      tracking. The daemon's snapshot is authoritative; if it
        //      doesn't know about a host workspace, iOS shouldn't keep
        //      showing it and letting users tap into a dead session.
        //
        // Grace window: keep placeholder rows created in the last 10s so an
        // in-flight startWorkspace → workspace.create RPC has time to land
        // before the next snapshot wipes the optimistic row.
        let remoteIdSet = Set(remoteIds)
        let graceCutoff = Date().addingTimeInterval(-10)
        workspaces.removeAll { ws in
            guard ws.hostID == hostID else { return false }
            if let remoteID = ws.remoteWorkspaceID {
                return !remoteIdSet.contains(remoteID)
            }
            return ws.lastActivity < graceCutoff
        }

        // Upsert workspaces preserving server order
        var updatedWorkspaces: [TerminalWorkspace] = []
        for wsData in data {
            guard let remoteId = wsData["id"] as? String else { continue }
            let title = wsData["title"] as? String ?? "Untitled"
            let preview = wsData["preview"] as? String ?? ""
            let unreadCount = wsData["unread_count"] as? Int ?? 0
            let lastActivityMs = wsData["last_activity_at"] as? Int64 ?? Int64(Date().timeIntervalSince1970 * 1000)
            let lastActivity = Date(timeIntervalSince1970: Double(lastActivityMs) / 1000)
            let pinned = wsData["pinned"] as? Bool ?? false
            let panesData = wsData["panes"] as? [[String: Any]] ?? []
            let panes: [TerminalPane] = panesData.compactMap { pane in
                guard let paneID = pane["id"] as? String else { return nil }
                return TerminalPane(
                    id: paneID,
                    sessionID: pane["session_id"] as? String,
                    title: pane["title"] as? String ?? "",
                    directory: pane["directory"] as? String ?? ""
                )
            }
            // Prefer the daemon's top-level session_id. macOS publishes the
            // focused terminal there, so opening a split workspace on iOS lands
            // on the same pane. Older daemons may omit it; fall back to the
            // first live pane instead of leaving the workspace stuck pending.
            let daemonSessionID = (wsData["session_id"] as? String) ?? panes.first?.sessionID

            if let existing = workspaces.first(where: { $0.remoteWorkspaceID == remoteId && $0.hostID == hostID }) {
                let localID = Self.localWorkspaceID(forRemoteWorkspaceID: remoteId, fallback: existing.id)
                var updated: TerminalWorkspace
                if localID == existing.id {
                    updated = existing
                } else {
                    cancelWorkspaceIdentityReservation(for: existing.id)
                    cancelWorkspaceMetadataObservation(for: existing.id)
                    controllers[existing.id]?.disconnect()
                    controllers.removeValue(forKey: existing.id)
                    if selectedWorkspaceID == existing.id {
                        selectedWorkspaceID = localID
                    }
                    updated = TerminalWorkspace(
                        id: localID,
                        hostID: existing.hostID,
                        title: existing.title,
                        tmuxSessionName: existing.tmuxSessionName,
                        preview: existing.preview,
                        lastActivity: existing.lastActivity,
                        unread: existing.unread,
                        pinned: existing.pinned,
                        phase: existing.phase,
                        lastError: existing.lastError,
                        remoteWorkspaceID: existing.remoteWorkspaceID,
                        backendIdentity: existing.backendIdentity,
                        backendMetadata: existing.backendMetadata,
                        remoteDaemonResumeState: existing.remoteDaemonResumeState
                    )
                    updated.panes = existing.panes
                }
                updated.title = title
                updated.lastActivity = lastActivity
                if !preview.isEmpty { updated.preview = preview }
                updated.unread = unreadCount > 0
                updated.pinned = pinned
                updated.panes = panes
                if let sid = daemonSessionID {
                    ScannerLog.shared.log("  ws.update title=\(title) sessionName=\(sid) (was \(existing.tmuxSessionName))")
                    updated.tmuxSessionName = sid
                    updated.phase = .connected
                } else if updated.tmuxSessionName.hasPrefix("pending-") || updated.tmuxSessionName.isEmpty {
                    // Still no daemon session; keep the placeholder and don't
                    // promote to .connected yet.
                    updated.phase = .connecting
                } else {
                    // Already had a real session id and mac temporarily stopped
                    // reporting it (happens during a brief workspace.sync with
                    // panes=[]). Keep the id we remember.
                    updated.phase = .connected
                }
                updatedWorkspaces.append(updated)
            } else {
                // PR 5 (SSOT refactor): never synthesize a `local-<id>` session
                // name. With the mac daemon SSOT, a workspace without a daemon
                // session_id is one the mac hasn't finished binding yet — show
                // it in "connecting" state until the real session_id lands via
                // workspace.changed. Tapping a connecting workspace shows a
                // reconnecting spinner instead of silently spawning a phantom
                // shell on a fake session name.
                let placeholderSession = "pending-\(remoteId)"
                var workspace = TerminalWorkspace(
                    id: Self.localWorkspaceID(forRemoteWorkspaceID: remoteId),
                    hostID: hostID,
                    title: title,
                    tmuxSessionName: daemonSessionID ?? placeholderSession,
                    remoteWorkspaceID: remoteId
                )
                workspace.lastActivity = lastActivity
                workspace.phase = (daemonSessionID != nil) ? .connected : .connecting
                if !preview.isEmpty { workspace.preview = preview }
                workspace.unread = unreadCount > 0
                workspace.pinned = pinned
                workspace.panes = panes
                updatedWorkspaces.append(workspace)
            }
        }

        for workspace in updatedWorkspaces {
            let sessionID = Self.stableDaemonSessionID(workspace.tmuxSessionName)
            let title = Self.normalizedWorkspaceTitle(workspace.title)
            guard let previousID = sessionID.flatMap({ previousIDBySession[$0] }) ?? previousIDByUniqueTitle[title],
                  previousID != workspace.id else {
                continue
            }
            workspaceIDReplacements[previousID] = workspace.id
            if selectedWorkspaceID == previousID {
                selectedWorkspaceID = workspace.id
            }
        }

        // Replace remote workspaces for this host with the server-ordered list,
        // preserving any non-remote workspaces
        let nonRemoteWorkspaces = workspaces.filter { $0.hostID != hostID || $0.remoteWorkspaceID == nil }
        workspaces = nonRemoteWorkspaces + updatedWorkspaces
        rememberWorkspaces(workspaces)
        let validWorkspaceIDs = Set(workspaces.map(\.id))
        for staleID in controllers.keys where !validWorkspaceIDs.contains(staleID) {
            controllers[staleID]?.disconnect()
            controllers.removeValue(forKey: staleID)
        }

        for workspace in workspaces {
            guard let controller = controllers[workspace.id] else { continue }
            if var refreshedHost = hosts.first(where: { $0.id == workspace.hostID }) {
                applyDebugWebSocketConfig(&refreshedHost)
                controller.refreshHost(refreshedHost)
            }
            controller.refreshWorkspace(workspace)
        }

        if let selectedWorkspaceID,
           !workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            let replacementID = resolvedWorkspaceID(for: selectedWorkspaceID)
            self.selectedWorkspaceID = workspaces.contains(where: { $0.id == replacementID }) ? replacementID : workspaces.first?.id
        }
        visibleWorkspaceIDs = Set(visibleWorkspaceIDs.compactMap { visibleID in
            let resolvedID = resolvedWorkspaceID(for: visibleID)
            return workspaces.contains(where: { $0.id == resolvedID }) ? resolvedID : nil
        })
        pruneWorkspaceIDReplacements()

        if let changeSeq {
            lastAppliedWorkspaceChangeSeqByStableID[host.stableID] = changeSeq
            pendingWorkspaceSnapshotSeqByStableID[host.stableID] = nil
        }

        Self.debugLog("applyRemoteWorkspaces: \(data.count) workspaces from host \(host.name)")
        syncVisibleControllerLifecycle()
        persist()
    }

    private static func workspaceDictionaries(from result: TerminalRemoteDaemonWorkspaceListResult) -> [[String: Any]] {
        result.workspaces.map { workspace in
            var entry: [String: Any] = [
                "id": workspace.id,
                "title": workspace.title,
                "directory": workspace.directory,
                "pane_count": workspace.paneCount,
                "created_at": workspace.createdAt,
                "last_activity_at": workspace.lastActivityAt,
            ]
            if let sessionID = workspace.sessionID { entry["session_id"] = sessionID }
            if let preview = workspace.preview { entry["preview"] = preview }
            if let unreadCount = workspace.unreadCount { entry["unread_count"] = unreadCount }
            if let pinned = workspace.pinned { entry["pinned"] = pinned }
            if let panes = workspace.panes {
                entry["panes"] = panes.map { pane in
                    var paneEntry: [String: Any] = ["id": pane.id]
                    if let sessionID = pane.sessionID { paneEntry["session_id"] = sessionID }
                    if let title = pane.title { paneEntry["title"] = title }
                    if let directory = pane.directory { paneEntry["directory"] = directory }
                    return paneEntry
                }
            }
            return entry
        }
    }

    private static func uint64Value(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 {
            return value
        }
        if let value = value as? Int, value >= 0 {
            return UInt64(value)
        }
        if let value = value as? NSNumber {
            return value.uint64Value
        }
        return nil
    }

    private static func localWorkspaceID(forRemoteWorkspaceID remoteWorkspaceID: String, fallback: UUID? = nil) -> UUID {
        UUID(uuidString: remoteWorkspaceID) ?? fallback ?? UUID()
    }

    private static func stableDaemonSessionID(_ sessionID: String) -> String? {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("pending-"),
              !trimmed.hasPrefix("local-") else {
            return nil
        }
        return trimmed
    }

    private static func normalizedWorkspaceTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func pruneWorkspaceIDReplacements() {
        let validIDs = Set(workspaces.map(\.id))
        workspaceIDReplacements = workspaceIDReplacements.filter { key, value in
            !validIDs.contains(key) && validIDs.contains(value)
        }
    }

    private func rememberWorkspaces(_ workspaces: [TerminalWorkspace]) {
        for workspace in workspaces {
            lastKnownWorkspacesByID[workspace.id] = workspace
        }
        if lastKnownWorkspacesByID.count > 200 {
            let validIDs = Set(self.workspaces.map(\.id)).union(Set(workspaceIDReplacements.keys))
            lastKnownWorkspacesByID = lastKnownWorkspacesByID.filter { id, _ in validIDs.contains(id) }
        }
    }

    private func replacementWorkspace(for previous: TerminalWorkspace) -> TerminalWorkspace? {
        if let sessionID = Self.stableDaemonSessionID(previous.tmuxSessionName),
           let sessionMatch = workspaces.first(where: { workspace in
               workspace.hostID == previous.hostID
                   && (workspace.tmuxSessionName == sessionID || workspace.panes.contains(where: { $0.sessionID == sessionID }))
           }) {
            return sessionMatch
        }

        let title = Self.normalizedWorkspaceTitle(previous.title)
        guard !title.isEmpty else { return nil }
        let titleMatches = workspaces.filter {
            $0.hostID == previous.hostID && Self.normalizedWorkspaceTitle($0.title) == title
        }
        return titleMatches.count == 1 ? titleMatches[0] : nil
    }


    private func observeNetworkPath() {
        guard let networkPathMonitor else { return }
        lastNetworkPathState = networkPathMonitor.currentState
        networkPathMonitor.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleNetworkPathUpdate(state)
            }
            .store(in: &cancellables)
    }

    private func handleNetworkPathUpdate(_ state: TerminalNetworkPathState) {
        let previousState = lastNetworkPathState
        lastNetworkPathState = state

        guard previousState != state else { return }

        if !state.isReachable {
            for controller in controllers.values {
                controller.suspendPreservingState()
            }
            return
        }

        if previousState?.isReachable == false {
            syncVisibleControllerLifecycle()
            return
        }

        guard previousState != nil,
              let visibleWorkspaceID = visibleWorkspaceIDs.first,
              let workspace = workspace(with: resolvedWorkspaceID(for: visibleWorkspaceID)) else {
            return
        }

        let controller = controller(for: workspace)
        switch controller.phase {
        case .connected, .connecting, .reconnecting:
            controller.reconnectNow()
        case .disconnected, .idle:
            controller.resumeIfNeeded()
        default:
            break
        }
    }

    #if DEBUG
    func simulateNetworkPathUpdateForTesting(_ state: TerminalNetworkPathState) {
        handleNetworkPathUpdate(state)
    }
    #endif

    private func makeController(for workspace: TerminalWorkspace, host: TerminalHost) -> TerminalSessionController {
        let controller = controllerFactory(
            workspace,
            host,
            credentialsStore,
            transportFactory
        )
        controller.onUpdate = { [weak self] update in
            self?.apply(update: update, to: workspace.id)
        }
        if controller.phase != workspace.phase || controller.errorMessage != workspace.lastError {
            apply(update: .phase(controller.phase, controller.errorMessage), to: workspace.id)
        }
        return controller
    }

    private func apply(update: TerminalSessionUpdate, to workspaceID: TerminalWorkspace.ID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        switch update {
        case .phase(let phase, let error):
            workspaces[index].phase = phase
            workspaces[index].lastError = error
            workspaces[index].lastActivity = .now
            trackAttachTransition(for: workspaces[index], phase: phase, error: error)
        case .preview(let preview, let date):
            workspaces[index].preview = preview
            workspaces[index].lastActivity = date
            if selectedWorkspaceID != workspaceID {
                workspaces[index].unread = true
            }
            sortWorkspaces()
        case .bell(let date):
            workspaces[index].lastActivity = date
            if selectedWorkspaceID != workspaceID {
                workspaces[index].unread = true
            }
            sortWorkspaces()
        case .trustedHostKey(let hostKey):
            guard let hostIndex = hosts.firstIndex(where: { $0.id == workspaces[index].hostID }) else { break }
            hosts[hostIndex].trustedHostKey = hostKey
            if hosts[hostIndex].pendingHostKey == hostKey {
                hosts[hostIndex].pendingHostKey = nil
            }
            controllers[workspaceID]?.refreshHost(hosts[hostIndex])
        case .pendingHostKey(let hostKey):
            guard let hostIndex = hosts.firstIndex(where: { $0.id == workspaces[index].hostID }) else { break }
            hosts[hostIndex].pendingHostKey = hostKey
        case .remoteDaemonResumeState(let state):
            workspaces[index].remoteDaemonResumeState = state
        }
        persist()
    }

    private func trackWorkspaceOpened(
        workspaceID: TerminalWorkspace.ID,
        source: TerminalWorkspaceOpenSource,
        unreadCount: Int?
    ) {
        guard let workspace = workspace(with: workspaceID),
              workspace.isRemoteWorkspace,
              let host = server(for: workspace.hostID),
              let remoteWorkspaceID = workspace.remoteWorkspaceID,
              let machineID = analyticsMachineID(for: host) else {
            return
        }

        analyticsTracker?.capture(
            event: .mobileWorkspaceOpened,
            properties: MobileAnalyticsProperties(
                teamId: host.teamID,
                machineId: machineID,
                workspaceId: remoteWorkspaceID,
                source: source.rawValue,
                unreadCount: unreadCount
            )
        )
    }

    private func trackAttachTransition(
        for workspace: TerminalWorkspace,
        phase: TerminalConnectionPhase,
        error: String?
    ) {
        guard workspace.isRemoteWorkspace,
              let host = server(for: workspace.hostID),
              let remoteWorkspaceID = workspace.remoteWorkspaceID,
              let machineID = analyticsMachineID(for: host) else {
            attachAttemptStartedAt.removeValue(forKey: workspace.id)
            reportedAttachResults.removeValue(forKey: workspace.id)
            return
        }

        switch phase {
        case .connecting, .reconnecting:
            attachAttemptStartedAt[workspace.id] = Date()
            reportedAttachResults.removeValue(forKey: workspace.id)
        case .connected:
            guard reportedAttachResults[workspace.id] != "success" else { return }
            analyticsTracker?.capture(
                event: .mobileDaemonAttachResult,
                properties: MobileAnalyticsProperties(
                    teamId: host.teamID,
                    machineId: machineID,
                    workspaceId: remoteWorkspaceID,
                    source: "direct_daemon",
                    result: "success",
                    latencyMs: attachLatencyMs(for: workspace.id)
                )
            )
            reportedAttachResults[workspace.id] = "success"
            attachAttemptStartedAt.removeValue(forKey: workspace.id)
        case .failed:
            guard reportedAttachResults[workspace.id] != "failure" else { return }
            analyticsTracker?.capture(
                event: .mobileDaemonAttachResult,
                properties: MobileAnalyticsProperties(
                    teamId: host.teamID,
                    machineId: machineID,
                    workspaceId: remoteWorkspaceID,
                    source: "direct_daemon",
                    result: "failure",
                    errorCode: error?.trimmingCharacters(in: .whitespacesAndNewlines),
                    latencyMs: attachLatencyMs(for: workspace.id)
                )
            )
            reportedAttachResults[workspace.id] = "failure"
            attachAttemptStartedAt.removeValue(forKey: workspace.id)
        case .needsConfiguration, .idle, .disconnected:
            attachAttemptStartedAt.removeValue(forKey: workspace.id)
        }
    }

    private func attachLatencyMs(for workspaceID: TerminalWorkspace.ID) -> Int? {
        guard let startedAt = attachAttemptStartedAt[workspaceID] else {
            return nil
        }
        return max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    private func analyticsMachineID(for host: TerminalHost) -> String? {
        let stableID = host.stableID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stableID.isEmpty {
            return stableID
        }
        let serverID = host.serverID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return serverID.isEmpty ? nil : serverID
    }

    private func setUnread(_ unread: Bool, for workspaceID: TerminalWorkspace.ID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[index].unread = unread
    }

    private func sortWorkspaces() {
        workspaces.sort { $0.lastActivity > $1.lastActivity }
    }

    private func upsertRemoteHost(for item: UnifiedInboxItem, machineID: String) -> TerminalHost {
        let resolvedName = item.accessoryLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostName = (resolvedName?.isEmpty == false ? resolvedName : machineID) ?? machineID
        let hostname = item.tailscaleHostname ??
            item.tailscaleIPs.first ??
            machineID
        let serverID = normalizedRemoteServerID(machineID: machineID, tailscaleHostname: item.tailscaleHostname)

        if let existingIndex = hosts.firstIndex(where: {
            $0.stableID == machineID ||
                $0.serverID == machineID ||
                $0.serverID == serverID ||
                ($0.source == .discovered && $0.hostname.caseInsensitiveCompare(hostname) == .orderedSame) ||
                ($0.source == .custom &&
                    !$0.isConfigured &&
                    $0.name.caseInsensitiveCompare(hostName) == .orderedSame)
        }) {
            hosts[existingIndex].stableID = machineID
            hosts[existingIndex].name = hostName
            hosts[existingIndex].hostname = hostname
            hosts[existingIndex].username = "cmux"
            hosts[existingIndex].source = .discovered
            hosts[existingIndex].transportPreference = .remoteDaemon
            hosts[existingIndex].teamID = item.teamID
            hosts[existingIndex].serverID = serverID
            hosts[existingIndex].machineStatus = item.machineStatus
            applyDebugWebSocketConfig(&hosts[existingIndex])
            return hosts[existingIndex]
        }

        var host = TerminalHost(
            stableID: machineID,
            name: hostName,
            hostname: hostname,
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: TerminalHostPalette.allCases[hosts.count % TerminalHostPalette.allCases.count],
            sortIndex: hosts.count,
            source: .discovered,
            transportPreference: .remoteDaemon,
            teamID: item.teamID,
            serverID: serverID,
            allowsSSHFallback: true,
            machineStatus: item.machineStatus
        )
        applyDebugWebSocketConfig(&host)
        hosts.append(host)
        return host
    }

    private func applyDebugWebSocketConfig(_ host: inout TerminalHost) {
        #if DEBUG
        guard host.wsPort == nil else { return }

        // Check for embedded port from tagged build, fall back to 52100
        if let bundlePath = Bundle.main.path(forResource: "debug-ws-port", ofType: nil),
           let portStr = try? String(contentsOfFile: bundlePath, encoding: .utf8)
               .trimmingCharacters(in: .whitespacesAndNewlines),
           let port = Int(portStr) {
            host.wsPort = port
        } else {
            host.wsPort = 52100
        }

        // Load ws-secret: simulator reads from Mac filesystem, device reads from app bundle
        var secret: String?
        #if targetEnvironment(simulator)
        let home = NSHomeDirectory()
        let hostHome = home.components(separatedBy: "/Library/Developer/CoreSimulator").first ?? home
        let secretPath = hostHome + "/Library/Application Support/cmux/mobile-ws-secret"
        secret = try? String(contentsOfFile: secretPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        host.hostname = "127.0.0.1"
        #else
        // On physical device, the build script copies the secret into the app bundle
        if let bundlePath = Bundle.main.path(forResource: "mobile-ws-secret", ofType: nil) {
            secret = try? String(contentsOfFile: bundlePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // On physical device, the build script also writes the Mac's Tailscale IP into the bundle
        if let ipPath = Bundle.main.path(forResource: "debug-relay-host", ofType: nil) {
            let relayHost = (try? String(contentsOfFile: ipPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
            if !relayHost.isEmpty {
                host.hostname = relayHost
            }
        }
        #endif

        if let secret, !secret.isEmpty {
            host.wsSecret = secret
            let hostname = host.hostname
            log.debug("WS debug: secret loaded (\(secret.count, privacy: .public) chars) hostname=\(hostname, privacy: .public)")
        } else {
            host.wsPort = nil
            log.debug("WS debug: no secret available, disabling WebSocket")
        }
        #endif
    }

    private func normalizedRemoteServerID(machineID: String, tailscaleHostname: String?) -> String {
        let trimmedHostname = tailscaleHostname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedHostname.isEmpty {
            return trimmedHostname
        }
        return machineID
    }

    private func observeWorkspaceMetadata() {
        for workspace in workspaces {
            startWorkspaceMetadataObservationIfNeeded(for: workspace.id)
        }
    }

    private func ensureBackendIdentityIfNeeded(for workspaceID: TerminalWorkspace.ID) {
        guard workspaceIdentityTasks[workspaceID] == nil,
              let workspaceIdentityService,
              let workspace = workspace(with: workspaceID),
              !workspace.isRemoteWorkspace,
              workspace.backendIdentity == nil,
              let host = server(for: workspace.hostID),
              let teamID = host.teamID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !teamID.isEmpty else {
            return
        }

        let task = Task { @MainActor [weak self] in
            defer {
                self?.workspaceIdentityTasks.removeValue(forKey: workspaceID)
            }

            do {
                let identity = try await workspaceIdentityService.reserveWorkspace(for: host)
                guard let self,
                      let index = self.workspaces.firstIndex(where: { $0.id == workspaceID }),
                      self.workspaces[index].backendIdentity == nil else {
                    return
                }

                self.workspaces[index].backendIdentity = identity
                self.persist()
                self.startWorkspaceMetadataObservationIfNeeded(for: workspaceID)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }

        workspaceIdentityTasks[workspaceID] = task
    }

    private func cancelWorkspaceIdentityReservation(for workspaceID: TerminalWorkspace.ID) {
        workspaceIdentityTasks[workspaceID]?.cancel()
        workspaceIdentityTasks.removeValue(forKey: workspaceID)
    }

    private func startWorkspaceMetadataObservationIfNeeded(for workspaceID: TerminalWorkspace.ID) {
        guard workspaceMetadataCancellables[workspaceID] == nil,
              let workspaceMetadataService,
              let workspace = workspace(with: workspaceID),
              let identity = workspace.backendIdentity else {
            return
        }

        workspaceMetadataCancellables[workspaceID] = workspaceMetadataService
            .metadataPublisher(for: identity)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] metadata in
                guard let self,
                      let index = self.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
                    return
                }

                guard self.workspaces[index].backendMetadata != metadata else { return }
                self.workspaces[index].backendMetadata = metadata
                self.persist()
            }
    }

    private func cancelWorkspaceMetadataObservation(for workspaceID: TerminalWorkspace.ID) {
        workspaceMetadataCancellables[workspaceID]?.cancel()
        workspaceMetadataCancellables.removeValue(forKey: workspaceID)
    }

    private func normalizedTeamID(_ teamID: String?) -> String? {
        guard let trimmed = teamID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    private func persist() {
        do {
            try snapshotStore.save(
                TerminalStoreSnapshot(
                    hosts: hosts,
                    workspaces: workspaces,
                    selectedWorkspaceID: selectedWorkspaceID
                )
            )
        } catch {
            #if DEBUG
            log.error("Failed to save terminal snapshot: \(error.localizedDescription, privacy: .public)")
            #endif
        }
    }

    private func observeLifecycle() {
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for controller in self.controllers.values {
                        controller.suspendPreservingState()
                    }
                }
            }
        )
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.syncVisibleControllerLifecycle()
                }
            }
        )
    }
}

@MainActor
@Observable
final class TerminalSessionController {
    let workspaceID: TerminalWorkspace.ID
    @ObservationIgnored
    var onUpdate: ((TerminalSessionUpdate) -> Void)?

    private(set) var phase: TerminalConnectionPhase
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var surfaceView: GhosttySurfaceView?
    #if DEBUG
    private(set) var accessibilityTerminalText: String = ""
    #endif

    private var host: TerminalHost
    private var workspace: TerminalWorkspace
    private let credentialsStore: TerminalCredentialsStoring
    private let transportFactory: TerminalTransportFactory
    private let surfaceFactory: @MainActor (GhosttySurfaceViewDelegate) throws -> any TerminalSurfaceHosting

    private var terminalSurface: (any TerminalSurfaceHosting)?
    private var surfaceNeedsInitialReplay = false
    private var remoteDaemonResumeState: TerminalRemoteDaemonResumeState?
    private var transport: TerminalTransport?
    @ObservationIgnored
    private let transportEventQueue = DispatchQueue(
        label: "dev.cmux.TerminalSessionController.transport-events",
        qos: .userInitiated,
        target: .main
    )
    private var transportConnectTask: Task<Void, Never>?
    private var transportDisconnectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var statusMessageTask: Task<Void, Never>?
    private var surfaceCloseObserver: NSObjectProtocol?
    private var surfaceBellObserver: NSObjectProtocol?
    private var shouldReconnect = true
    private var transportConnectGeneration = 0
    private var pendingReconnectAfterTransportWork = false
    private var pendingReconnectUsesReconnectingPhase = false
    private var consecutiveConnectFailures = 0

    private var isLiveAnchormuxSession: Bool {
        host.stableID.hasPrefix("anchormux-live-")
    }

    static func unavailable(workspaceID: TerminalWorkspace.ID) -> TerminalSessionController {
        TerminalSessionController(
            workspace: TerminalWorkspace(
                id: workspaceID,
                hostID: UUID(),
                title: TerminalStoreStrings.unavailableWorkspaceTitle,
                tmuxSessionName: "unavailable",
                phase: .failed,
                lastError: TerminalStoreStrings.missingServerError
            ),
            host: TerminalHost(
                id: UUID(),
                name: TerminalStoreStrings.missingServerName,
                hostname: "",
                username: "",
                symbolName: "exclamationmark.triangle.fill",
                palette: .rose
            ),
            credentialsStore: InMemoryTerminalCredentialsStore(),
            transportFactory: DefaultTerminalTransportFactory()
        )
    }

    init(
        workspace: TerminalWorkspace,
        host: TerminalHost,
        credentialsStore: TerminalCredentialsStoring,
        transportFactory: TerminalTransportFactory,
        surfaceFactory: @escaping @MainActor (GhosttySurfaceViewDelegate) throws -> any TerminalSurfaceHosting = makeTerminalSurface(delegate:)
    ) {
        self.workspaceID = workspace.id
        self.workspace = workspace
        self.host = host
        self.credentialsStore = credentialsStore
        self.transportFactory = transportFactory
        self.surfaceFactory = surfaceFactory
        self.remoteDaemonResumeState = workspace.remoteDaemonResumeState
        self.phase = workspace.phase
        self.errorMessage = workspace.lastError
    }

    deinit {
        MainActor.assumeIsolated {
            if let surfaceCloseObserver {
                NotificationCenter.default.removeObserver(surfaceCloseObserver)
            }
            if let surfaceBellObserver {
                NotificationCenter.default.removeObserver(surfaceBellObserver)
            }
        }
    }

    func refreshHost(_ host: TerminalHost) {
        self.host = host
        if phase == .needsConfiguration || phase == .failed {
            connectIfNeeded()
        }
    }

    func refreshWorkspace(_ workspace: TerminalWorkspace) {
        let previousWorkspace = self.workspace
        self.workspace = workspace
        remoteDaemonResumeState = workspace.remoteDaemonResumeState

        guard sessionOverride == nil else { return }
        guard previousWorkspace.tmuxSessionName != workspace.tmuxSessionName else { return }
        guard !workspace.tmuxSessionName.isEmpty, !workspace.tmuxSessionName.hasPrefix("pending-") else { return }

        if transport != nil || transportConnectTask != nil || phase == .connected || phase == .connecting || phase == .reconnecting {
            reconnectForAuthoritativeSessionChange()
        }
    }

    func connectIfNeeded(reconnecting: Bool = false) {
        if isLiveAnchormuxSession {
            liveAnchormuxLog("controller.connectIfNeeded reconnecting=\(reconnecting) phase=\(phase) transport=\(transport != nil)")
        }
        guard transport == nil else { return }
        guard transportConnectTask == nil, transportDisconnectTask == nil else {
            queueReconnectAfterPendingTransportWork(reconnecting: reconnecting)
            return
        }
        guard ensureTerminalSurface() else {
            return
        }
        guard let terminalSurface else {
            setPhase(.failed, error: TerminalStoreStrings.surfaceUnavailableError)
            return
        }
        guard host.isConfigured else {
            setPhase(.needsConfiguration, error: TerminalStoreStrings.configureHostError)
            return
        }

        let credentials = credentialsStore.sshCredentials(for: host.id)
        if host.requiresSavedSSHPassword, !credentials.hasPassword {
            setPhase(.needsConfiguration, error: TerminalStoreStrings.configurePasswordError)
            return
        }
        if host.requiresSavedSSHPrivateKey, !credentials.hasPrivateKey {
            setPhase(.needsConfiguration, error: TerminalStoreStrings.configurePrivateKeyError)
            return
        }

        clearStatusMessage()
        setPhase(reconnecting ? .reconnecting : .connecting, error: nil)
        shouldReconnect = true
        // If the surface hasn't been laid out yet (grid size is 0x0), fall
        // back to a sensible default. The daemon rejects attaches with 0
        // cols/rows because the PTY ioctl fails, so passing zeros puts us in
        // a reconnect loop until the view lays out.
        let surfaceGrid = terminalSurface.currentGridSize
        let initialSize: TerminalGridSize = (surfaceGrid.columns <= 0 || surfaceGrid.rows <= 0)
            ? TerminalGridSize(columns: 80, rows: 24, pixelWidth: 640, pixelHeight: 384)
            : surfaceGrid

        let effectiveSessionName = sessionOverride ?? workspace.tmuxSessionName
        // PR 5 SSOT guard: a "pending-<remoteId>" session name means the mac
        // hasn't finished binding a shell to this workspace yet. Attaching
        // would silently spawn a fresh PTY on the daemon (the phantom-shell
        // bug) so we stay in .connecting and re-check on the next
        // workspace.changed update. The onUpdate path will invoke
        // connectIfNeeded again once the real session id arrives.
        if effectiveSessionName.hasPrefix("pending-") {
            self.transport = nil
            setPhase(.connecting, error: TerminalStoreStrings.configureWaitingForDaemonMessage)
            return
        }
        let transport = transportFactory.makeTransport(
            host: host,
            credentials: credentials,
            sessionName: effectiveSessionName,
            resumeState: resumeStateForConnect(surfaceNeedsInitialReplay: surfaceNeedsInitialReplay)
        )
        let transportEventQueue = self.transportEventQueue
        let transportID = ObjectIdentifier(transport as AnyObject)
        transport.eventHandler = { [weak self] event in
            transportEventQueue.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isCurrentTransport(transportID) else { return }
                    self.handle(event: event)
                }
            }
        }
        self.transport = transport

        transportConnectGeneration += 1
        let connectGeneration = transportConnectGeneration
        transportConnectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await transport.connect(initialSize: initialSize)
                await MainActor.run {
                    self.finishTransportConnectTask(generation: connectGeneration)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.finishTransportConnectTask(generation: connectGeneration)
                }
            } catch {
                log.error("SessionController: connect failed: \(error.localizedDescription, privacy: .public) (type=\(String(describing: type(of: error)), privacy: .public))")
                await MainActor.run {
                    let isCurrentTransport = self.isCurrentTransport(transport)
                    if isCurrentTransport {
                        transport.eventHandler = nil
                        self.transport = nil
                        if case TerminalRemoteDaemonSessionTransportError.sharedSessionUnavailable = error {
                            self.setPhase(.connecting, error: error.localizedDescription)
                        } else if let sshError = error as? TerminalSSHError {
                            switch sshError {
                            case .untrustedHostKey(let hostKey), .hostKeyChanged(let hostKey):
                                self.onUpdate?(.pendingHostKey(hostKey))
                                self.setPhase(.needsConfiguration, error: sshError.localizedDescription)
                            default:
                                self.setPhase(.failed, error: error.localizedDescription)
                            }
                        } else {
                            self.setPhase(.failed, error: error.localizedDescription)
                        }
                        self.consecutiveConnectFailures += 1
                        if self.shouldAutoReconnect(after: error) {
                            // Exponential backoff: 2, 4, 8, 16, 30 max
                            let delay = min(30.0, 2.0 * pow(2.0, Double(min(self.consecutiveConnectFailures - 1, 4))))
                            self.scheduleReconnectIfNeeded(after: delay)
                        }
                    }
                    self.finishTransportConnectTask(generation: connectGeneration)
                }
            }
        }
    }

    func resumeIfNeeded() {
        if isLiveAnchormuxSession {
            liveAnchormuxLog("controller.resumeIfNeeded phase=\(phase) transport=\(transport != nil) shouldReconnect=\(shouldReconnect)")
        }
        guard shouldReconnect else { return }
        if transport == nil, phase != .needsConfiguration {
            connectIfNeeded(reconnecting: true)
        }
    }

    /// Override session name for pane switching. When set, connectIfNeeded
    /// uses this instead of workspace.tmuxSessionName.
    private var sessionOverride: String?

    /// Switch to a different daemon session (e.g. a different pane in
    /// the same workspace). Disconnects the current session and
    /// reconnects with the new session ID.
    func switchSession(to sessionID: String) {
        sessionOverride = sessionID
        reconnectTask?.cancel()
        reconnectTask = nil
        clearStatusMessage()
        updateRemoteDaemonResumeState(nil)
        clearPendingReconnectAfterTransportWork()
        cancelTransportConnectTask()
        // Tear down the old Ghostty surface so stale content from the
        // previous pane doesn't linger. A fresh surface is created by
        // ensureTerminalSurface() inside connectIfNeeded().
        clearTerminalSurface()
        setPhase(.reconnecting, error: nil)
        let transport = releaseTransport()
        scheduleTransportDisconnect(transport, preserveSession: true)
        connectIfNeeded(reconnecting: true)
    }

    func reconnectNow() {
        if isLiveAnchormuxSession {
            liveAnchormuxLog("controller.reconnectNow phase=\(phase)")
        }
        guard transportDisconnectTask == nil else {
            terminalSurface?.focusInput()
            return
        }
        let hasTransportWork = transport != nil || transportConnectTask != nil
        guard phase != .reconnecting || hasTransportWork else {
            terminalSurface?.focusInput()
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        clearStatusMessage()
        syncRemoteDaemonResumeStateFromTransport()
        clearPendingReconnectAfterTransportWork()
        cancelTransportConnectTask()
        setPhase(.reconnecting, error: nil)
        let transport = releaseTransport()
        scheduleTransportDisconnect(transport, preserveSession: true)
        connectIfNeeded(reconnecting: true)
    }

    private func reconnectForAuthoritativeSessionChange() {
        reconnectTask?.cancel()
        reconnectTask = nil
        clearStatusMessage()
        sessionOverride = nil
        updateRemoteDaemonResumeState(nil)
        clearPendingReconnectAfterTransportWork()
        cancelTransportConnectTask()
        clearTerminalSurface()
        setPhase(.reconnecting, error: nil)
        let transport = releaseTransport()
        scheduleTransportDisconnect(transport, preserveSession: true)
        connectIfNeeded(reconnecting: true)
    }

    func disconnect() {
        if isLiveAnchormuxSession {
            liveAnchormuxLog("controller.disconnect phase=\(phase)")
        }
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        clearStatusMessage()
        updateRemoteDaemonResumeState(nil)
        clearPendingReconnectAfterTransportWork()
        cancelTransportConnectTask()
        let transport = releaseTransport()
        clearTerminalSurface()
        scheduleTransportDisconnect(transport)
    }

    func suspendPreservingState() {
        if isLiveAnchormuxSession {
            liveAnchormuxLog("controller.suspendPreservingState phase=\(phase)")
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        clearStatusMessage()
        syncRemoteDaemonResumeStateFromTransport()
        clearPendingReconnectAfterTransportWork()
        cancelTransportConnectTask()
        let transport = releaseTransport()
        clearTerminalSurface()

        if phase != .needsConfiguration && phase != .failed {
            setPhase(.idle, error: nil)
        }

        scheduleTransportDisconnect(transport, preserveSession: true)
    }

    private func handle(event: TerminalTransportEvent) {
        if isLiveAnchormuxSession {
            switch event {
            case .connected:
                liveAnchormuxLog("controller.event connected")
            case .output(let data):
                liveAnchormuxLog("controller.event output bytes=\(data.count)")
            case .disconnected(let message):
                liveAnchormuxLog("controller.event disconnected message=\(message ?? "nil")")
            case .notice(let message):
                liveAnchormuxLog("controller.event notice message=\(message)")
            case .trustedHostKey(let hostKey):
                liveAnchormuxLog("controller.event trusted_host_key key=\(hostKey)")
            case .remotePlatform(let platform):
                liveAnchormuxLog("controller.event remote_platform os=\(platform.goOS) arch=\(platform.goArch)")
            case .viewSize(let cols, let rows):
                liveAnchormuxLog("controller.event view_size cols=\(cols) rows=\(rows)")
            }
        }
        switch event {
        case .connected:
            reconnectTask?.cancel()
            reconnectTask = nil
            consecutiveConnectFailures = 0
            setPhase(.connected, error: nil)
            syncRemoteDaemonResumeStateFromTransport()
            terminalSurface?.focusInput()
            if statusMessage != nil {
                scheduleStatusMessageClear(after: 2)
            }
        case .output(let data):
            terminalSurface?.processOutput(data)
            if !data.isEmpty {
                surfaceNeedsInitialReplay = false
            }
            #if DEBUG
            refreshAccessibilityTerminalText()
            #endif
            if let preview = TerminalPreviewExtractor.preview(from: data) {
                onUpdate?(.preview(preview, .now))
            }
        case .disconnected(let message):
            syncRemoteDaemonResumeStateFromTransport()
            transport = nil
            clearStatusMessage()
            if let message {
                setPhase(.disconnected, error: message)
            } else {
                setPhase(.disconnected, error: nil)
            }
            consecutiveConnectFailures += 1
            let delay = min(30.0, 2.0 * pow(2.0, Double(min(consecutiveConnectFailures - 1, 4))))
            scheduleReconnectIfNeeded(after: delay)
        case .notice(let message):
            setStatusMessage(message)
        case .trustedHostKey(let hostKey):
            onUpdate?(.trustedHostKey(hostKey))
        case .remotePlatform(let platform):
            terminalSurface?.updateRemotePlatform(platform)
        case .viewSize(let cols, let rows):
            // Daemon is authoritative for the rendering grid. Apply
            // unconditionally; surface lets-boxes if container bigger.
            terminalSurface?.applyViewSize(cols: cols, rows: rows)
            #if DEBUG
            refreshAccessibilityTerminalText()
            #endif
        }
    }

    private func setPhase(_ phase: TerminalConnectionPhase, error: String?) {
        let normalizedError = normalizedDisplayError(error)
        if isLiveAnchormuxSession {
            liveAnchormuxLog("controller.phase from=\(self.phase) to=\(phase) error=\(normalizedError ?? "nil")")
        }
        self.phase = phase
        self.errorMessage = normalizedError
        onUpdate?(.phase(phase, normalizedError))
    }

    private func scheduleReconnectIfNeeded(after seconds: Double) {
        guard shouldReconnect else { return }
        guard phase != .needsConfiguration else { return }
        guard shouldAutoReconnect(for: errorMessage) else { return }
        let reconnectDelay = UITestConfig.terminalReconnectDelayOverride ?? seconds
        reconnect(seconds: reconnectDelay)
    }

    private func shouldAutoReconnect(after error: Error) -> Bool {
        switch error {
        case let error as TerminalDirectDaemonClientError:
            if case .connectionFailed(let message) = error {
                if isSecureConnectionConfigurationError(message) {
                    return false
                }
                return true
            }
            return false
        case let error as TerminalSSHError:
            switch error {
            case .passwordAuthenticationUnavailable,
                 .publicKeyAuthenticationUnavailable,
                 .missingPassword,
                 .missingPrivateKey,
                 .authenticationTimedOut,
                 .untrustedHostKey,
                 .hostKeyChanged:
                return false
            case .channelClosedBeforeAuthentication:
                return true
            }
        case let error as TerminalDaemonTicketServiceError:
            switch error {
            case .httpError(let statusCode, _):
                return statusCode >= 500
            case .invalidResponse:
                return false
            }
        default:
            return shouldAutoReconnect(for: error.localizedDescription)
        }
    }

    private func shouldAutoReconnect(for errorMessage: String?) -> Bool {
        guard let errorMessage else { return true }

        let lowercased = errorMessage.localizedLowercase
        if isSecureConnectionConfigurationError(errorMessage) {
            return false
        }
        if lowercased.contains("host key") ||
            lowercased.contains("password") ||
            lowercased.contains("private key") ||
            lowercased.contains("public key") ||
            lowercased.contains("authentication timed out") {
            return false
        }
        return true
    }

    private func reconnect(seconds: Double) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.connectIfNeeded(reconnecting: true)
            }
        }
    }

    private func normalizedDisplayError(_ error: String?) -> String? {
        guard let error else { return nil }
        if isSecureConnectionConfigurationError(error) {
            return TerminalStoreStrings.secureConnectionError
        }
        return error
    }

    private func isSecureConnectionConfigurationError(_ errorMessage: String?) -> Bool {
        guard let errorMessage else { return false }
        if errorMessage == TerminalStoreStrings.secureConnectionError {
            return true
        }
        let lowercased = errorMessage.localizedLowercase
        return lowercased.contains("app transport security") ||
            lowercased.contains("requires the use of a secure connection")
    }

    private func setStatusMessage(_ message: String?) {
        statusMessageTask?.cancel()
        statusMessageTask = nil
        statusMessage = normalizedDisplayError(message)
    }

    private func clearStatusMessage() {
        statusMessageTask?.cancel()
        statusMessageTask = nil
        statusMessage = nil
    }

    private func resumeStateForConnect(surfaceNeedsInitialReplay: Bool) -> TerminalRemoteDaemonResumeState? {
        guard var state = remoteDaemonResumeState else { return nil }
        // A fresh Ghostty surface starts with an empty local emulator. Reusing
        // a persisted readOffset would only replay the unread tail into that
        // empty renderer, which drops older scrollback like the initial prompt.
        // Keep session/attachment identity, but bootstrap from offset 0.
        if surfaceNeedsInitialReplay {
            state.readOffset = 0
        }
        return state
    }

    private func scheduleStatusMessageClear(after seconds: Double) {
        statusMessageTask?.cancel()
        statusMessageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.statusMessage = nil
                self?.statusMessageTask = nil
            }
        }
    }

    private func syncRemoteDaemonResumeStateFromTransport() {
        guard let snapshotting = transport as? TerminalRemoteDaemonResumeStateSnapshotting else { return }
        updateRemoteDaemonResumeState(snapshotting.remoteDaemonResumeStateSnapshot())
    }

    private func updateRemoteDaemonResumeState(_ state: TerminalRemoteDaemonResumeState?) {
        guard remoteDaemonResumeState != state else { return }
        remoteDaemonResumeState = state
        onUpdate?(.remoteDaemonResumeState(state))
    }

    @discardableResult
    private func ensureTerminalSurface() -> Bool {
        if terminalSurface != nil {
            return true
        }

        do {
            let surface = try surfaceFactory(self)
            terminalSurface = surface
            surfaceView = surface as? GhosttySurfaceView
            surfaceNeedsInitialReplay = true
            observeSurfaceClose(for: surface)
            // Marker: surface created successfully
            if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                let info = "ensureTerminalSurface OK at \(Date())\nsurfaceView=\(surfaceView != nil)\nghostty_surface=\(surfaceView?.surface != nil)\n"
                try? info.write(to: caches.appendingPathComponent("ensure-surface-marker.txt"), atomically: true, encoding: .utf8)
            }
            return true
        } catch {
            // Marker: surface creation failed
            if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                let info = "ensureTerminalSurface FAILED at \(Date())\nerror=\(error)\n"
                try? info.write(to: caches.appendingPathComponent("ensure-surface-error.txt"), atomically: true, encoding: .utf8)
            }
            clearTerminalSurface()
            setPhase(.failed, error: error.localizedDescription)
            return false
        }
    }

    private func releaseTransport() -> TerminalTransport? {
        let transport = self.transport
        transport?.eventHandler = nil
        self.transport = nil
        return transport
    }

    private func clearTerminalSurface() {
        if let surfaceCloseObserver {
            NotificationCenter.default.removeObserver(surfaceCloseObserver)
            self.surfaceCloseObserver = nil
        }
        if let surfaceBellObserver {
            NotificationCenter.default.removeObserver(surfaceBellObserver)
            self.surfaceBellObserver = nil
        }
        surfaceView?.disposeSurface()
        terminalSurface = nil
        surfaceView = nil
        surfaceNeedsInitialReplay = false
        updateRemoteDaemonResumeState(nil)
        #if DEBUG
        accessibilityTerminalText = ""
        #endif
    }

    #if DEBUG
    private func refreshAccessibilityTerminalText() {
        accessibilityTerminalText = terminalSurface?.accessibilityRenderedTextForTesting() ?? ""
    }
    #endif

    private func observeSurfaceClose(for surface: any TerminalSurfaceHosting) {
        if let surfaceCloseObserver {
            NotificationCenter.default.removeObserver(surfaceCloseObserver)
        }
        if let surfaceBellObserver {
            NotificationCenter.default.removeObserver(surfaceBellObserver)
        }
        surfaceCloseObserver = NotificationCenter.default.addObserver(
            forName: .ghosttySurfaceDidRequestClose,
            object: surface,
            queue: .main
        ) { [weak self] notification in
            let processAlive = notification.userInfo?["process_alive"] as? Bool ?? false
            Task { @MainActor [weak self] in
                self?.handleSurfaceCloseRequest(processAlive: processAlive)
            }
        }
        surfaceBellObserver = NotificationCenter.default.addObserver(
            forName: .ghosttySurfaceDidRingBell,
            object: surface,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSurfaceBell()
            }
        }
    }

    private func handleSurfaceBell() {
        onUpdate?(.bell(.now))
    }

    private func handleSurfaceCloseRequest(processAlive _: Bool) {
        if isLiveAnchormuxSession {
            liveAnchormuxLog("controller.surfaceCloseRequest phase=\(phase)")
        }
        guard terminalSurface != nil else { return }

        reconnectTask?.cancel()
        reconnectTask = nil
        clearStatusMessage()
        syncRemoteDaemonResumeStateFromTransport()
        clearTerminalSurface()

        let transport = releaseTransport()
        guard shouldReconnect else {
            clearPendingReconnectAfterTransportWork()
            cancelTransportConnectTask()
            scheduleTransportDisconnect(transport)
            return
        }

        setPhase(.reconnecting, error: nil)
        clearPendingReconnectAfterTransportWork()
        cancelTransportConnectTask()
        scheduleTransportDisconnect(transport, preserveSession: true) { controller in
            guard controller.ensureTerminalSurface() else {
                controller.scheduleReconnectIfNeeded(after: 2)
                return
            }
            controller.connectIfNeeded(reconnecting: true)
        }
    }

    private func queueReconnectAfterPendingTransportWork(reconnecting: Bool) {
        pendingReconnectAfterTransportWork = true
        pendingReconnectUsesReconnectingPhase = pendingReconnectUsesReconnectingPhase || reconnecting
    }

    private func clearPendingReconnectAfterTransportWork() {
        pendingReconnectAfterTransportWork = false
        pendingReconnectUsesReconnectingPhase = false
    }

    private func flushPendingReconnectIfNeeded() {
        guard pendingReconnectAfterTransportWork else { return }
        guard transportConnectTask == nil, transportDisconnectTask == nil else { return }
        let reconnecting = pendingReconnectUsesReconnectingPhase
        clearPendingReconnectAfterTransportWork()
        connectIfNeeded(reconnecting: reconnecting)
    }

    private func cancelTransportConnectTask() {
        guard let task = transportConnectTask else { return }
        transportConnectGeneration += 1
        task.cancel()
        transportConnectTask = nil
    }

    private func finishTransportConnectTask(generation: Int) {
        guard transportConnectGeneration == generation else { return }
        transportConnectTask = nil
        if transport == nil {
            flushPendingReconnectIfNeeded()
        }
    }

    private func isCurrentTransport(_ candidate: any TerminalTransport) -> Bool {
        guard let transport else { return false }
        return transport as AnyObject === candidate as AnyObject
    }

    private func isCurrentTransport(_ candidateID: ObjectIdentifier) -> Bool {
        guard let transport else { return false }
        return ObjectIdentifier(transport as AnyObject) == candidateID
    }

    private func scheduleTransportDisconnect(
        _ transport: TerminalTransport?,
        preserveSession: Bool = false,
        afterDisconnect: (@MainActor @Sendable (TerminalSessionController) -> Void)? = nil
    ) {
        guard let transport else {
            if let afterDisconnect {
                afterDisconnect(self)
            } else {
                flushPendingReconnectIfNeeded()
            }
            return
        }

        transportDisconnectTask = Task { [weak self] in
            if preserveSession, let parkingTransport = transport as? TerminalSessionParking {
                await parkingTransport.suspendPreservingSession()
            } else {
                await transport.disconnect()
            }
            await MainActor.run {
                guard let self else { return }
                self.transportDisconnectTask = nil
                if let afterDisconnect {
                    afterDisconnect(self)
                } else {
                    self.flushPendingReconnectIfNeeded()
                }
            }
        }
    }
}

#if DEBUG
extension TerminalSidebarStore {
    static func uiTestDirectFixture() -> TerminalSidebarStore {
        let host = TerminalHost(
            stableID: "cmux-macmini",
            name: "Mac mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .discovered,
            transportPreference: .remoteDaemon,
            teamID: "team-uitest",
            serverID: "cmux-macmini"
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [host],
            workspaces: [],
            selectedWorkspaceID: nil
        )
        let snapshotStore = InMemoryTerminalSnapshotStore(snapshot: snapshot)
        let credentialsStore = InMemoryTerminalCredentialsStore(passwords: [host.id: "fixture"])
        return TerminalSidebarStore(
            snapshotStore: snapshotStore,
            credentialsStore: credentialsStore,
            transportFactory: TerminalUITestDirectReconnectTransportFactory(),
            serverDiscovery: nil,
            networkPathMonitor: nil,
            eagerlyRestoreSessions: false
        )
    }

    static func uiTestInboxFixture() -> TerminalSidebarStore {
        let macMiniID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let linuxVMID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let currentWorkspaceID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let olderWorkspaceID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

        let macMini = TerminalHost(
            id: macMiniID,
            stableID: "cmux-macmini",
            name: "Mac mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            sortIndex: 0,
            source: .discovered,
            transportPreference: .remoteDaemon,
            teamID: "team-uitest",
            serverID: "cmux-macmini"
        )
        let linuxVM = TerminalHost(
            id: linuxVMID,
            stableID: "cmux-linux-vm",
            name: "Linux VM",
            hostname: "orb",
            username: "cmux",
            symbolName: "server.rack",
            palette: .sky,
            sortIndex: 1,
            source: .discovered,
            transportPreference: .remoteDaemon,
            teamID: "team-uitest",
            serverID: "cmux-linux-vm"
        )

        let currentWorkspace = TerminalWorkspace(
            id: currentWorkspaceID,
            hostID: macMini.id,
            title: "Mac mini",
            tmuxSessionName: "cmux-mac-mini",
            preview: "Build failed",
            lastActivity: Date(timeIntervalSince1970: 1_774_000_200),
            unread: true,
            phase: .connected,
            remoteWorkspaceID: currentWorkspaceID.uuidString
        )
        let olderWorkspace = TerminalWorkspace(
            id: olderWorkspaceID,
            hostID: linuxVM.id,
            title: "Linux VM",
            tmuxSessionName: "cmux-linux-vm",
            preview: "cmux@orb:~$",
            lastActivity: Date(timeIntervalSince1970: 1_774_000_000),
            unread: false,
            phase: .disconnected,
            remoteWorkspaceID: olderWorkspaceID.uuidString
        )

        let snapshot = TerminalStoreSnapshot(
            hosts: [macMini, linuxVM],
            workspaces: [olderWorkspace, currentWorkspace],
            selectedWorkspaceID: currentWorkspace.id
        )
        let snapshotStore = InMemoryTerminalSnapshotStore(snapshot: snapshot)
        let credentialsStore = InMemoryTerminalCredentialsStore(
            passwords: [
                macMini.id: "fixture",
                linuxVM.id: "fixture",
            ]
        )
        return TerminalSidebarStore(
            snapshotStore: snapshotStore,
            credentialsStore: credentialsStore,
            serverDiscovery: nil,
            networkPathMonitor: nil,
            eagerlyRestoreSessions: false
        )
    }

    static func uiTestWorkspaceHomeFixture() -> TerminalSidebarStore {
        let desktopID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let macMiniID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let desktop = TerminalHost(
            id: desktopID,
            stableID: "lawrences-macbook-pro-2",
            name: "Desktop",
            hostname: "lawrences-macbook-pro-2.tail",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .sky,
            sortIndex: 0,
            source: .discovered,
            transportPreference: .remoteDaemon,
            teamID: "uitest_team",
            serverID: "lawrences-macbook-pro-2"
        )
        let macMini = TerminalHost(
            id: macMiniID,
            stableID: "cmux-macmini",
            name: "Mac mini",
            hostname: "cmux-macmini.tail",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            sortIndex: 1,
            source: .discovered,
            transportPreference: .remoteDaemon,
            teamID: "uitest_team",
            serverID: "cmux-macmini"
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [desktop, macMini],
            workspaces: [],
            selectedWorkspaceID: nil
        )
        return TerminalSidebarStore(
            snapshotStore: InMemoryTerminalSnapshotStore(snapshot: snapshot),
            credentialsStore: InMemoryTerminalCredentialsStore(
                passwords: [
                    desktop.id: "fixture",
                    macMini.id: "fixture",
                ]
            ),
            transportFactory: TerminalUITestConnectedTransportFactory(),
            serverDiscovery: nil,
            networkPathMonitor: nil,
            eagerlyRestoreSessions: false
        )
    }

    static func uiTestSetupFixture() -> TerminalSidebarStore {
        let setupHost = TerminalHost(
            stableID: "cmux-setup",
            name: "Mac mini",
            hostname: "",
            username: "",
            symbolName: "desktopcomputer",
            palette: .mint,
            sortIndex: 0,
            source: .custom,
            transportPreference: .rawSSH
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [setupHost],
            workspaces: [],
            selectedWorkspaceID: nil
        )
        let snapshotStore = InMemoryTerminalSnapshotStore(snapshot: snapshot)
        return TerminalSidebarStore(
            snapshotStore: snapshotStore,
            credentialsStore: InMemoryTerminalCredentialsStore(),
            transportFactory: TerminalUITestConnectedTransportFactory(),
            serverDiscovery: nil,
            networkPathMonitor: nil,
            eagerlyRestoreSessions: false
        )
    }

    static func uiTestDiscoveredFixture() -> TerminalSidebarStore {
        let placeholderHost = TerminalHost(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            stableID: "cmux-setup",
            name: "Mac mini",
            hostname: "",
            username: "",
            symbolName: "desktopcomputer",
            palette: .mint,
            sortIndex: 0,
            source: .custom,
            transportPreference: .rawSSH
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [placeholderHost],
            workspaces: [],
            selectedWorkspaceID: nil
        )
        let store = TerminalSidebarStore(
            snapshotStore: InMemoryTerminalSnapshotStore(snapshot: snapshot),
            credentialsStore: InMemoryTerminalCredentialsStore(),
            transportFactory: TerminalUITestConnectedTransportFactory(),
            serverDiscovery: nil,
            networkPathMonitor: nil,
            eagerlyRestoreSessions: false
        )

        store.applyDiscoveredHosts([
            TerminalHost(
                stableID: "machine-macmini-live",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .discovered,
                transportPreference: .remoteDaemon,
                teamID: "team-uitest",
                serverID: "cmux-macmini",
                allowsSSHFallback: false
            )
        ])

        return store
    }

    static func uiTestInputFixture() -> TerminalSidebarStore {
        let host = TerminalHost(
            stableID: "cmux-input",
            name: "Input Fixture",
            hostname: "fixture",
            username: "cmux",
            symbolName: "keyboard",
            palette: .sky,
            sortIndex: 0,
            source: .custom,
            transportPreference: .rawSSH
        )
        let snapshot = TerminalStoreSnapshot(
            hosts: [host],
            workspaces: [],
            selectedWorkspaceID: nil
        )
        let snapshotStore = InMemoryTerminalSnapshotStore(snapshot: snapshot)
        let credentialsStore = InMemoryTerminalCredentialsStore(passwords: [host.id: "fixture"])
        return TerminalSidebarStore(
            snapshotStore: snapshotStore,
            credentialsStore: credentialsStore,
            transportFactory: TerminalUITestInputTransportFactory(),
            serverDiscovery: nil,
            networkPathMonitor: nil,
            eagerlyRestoreSessions: false
        )
    }
}

private struct TerminalUITestDirectReconnectTransportFactory: TerminalTransportFactory {
    private let scenario = TerminalUITestDirectReconnectScenario()

    func makeTransport(
        host: TerminalHost,
        credentials: TerminalSSHCredentials,
        sessionName: String,
        resumeState: TerminalRemoteDaemonResumeState?
    ) -> TerminalTransport {
        TerminalUITestDirectReconnectTransport(scenario: scenario)
    }
}

private struct TerminalUITestConnectedTransportFactory: TerminalTransportFactory {
    func makeTransport(
        host: TerminalHost,
        credentials: TerminalSSHCredentials,
        sessionName: String,
        resumeState: TerminalRemoteDaemonResumeState?
    ) -> TerminalTransport {
        TerminalUITestConnectedTransport()
    }
}

enum TerminalUITestEchoFormatter {
    static func preview(for data: Data) -> String {
        if data == Data([0x09]) {
            return "[TAB]"
        }
        if data == Data([0x1B]) {
            return "[ESC]"
        }
        if let string = String(data: data, encoding: .utf8),
           !string.isEmpty,
           string.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            return string
        }
        return data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

private struct TerminalUITestInputTransportFactory: TerminalTransportFactory {
    func makeTransport(
        host: TerminalHost,
        credentials: TerminalSSHCredentials,
        sessionName: String,
        resumeState: TerminalRemoteDaemonResumeState?
    ) -> TerminalTransport {
        TerminalUITestInputTransport()
    }
}

private actor TerminalUITestDirectReconnectScenario {
    private var connectCount = 0

    func nextAttempt() -> Int {
        connectCount += 1
        return connectCount
    }
}

private final class TerminalUITestDirectReconnectTransport: TerminalTransport, @unchecked Sendable {
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)?

    private let scenario: TerminalUITestDirectReconnectScenario
    private var runTask: Task<Void, Never>?

    init(scenario: TerminalUITestDirectReconnectScenario) {
        self.scenario = scenario
    }

    func connect(initialSize: TerminalGridSize) async throws {
        let attempt = await scenario.nextAttempt()
        runTask?.cancel()
        runTask = Task { [weak self] in
            guard let self else { return }
            if attempt == 1 {
                self.eventHandler?(.connected)
                self.eventHandler?(.output(Data("cmux@fixture:~$ ".utf8)))
                try? await Task.sleep(for: .milliseconds(1_200))
                guard !Task.isCancelled else { return }
                self.eventHandler?(.disconnected(nil))
                return
            }

            try? await Task.sleep(for: .milliseconds(2_000))
            guard !Task.isCancelled else { return }
            self.eventHandler?(.connected)
            self.eventHandler?(.notice("reconnected"))
            self.eventHandler?(.output(Data("cmux@fixture:reconnected$ ".utf8)))
        }
    }

    func send(_ data: Data) async throws {}

    func resize(_ size: TerminalGridSize) async {}

    func disconnect() async {
        runTask?.cancel()
        runTask = nil
    }
}

private final class TerminalUITestConnectedTransport: TerminalTransport, @unchecked Sendable {
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)?

    func connect(initialSize: TerminalGridSize) async throws {
        eventHandler?(.connected)
        eventHandler?(.output(Data("cmux@fixture:~$ ".utf8)))
    }

    func send(_ data: Data) async throws {}

    func resize(_ size: TerminalGridSize) async {}

    func disconnect() async {}
}

private final class TerminalUITestInputTransport: TerminalTransport, @unchecked Sendable {
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)?

    func connect(initialSize: TerminalGridSize) async throws {
        eventHandler?(.connected)
        eventHandler?(.output(Data("cmux@fixture:~$ ".utf8)))
    }

    func send(_ data: Data) async throws {
        let preview = TerminalUITestEchoFormatter.preview(for: data)
        eventHandler?(.output(Data(preview.utf8)))
    }

    func resize(_ size: TerminalGridSize) async {}

    func disconnect() async {}
}
#endif

extension TerminalSessionController: GhosttySurfaceViewDelegate {
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {
        TerminalInputDebugLog.log("controller.didProduceInput data=\(TerminalInputDebugLog.dataSummary(data))")
        Task { [weak self] in
            try? await self?.transport?.send(data)
        }
    }

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize) {
        Task { [weak self] in
            await self?.transport?.resize(size)
        }
    }
}

enum TerminalPreviewExtractor {
    static func preview(from data: Data) -> String? {
        guard var string = String(data: data, encoding: .utf8), !string.isEmpty else { return nil }
        string = string.replacingOccurrences(
            of: #"\u{001B}\[[0-?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )
        string = string.replacingOccurrences(
            of: #"\u{001B}\].*?(?:\u{0007}|\u{001B}\\)"#,
            with: "",
            options: .regularExpression
        )

        let lines = string
            .components(separatedBy: .newlines)
            .reversed()
            .map {
                $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
            }

        return lines.first(where: { !$0.isEmpty })
    }
}

private enum TerminalStoreStrings {
    static let newServerName = String(
        localized: "terminal.host.new_server_name",
        defaultValue: "New Server"
    )
    static let unavailableWorkspaceTitle = String(
        localized: "terminal.workspace.unavailable_title",
        defaultValue: "Unavailable"
    )
    static let missingServerError = String(
        localized: "terminal.workspace.missing_server_error",
        defaultValue: "Server missing"
    )
    static let missingServerName = String(
        localized: "terminal.host.missing_server_name",
        defaultValue: "Missing Server"
    )
    static let surfaceUnavailableError = String(
        localized: "terminal.workspace.surface_unavailable",
        defaultValue: "Terminal surface unavailable"
    )
    static let configureHostError = String(
        localized: "terminal.workspace.configure_host",
        defaultValue: "Add SSH host details to connect."
    )
    static let configurePasswordError = String(
        localized: "terminal.workspace.configure_password",
        defaultValue: "Add a password for this server."
    )
    static let configurePrivateKeyError = String(
        localized: "terminal.workspace.configure_private_key",
        defaultValue: "Add a private key for this server."
    )
    static let secureConnectionError = String(
        localized: "terminal.workspace.secure_connection_required",
        defaultValue: "Secure connection required. Check the server URL and try again."
    )
    static let configureWaitingForDaemonMessage = String(
        localized: "terminal.workspace.waiting_for_daemon",
        defaultValue: "Waiting for Mac to finish starting this workspace…"
    )
}
