import Combine
import Foundation
import Network
import SwiftUI
import UIKit

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
final class TerminalSidebarStore: ObservableObject {
    @Published private(set) var hosts: [TerminalHost]
    @Published private(set) var workspaces: [TerminalWorkspace]
    @Published var selectedWorkspaceID: TerminalWorkspace.ID?

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

    private var controllers: [TerminalWorkspace.ID: TerminalSessionController] = [:]
    private var workspaceIdentityTasks: [TerminalWorkspace.ID: Task<Void, Never>] = [:]
    private var workspaceMetadataCancellables: [TerminalWorkspace.ID: AnyCancellable] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var notificationObservers: [NSObjectProtocol] = []
    private var lastNetworkPathState: TerminalNetworkPathState?
    private var attachAttemptStartedAt: [TerminalWorkspace.ID: Date] = [:]
    private var reportedAttachResults: [TerminalWorkspace.ID: String] = [:]

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
        controllerFactory: TerminalSessionControllerFactory? = nil
    ) {
        self.snapshotStore = snapshotStore
        self.credentialsStore = credentialsStore
        self.transportFactory = transportFactory
        self.workspaceIdentityService = workspaceIdentityService ?? TerminalConvexWorkspaceIdentityService()
        self.workspaceMetadataService = workspaceMetadataService ?? TerminalConvexWorkspaceMetadataService()
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

        let snapshot = snapshotStore.load()
        self.hosts = snapshot.hosts.sorted(by: { $0.sortIndex < $1.sortIndex })
        self.workspaces = snapshot.workspaces.sorted(by: { $0.lastActivity > $1.lastActivity })
        self.selectedWorkspaceID = snapshot.selectedWorkspaceID ?? self.workspaces.first?.id

        observeServerDiscovery()
        observeNetworkPath()
        observeWorkspaceMetadata()
        if eagerlyRestoreSessions {
            rebuildControllers()
            syncSelectedControllerLifecycle()
        }
        observeLifecycle()
    }

    deinit {
        workspaceIdentityTasks.values.forEach { $0.cancel() }
        workspaceMetadataCancellables.values.forEach { $0.cancel() }
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func server(for id: TerminalHost.ID) -> TerminalHost? {
        hosts.first(where: { $0.id == id })
    }

    func workspace(with id: TerminalWorkspace.ID) -> TerminalWorkspace? {
        workspaces.first(where: { $0.id == id })
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
        syncSelectedControllerLifecycle()
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
                    print("Failed to mark remote workspace read: \(error)")
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
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: title,
            tmuxSessionName: "cmux-\(host.name.lowercased().replacingOccurrences(of: " ", with: "-"))-\(UUID().terminalShortID)",
            preview: host.subtitle,
            lastActivity: .now,
            unread: false,
            phase: .idle
        )
        workspaces.insert(workspace, at: 0)
        selectedWorkspaceID = workspace.id
        syncSelectedControllerLifecycle()
        persist()
        ensureBackendIdentityIfNeeded(for: workspace.id)
        startWorkspaceMetadataObservationIfNeeded(for: workspace.id)
        return workspace.id
    }

    func closeWorkspace(_ workspace: TerminalWorkspace) {
        cancelWorkspaceIdentityReservation(for: workspace.id)
        cancelWorkspaceMetadataObservation(for: workspace.id)
        controllers[workspace.id]?.disconnect()
        controllers.removeValue(forKey: workspace.id)
        workspaces.removeAll { $0.id == workspace.id }
        if selectedWorkspaceID == workspace.id {
            selectedWorkspaceID = workspaces.first?.id
        }
        syncSelectedControllerLifecycle()
        persist()
    }

    func toggleUnread(for workspaceID: TerminalWorkspace.ID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[index].unread.toggle()
        persist()
    }

    func controller(for workspace: TerminalWorkspace) -> TerminalSessionController {
        if let existing = controllers[workspace.id] {
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
        NSLog("📱 controller(for:) host=%@ wsPort=%@ hasWS=%d", host.hostname, String(describing: host.wsPort), host.hasWebSocketEndpoint ? 1 : 0)
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

        if let selectedWorkspaceID, removedWorkspaceIDs.contains(selectedWorkspaceID) {
            self.selectedWorkspaceID = workspaces.first?.id
        }

        syncSelectedControllerLifecycle()
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

    func applyDiscoveredHosts(_ discoveredHosts: [TerminalHost]) {
        let existingHostsByID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        var mergedHosts = TerminalServerCatalog.merge(discovered: discoveredHosts, local: hosts)
        let mergedHostIDs = Set(mergedHosts.map(\.id))
        let workspaceHostIDs = Set(workspaces.map(\.hostID))
        let missingWorkspaceHostIDs = workspaceHostIDs.subtracting(mergedHostIDs)

        for hostID in missingWorkspaceHostIDs {
            guard let preservedHost = existingHostsByID[hostID] else { continue }
            mergedHosts.append(preservedHost)
        }

        for index in mergedHosts.indices {
            applyDebugWebSocketConfig(&mergedHosts[index])
        }

        hosts = mergedHosts.sorted(by: { $0.sortIndex < $1.sortIndex })

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

    private func syncSelectedControllerLifecycle() {
        for workspace in workspaces {
            let controller = controller(for: workspace)
            if workspace.id == selectedWorkspaceID {
                controller.resumeIfNeeded()
                ensureBackendIdentityIfNeeded(for: workspace.id)
            } else {
                controller.suspendPreservingState()
            }
        }
    }

    private func observeServerDiscovery() {
        guard let serverDiscovery else { return }
        serverDiscovery.hostsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hosts in
                self?.applyDiscoveredHosts(hosts)
            }
            .store(in: &cancellables)
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
            syncSelectedControllerLifecycle()
            return
        }

        guard previousState != nil,
              let selectedWorkspaceID,
              let workspace = workspace(with: selectedWorkspaceID) else {
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
        if host.wsPort == nil {
            host.wsPort = 9444
            let home = NSHomeDirectory()
            let hostHome = home.components(separatedBy: "/Library/Developer/CoreSimulator").first ?? home
            let secretPath = hostHome + "/Library/Application Support/cmux/mobile-ws-secret"
            NSLog("📱 WS debug: home=%@ hostHome=%@ secretPath=%@ exists=%d", home, hostHome, secretPath, FileManager.default.fileExists(atPath: secretPath) ? 1 : 0)
            if let secret = try? String(contentsOfFile: secretPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               !secret.isEmpty {
                host.wsSecret = secret
                NSLog("📱 WS debug: secret loaded (%d chars)", secret.count)
            } else {
                NSLog("📱 WS debug: failed to load secret")
            }
            host.hostname = "127.0.0.1"
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
            print("Failed to save terminal snapshot: \(error)")
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
                    self.syncSelectedControllerLifecycle()
                }
            }
        )
    }
}

@MainActor
final class TerminalSessionController: ObservableObject {
    let workspaceID: TerminalWorkspace.ID
    var onUpdate: ((TerminalSessionUpdate) -> Void)?

    @Published private(set) var phase: TerminalConnectionPhase
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var surfaceView: GhosttySurfaceView?

    private var host: TerminalHost
    private let workspace: TerminalWorkspace
    private let credentialsStore: TerminalCredentialsStoring
    private let transportFactory: TerminalTransportFactory
    private let surfaceFactory: @MainActor (GhosttySurfaceViewDelegate) throws -> any TerminalSurfaceHosting

    private var terminalSurface: (any TerminalSurfaceHosting)?
    private var remoteDaemonResumeState: TerminalRemoteDaemonResumeState?
    private var transport: TerminalTransport?
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

        _ = ensureTerminalSurface()
    }

    deinit {
        if let surfaceCloseObserver {
            NotificationCenter.default.removeObserver(surfaceCloseObserver)
        }
        if let surfaceBellObserver {
            NotificationCenter.default.removeObserver(surfaceBellObserver)
        }
    }

    func refreshHost(_ host: TerminalHost) {
        self.host = host
        if phase == .needsConfiguration || phase == .failed {
            connectIfNeeded()
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
        guard ensureTerminalSurface(), let terminalSurface else {
            setPhase(.failed, error: errorMessage ?? TerminalStoreStrings.surfaceUnavailableError)
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
        let initialSize = terminalSurface.currentGridSize

        let transport = transportFactory.makeTransport(
            host: host,
            credentials: credentials,
            sessionName: workspace.tmuxSessionName,
            resumeState: remoteDaemonResumeState
        )
        transport.eventHandler = { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
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
                await MainActor.run {
                    let isCurrentTransport = self.isCurrentTransport(transport)
                    if isCurrentTransport {
                        transport.eventHandler = nil
                        self.transport = nil
                        if let sshError = error as? TerminalSSHError {
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
                        if self.shouldAutoReconnect(after: error) {
                            self.scheduleReconnectIfNeeded(after: 2)
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

    func reconnectNow() {
        if isLiveAnchormuxSession {
            liveAnchormuxLog("controller.reconnectNow phase=\(phase)")
        }
        guard phase != .reconnecting, transportDisconnectTask == nil else {
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
            }
        }
        switch event {
        case .connected:
            reconnectTask?.cancel()
            reconnectTask = nil
            setPhase(.connected, error: nil)
            syncRemoteDaemonResumeStateFromTransport()
            terminalSurface?.focusInput()
            if statusMessage != nil {
                scheduleStatusMessageClear(after: 2)
            }
        case .output(let data):
            terminalSurface?.processOutput(data)
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
            scheduleReconnectIfNeeded(after: 2)
        case .notice(let message):
            setStatusMessage(message)
        case .trustedHostKey(let hostKey):
            onUpdate?(.trustedHostKey(hostKey))
        case .remotePlatform(let platform):
            terminalSurface?.updateRemotePlatform(platform)
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
            observeSurfaceClose(for: surface)
            return true
        } catch {
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
    }

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
        transportConnectTask?.cancel()
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
            phase: .connected
        )
        let olderWorkspace = TerminalWorkspace(
            id: olderWorkspaceID,
            hostID: linuxVM.id,
            title: "Linux VM",
            tmuxSessionName: "cmux-linux-vm",
            preview: "cmux@orb:~$",
            lastActivity: Date(timeIntervalSince1970: 1_774_000_000),
            unread: false,
            phase: .disconnected
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
            self.eventHandler?(.output(Data("cmux@fixture:~$ ".utf8)))
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
}
