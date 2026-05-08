import Foundation
import Network
import OSLog
import UIKit

enum CmxTerminalDetailPresentation: Equatable {
    case notConnected
    case loadingWorkspaces
    case noWorkspaces
    case noTerminal
    case loadingTerminal
    case terminal
}

#if DEBUG
nonisolated private let cmxConnectionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "connection"
)

nonisolated private func cmuxDebugLog(_ message: String) {
    cmxConnectionLogger.debug("\(message, privacy: .public)")
}
#endif

protocol CmxHiveTeamPreferenceStoring {
    func loadSelectedTeamID() throws -> String?
    func saveSelectedTeamID(_ teamID: String?) throws
}

struct CmxUserDefaultsHiveTeamPreferenceStore: CmxHiveTeamPreferenceStoring {
    private let userDefaults: UserDefaults
    private let key: String

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "dev.cmux.ios.hive.selected-team-id"
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    func loadSelectedTeamID() throws -> String? {
        CmxStringNormalization.trimmedNonEmpty(userDefaults.string(forKey: key))
    }

    func saveSelectedTeamID(_ teamID: String?) throws {
        if let teamID = CmxStringNormalization.trimmedNonEmpty(teamID) {
            userDefaults.set(teamID, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }
}

protocol CmxHiddenUnavailableNodeStoring {
    func loadHiddenNodeIDs() throws -> Set<UInt64>
    func saveHiddenNodeIDs(_ nodeIDs: Set<UInt64>) throws
}

struct CmxUserDefaultsHiddenUnavailableNodeStore: CmxHiddenUnavailableNodeStoring {
    private let userDefaults: UserDefaults
    private let key: String

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "dev.cmux.ios.hive.hidden-unavailable-node-ids"
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    func loadHiddenNodeIDs() throws -> Set<UInt64> {
        let values = userDefaults.stringArray(forKey: key) ?? []
        return Set(values.compactMap(UInt64.init))
    }

    func saveHiddenNodeIDs(_ nodeIDs: Set<UInt64>) throws {
        userDefaults.set(nodeIDs.map(String.init).sorted(), forKey: key)
    }
}

struct CmxHiveDiscoveryCachePayload: Codable, Equatable, Sendable {
    var teams: [CmxHiveTeam]
    var defaultTeamID: String?
    var selectedTeamID: String?
    var nodes: [CmxHiveNode]
    var workspaces: [CmxWorkspace]
    var cachedAt: Date

    var teamsSnapshot: CmxHiveTeamsSnapshot {
        CmxHiveTeamsSnapshot(
            teams: teams,
            defaultTeamID: defaultTeamID,
            selectedTeamID: selectedTeamID
        )
    }

    var discoverySnapshot: CmxHiveDiscoverySnapshot {
        CmxHiveDiscoverySnapshot(nodes: nodes, workspaces: workspaces)
    }
}

protocol CmxHiveDiscoveryCacheStoring {
    func load() throws -> CmxHiveDiscoveryCachePayload?
    func save(_ payload: CmxHiveDiscoveryCachePayload) throws
    func clear() throws
}

struct CmxUserDefaultsHiveDiscoveryCacheStore: CmxHiveDiscoveryCacheStoring {
    private let userDefaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "dev.cmux.ios.hive.discovery-cache"
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    func load() throws -> CmxHiveDiscoveryCachePayload? {
        guard let data = userDefaults.data(forKey: key) else { return nil }
        return try decoder.decode(CmxHiveDiscoveryCachePayload.self, from: data)
    }

    func save(_ payload: CmxHiveDiscoveryCachePayload) throws {
        let data = try encoder.encode(payload)
        userDefaults.set(data, forKey: key)
    }

    func clear() throws {
        userDefaults.removeObject(forKey: key)
    }
}

@MainActor
final class CmxConnectionStore: ObservableObject {
    private static let placeholderTerminalID = UInt64.max
    private static let maximumCachedTerminalOutputBytes = 512 * 1024
    private static let maximumCachedTerminalOutputChunks = 256
    #if DEBUG
    private static var xctestRetainedStores: [CmxConnectionStore] = []

    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
    #endif

    @Published var ticketText = ""
    @Published private(set) var ticket: CmxBridgeTicket?
    @Published private(set) var errorText: String?
    @Published private(set) var isConnecting = false
    @Published private(set) var isConnected = false
    @Published private(set) var isDiscoveringHive = false
    @Published private(set) var latencyMilliseconds: UInt32?
    @Published private(set) var stackAuthSession: CmxStackAuthSession?
    @Published private(set) var terminalAppearanceRevision = 0
    @Published private(set) var hiveTeams: [CmxHiveTeam] = []
    @Published private(set) var selectedHiveTeamID: String?
    @Published private(set) var defaultHiveTeamID: String?
    @Published private(set) var isLoadingHiveTeams = false
    @Published private(set) var hiddenUnavailableNodeIDs: Set<UInt64> = []
    @Published var nodes: [CmxHiveNode] = []
    @Published var workspaces: [CmxWorkspace] = []
    @Published private(set) var nativeSnapshot: CmxNativeSnapshot?
    @Published var selectedWorkspaceID: UInt64 = 0
    @Published var selectedSpaceID: UInt64 = 0
    @Published var selectedTerminalID: UInt64 = CmxConnectionStore.placeholderTerminalID
    @Published private(set) var effectiveTerminalSizesByID: [UInt64: CmxTerminalSize] = [:]
    @Published private(set) var terminalLayoutRevision = 0
    @Published private(set) var terminalOutputRevision = 0
    private var outputChunksByTerminalID: [UInt64: [CmxTerminalOutputChunk]] = [:]
    private var nextOutputChunkID = 1
    private var cachedOutputByteCountByTerminalID: [UInt64: Int] = [:]
    private let authSessionStore: CmxStackAuthSessionStore
    private let launchTicketStore: CmxLaunchTicketStateStore
    private let pairingSecretClient: CmxRivetPairingSecretFetching
    private let hiveDiscoveryClient: CmxHiveDiscoveryFetching
    private let hiveControlClient: CmxHiveControlFetching
    private let hiveTeamPreferenceStore: CmxHiveTeamPreferenceStoring
    private let hiddenUnavailableNodeStore: CmxHiddenUnavailableNodeStoring
    private let hiveDiscoveryCacheStore: CmxHiveDiscoveryCacheStoring
    private let hiveDiscoveryEndpoint: URL?
    private let terminalSessionFactory: any CmxTerminalSessionMaking
    private var terminalSession: (any CmxTerminalSession)?
    private var connectTask: Task<Void, Never>?
    private var hiveDiscoveryTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "dev.cmux.ios.connection.path")
    private var hasUsableNetworkPath = true
    private var appIsActive = true
    private var reconnectAllowed = false
    private var reconnectPending = false
    private var didUseImmediateReconnectForCurrentLoss = false
    private var terminalScreenVisible = false
    private var localTerminalSizesByID: [UInt64: CmxTerminalSize] = [:]
    private var lastSentNativeLayoutByTerminalID: [UInt64: CmxTerminalSize] = [:]
    private var lastReplayRequest: ReplayRequestKey?
    private var needsReplayAfterSessionStart = false
    private var terminalOutputSink: TerminalOutputSink?
    private var pendingSinkOutputByTerminalID: [UInt64: [CmxTerminalOutputChunk]] = [:]
    private var sinkOutputFlushScheduled = false
    private var currentSessionID: String?
    private var prefetchedWorkspaceIDs: Set<UInt64> = []
    private var pendingHiveAttachTarget: HiveAttachTarget?

    private struct ReplayRequestKey: Equatable {
        var terminalID: UInt64
        var size: CmxTerminalSize
        var outputRevision: Int
    }

    private struct TerminalOutputSink {
        var terminalID: UInt64
        var receive: @MainActor (CmxTerminalOutputChunk) -> Void
    }

    private struct HiveAttachTarget: Equatable {
        var nodeRawID: String
        var localWorkspaceID: String?
        var title: String
    }

    init(
        authSessionStore: CmxStackAuthSessionStore = CmxKeychainStackAuthSessionStore(),
        launchTicketStore: CmxLaunchTicketStateStore = CmxDisabledLaunchTicketStateStore(),
        pairingSecretClient: CmxRivetPairingSecretFetching = CmxRivetPairingSecretClient(),
        hiveDiscoveryClient: CmxHiveDiscoveryFetching = CmxHiveDiscoveryClient(),
        hiveControlClient: CmxHiveControlFetching = CmxHiveControlClient(),
        hiveTeamPreferenceStore: CmxHiveTeamPreferenceStoring = CmxUserDefaultsHiveTeamPreferenceStore(),
        hiddenUnavailableNodeStore: CmxHiddenUnavailableNodeStoring = CmxUserDefaultsHiddenUnavailableNodeStore(),
        hiveDiscoveryCacheStore: CmxHiveDiscoveryCacheStoring = CmxUserDefaultsHiveDiscoveryCacheStore(),
        hiveDiscoveryEndpoint: URL? = CmxLaunchConfiguration.hiveDiscoveryEndpoint(),
        terminalSessionFactory: any CmxTerminalSessionMaking = CmxDefaultTerminalSessionFactory(),
        startHiveDiscoveryOnInit: Bool = true,
        startLifecycleObserversOnInit: Bool = false,
        launchTicket: String? = CmxLaunchConfiguration.ticket(),
        launchAutoconnect: Bool = CmxLaunchConfiguration.shouldAutoconnect()
    ) {
        self.authSessionStore = authSessionStore
        self.launchTicketStore = launchTicketStore
        self.pairingSecretClient = pairingSecretClient
        self.hiveDiscoveryClient = hiveDiscoveryClient
        self.hiveControlClient = hiveControlClient
        self.hiveTeamPreferenceStore = hiveTeamPreferenceStore
        self.hiddenUnavailableNodeStore = hiddenUnavailableNodeStore
        self.hiveDiscoveryCacheStore = hiveDiscoveryCacheStore
        self.hiveDiscoveryEndpoint = hiveDiscoveryEndpoint
        self.terminalSessionFactory = terminalSessionFactory
        stackAuthSession = try? authSessionStore.load()
        selectedHiveTeamID = try? hiveTeamPreferenceStore.loadSelectedTeamID()
        hiddenUnavailableNodeIDs = (try? hiddenUnavailableNodeStore.loadHiddenNodeIDs()) ?? []
        let explicitLaunchTicket = launchTicket.flatMap(Self.nonEmptyTicket)
        let storedLaunchState = explicitLaunchTicket == nil ? (try? launchTicketStore.load()) : nil
        let storedLaunchTicket = storedLaunchState.flatMap { Self.nonEmptyTicket($0.ticket) }
        let resolvedLaunchTicket = explicitLaunchTicket ?? storedLaunchTicket
        let resolvedAutoconnect = launchAutoconnect || (explicitLaunchTicket == nil && storedLaunchState?.autoconnect == true)
        if let explicitLaunchTicket {
            try? launchTicketStore.save(CmxLaunchTicketState(ticket: explicitLaunchTicket, autoconnect: launchAutoconnect))
        }
        if let ticket = resolvedLaunchTicket {
            ticketText = ticket
            clearWorkspaceState()
        } else {
            restoreCachedHiveDiscoveryIfAvailable()
        }
        seedTerminalOutput()
        if startLifecycleObserversOnInit {
            startLifecycleObservers()
        }
        if startHiveDiscoveryOnInit {
            refreshHiveDiscoveryIfPossible()
        }
        if resolvedAutoconnect {
            Task { @MainActor [weak self] in
                self?.connect()
            }
        }
        #if DEBUG
        retainForXCTestIfNeeded()
        #endif
    }

    isolated deinit {
        hiveDiscoveryTask?.cancel()
        pathMonitor?.cancel()
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    #if DEBUG
    private func retainForXCTestIfNeeded() {
        guard Self.isRunningUnderXCTest else { return }
        Self.xctestRetainedStores.append(self)
    }
    #endif

    var selectedWorkspace: CmxWorkspace {
        workspaces.first(where: { $0.id == selectedWorkspaceID }) ?? workspaces.first ?? Self.placeholderWorkspace
    }

    var selectedSpace: CmxSpace {
        selectedWorkspace.spaces.first(where: { $0.id == selectedSpaceID })
            ?? selectedWorkspace.spaces.first
            ?? CmxSpace(id: 0, title: String(localized: "demo.space.space1", defaultValue: "space-1"), terminals: [])
    }

    var selectedTerminal: CmxTerminal {
        selectedSpace.terminals.first(where: { $0.id == selectedTerminalID })
            ?? selectedWorkspace.spaces.flatMap(\.terminals).first(where: { $0.id == selectedTerminalID })
            ?? selectedSpace.terminals.first
            ?? workspaces.flatMap(\.spaces).flatMap(\.terminals).first
            ?? CmxTerminal(
                id: Self.placeholderTerminalID,
                title: String(localized: "demo.terminal.cmx", defaultValue: "cmx"),
                size: .phoneDefault,
                rows: []
            )
    }

    var selectedHostPlatform: CmxHostPlatform {
        node(for: selectedWorkspace).platform
    }

    var effectiveHiveTeamID: String? {
        selectedHiveTeamID ?? defaultHiveTeamID ?? hiveTeams.first(where: \.isPersonal)?.id ?? hiveTeams.first?.id
    }

    var isAwaitingInitialWorkspaceSnapshot: Bool {
        workspaces.isEmpty
            && nativeSnapshot == nil
            && errorText == nil
            && (isConnecting || isConnected)
    }

    var canRenderSelectedTerminal: Bool {
        selectedTerminalID != Self.placeholderTerminalID && terminal(matching: selectedTerminalID) != nil
    }

    var selectedTerminalOutputIsReady: Bool {
        guard canRenderSelectedTerminal else { return false }
        return outputChunksByTerminalID[selectedTerminalID, default: []]
            .contains { Self.containsRenderableTerminalOutput($0.data) }
    }

    var terminalDetailPresentation: CmxTerminalDetailPresentation {
        guard isConnecting || isConnected else {
            return .notConnected
        }
        if workspaces.isEmpty {
            if isAwaitingInitialWorkspaceSnapshot {
                return .loadingWorkspaces
            }
            return .noWorkspaces
        }
        if canRenderSelectedTerminal {
            return selectedTerminalOutputIsReady ? .terminal : .loadingTerminal
        }
        if let nativeWorkspace = nativeSnapshot?.workspaces.first(where: { $0.id == selectedWorkspaceID }) {
            return nativeWorkspace.terminalCount == 0 ? .noTerminal : .loadingTerminal
        }
        return isConnecting || isConnected ? .loadingTerminal : .noTerminal
    }

    var statusText: String {
        if isConnecting {
            return String(localized: "status.connecting", defaultValue: "Connecting")
        }
        if isConnected {
            return String(localized: "status.connected", defaultValue: "Connected")
        }
        if let errorText {
            return errorText
        }
        return String(localized: "status.ready", defaultValue: "Ready")
    }

    var latencyText: String? {
        guard let latencyMilliseconds else { return nil }
        return String(
            format: String(localized: "status.latency_ms", defaultValue: "%d ms"),
            Int(latencyMilliseconds)
        )
    }

    func connect() {
        connect(isAutomaticReconnect: false)
    }

    private func connect(isAutomaticReconnect: Bool) {
        #if DEBUG
        cmuxDebugLog("ios.connection.connect automatic=\(isAutomaticReconnect ? 1 : 0)")
        #endif
        do {
            let rawTicket = ticketText.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = try CmxBridgeTicketParser.parse(rawTicket)
            try? launchTicketStore.save(CmxLaunchTicketState(ticket: rawTicket, autoconnect: true))
            reconnectAllowed = true
            reconnectPending = false
            if !isAutomaticReconnect {
                didUseImmediateReconnectForCurrentLoss = false
            }
            latencyMilliseconds = nil
            connectTask?.cancel()
            if parsed.auth?.requiresStackSession == true {
                guard let stackAuthSession else {
                    throw CmxConnectionError.missingStackAuthSession
                }
                ticket = parsed
                updateConnectedNode(for: parsed)
                errorText = nil
                isConnecting = true
                isConnected = false
                connectTask = Task { @MainActor [weak self] in
                    await self?.connectWithPairingSecret(
                        rawTicket: rawTicket,
                        ticket: parsed,
                        stackAuthSession: stackAuthSession
                    )
                }
                return
            }
            try startTerminalSession(rawTicket: rawTicket, ticket: parsed, pairingSecret: nil)
        } catch {
            #if DEBUG
            cmuxDebugLog("ios.connection.connect.failed error=\(error.localizedDescription)")
            #endif
            reconnectAllowed = false
            reconnectPending = false
            terminalSession?.disconnect()
            terminalSession = nil
            ticket = nil
            latencyMilliseconds = nil
            errorText = error.localizedDescription
            isConnecting = false
            isConnected = false
        }
    }

    func handleOpenURL(_ url: URL) {
        do {
            let session = try CmxStackAuthCallback.parse(url: url)
            try authSessionStore.save(session)
            stackAuthSession = session
            errorText = nil
            refreshHiveDiscoveryIfPossible()
        } catch {
            errorText = error.localizedDescription
        }
    }

    func signOut() {
        do {
            try authSessionStore.clear()
            try launchTicketStore.clear()
            try hiveDiscoveryCacheStore.clear()
            stackAuthSession = nil
            hiveDiscoveryTask?.cancel()
            hiveDiscoveryTask = nil
            isDiscoveringHive = false
        } catch {
            errorText = error.localizedDescription
        }
    }

    func disconnect() {
        #if DEBUG
        cmuxDebugLog("ios.connection.disconnect")
        #endif
        reconnectAllowed = false
        reconnectPending = false
        connectTask?.cancel()
        connectTask = nil
        pendingHiveAttachTarget = nil
        terminalSession?.disconnect()
        terminalSession = nil
        lastSentNativeLayoutByTerminalID = [:]
        lastReplayRequest = nil
        needsReplayAfterSessionStart = false
        currentSessionID = nil
        prefetchedWorkspaceIDs = []
        latencyMilliseconds = nil
        isConnecting = false
        isConnected = false
    }

    func select(workspace: CmxWorkspace) {
        selectedWorkspaceID = workspace.id
        if let firstSpace = workspace.spaces.first {
            selectedSpaceID = firstSpace.id
        }
        selectedTerminalID = firstTerminalID(in: workspace) ?? Self.placeholderTerminalID
        let node = node(for: workspace)
        if shouldAttachToHiveWorkspace(workspace, node: node) {
            attachToHiveWorkspace(workspace, node: node)
            return
        }
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            terminalSession?.sendCommand(.selectWorkspace(index: index))
        }
        syncNativeLayoutForVisibleTerminal(force: true)
        if requestPtyReplayForVisibleTerminalIfCacheIsEmpty() {
            needsReplayAfterSessionStart = false
        }
    }

    func prefetch(workspace: CmxWorkspace) {
        guard let terminalID = firstTerminalID(in: workspace) else { return }
        guard prefetchedWorkspaceIDs.insert(workspace.id).inserted else { return }
        guard outputChunksByTerminalID[terminalID, default: []].isEmpty else { return }
        terminalSession?.requestPtyReplay(terminalID: terminalID)
    }

    func togglePinned(for workspace: CmxWorkspace) {
        let nextPinned = !workspace.pinned
        updateWorkspace(workspace.id) { $0.pinned = nextPinned }
        terminalSession?.sendCommand(.setWorkspacePinned(workspaceID: workspace.id, pinned: nextPinned))
    }

    func toggleUnread(for workspace: CmxWorkspace) {
        let nextUnread = !workspace.unread
        updateWorkspace(workspace.id) { $0.unread = nextUnread }
        terminalSession?.sendCommand(.setWorkspaceUnread(workspaceID: workspace.id, unread: nextUnread))
    }

    func select(workspaceID: UInt64) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        select(workspace: workspace)
    }

    func select(space: CmxSpace) {
        selectedSpaceID = space.id
        selectedTerminalID = space.terminals.first?.id ?? Self.placeholderTerminalID
        if let index = selectedWorkspace.spaces.firstIndex(where: { $0.id == space.id }) {
            terminalSession?.sendCommand(.selectSpace(index: index))
        }
        syncNativeLayoutForVisibleTerminal(force: true)
        if requestPtyReplayForVisibleTerminalIfCacheIsEmpty() {
            needsReplayAfterSessionStart = false
        }
    }

    func select(terminal: CmxTerminal) {
        selectedTerminalID = terminal.id
        if let selection = nativeSnapshot?.panels.selection(for: terminal.id) {
            terminalSession?.sendCommand(.selectTabInPanel(panelID: selection.panelID, index: selection.index))
        }
        syncNativeLayoutForVisibleTerminal(force: true)
        if requestPtyReplayForVisibleTerminalIfCacheIsEmpty() {
            needsReplayAfterSessionStart = false
        }
    }

    func terminalScreenDidAppear() {
        terminalScreenVisible = true
        syncNativeLayoutForVisibleTerminal(force: true)
        if requestPtyReplayForVisibleTerminalIfCacheIsEmpty() {
            needsReplayAfterSessionStart = false
        }
    }

    func terminalScreenDidDisappear() {
        terminalScreenVisible = false
        terminalSession?.sendNativeLayout([])
        lastSentNativeLayoutByTerminalID = [:]
    }

    func node(for workspace: CmxWorkspace) -> CmxHiveNode {
        nodes.first(where: { $0.id == workspace.nodeID }) ?? CmxHiveNode(
            id: 0,
            rawID: "unknown",
            name: String(localized: "node.unknown.name", defaultValue: "Unknown Node"),
            subtitle: String(localized: "node.unknown.subtitle", defaultValue: "not discovered"),
            symbolName: "questionmark.circle",
            platform: .unknown,
            isOnline: false
        )
    }

    func workspaceCount(for node: CmxHiveNode) -> Int {
        workspaces.filter { $0.nodeID == node.id }.count
    }

    func visibleWorkspaces(
        matching query: String,
        filter: CmxWorkspaceVisibilityFilter = .all
    ) -> [CmxWorkspace] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = workspaces.sorted { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity {
                return lhs.lastActivity > rhs.lastActivity
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        let filtered = sorted.filter { workspace in
            let node = node(for: workspace)
            switch filter {
            case .all:
                return node.isOnline || !hiddenUnavailableNodeIDs.contains(node.id)
            case .online:
                return node.isOnline
            case .offline:
                return !node.isOnline && !hiddenUnavailableNodeIDs.contains(node.id)
            case .hiddenUnavailable:
                return !node.isOnline && hiddenUnavailableNodeIDs.contains(node.id)
            }
        }
        guard !trimmed.isEmpty else { return filtered }
        return filtered.filter { workspace in
            let node = node(for: workspace)
            return workspace.title.localizedCaseInsensitiveContains(trimmed)
                || workspace.preview.localizedCaseInsensitiveContains(trimmed)
                || node.name.localizedCaseInsensitiveContains(trimmed)
                || node.subtitle.localizedCaseInsensitiveContains(trimmed)
                || workspace.spaces.contains { $0.title.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    private func shouldAttachToHiveWorkspace(_: CmxWorkspace, node: CmxHiveNode) -> Bool {
        guard node.isOnline else { return false }
        guard node.attachTicket?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        if let expiresAtUnix = node.attachTicketExpiresAtUnix,
           Date().timeIntervalSince1970 >= TimeInterval(expiresAtUnix) {
            return false
        }
        if let ticketNodeID = ticket?.node?.id,
           ticketNodeID == node.rawID,
           terminalSession != nil {
            return false
        }
        return true
    }

    private func attachToHiveWorkspace(_ workspace: CmxWorkspace, node: CmxHiveNode) {
        guard let attachTicket = node.attachTicket?.trimmingCharacters(in: .whitespacesAndNewlines),
              !attachTicket.isEmpty else { return }
        pendingHiveAttachTarget = HiveAttachTarget(
            nodeRawID: node.rawID,
            localWorkspaceID: workspace.localWorkspaceID,
            title: workspace.title
        )
        ticketText = attachTicket
        connect()
    }

    func selectHiveTeam(id: String?) {
        let trimmedTeamID = CmxStringNormalization.trimmedNonEmpty(id)
        selectedHiveTeamID = trimmedTeamID
        do {
            try hiveTeamPreferenceStore.saveSelectedTeamID(trimmedTeamID)
        } catch {
            errorText = error.localizedDescription
        }
        refreshHiveDiscoveryIfPossible()
    }

    func hideUnavailableWorkspaces(from node: CmxHiveNode) {
        guard !node.isOnline else { return }
        hiddenUnavailableNodeIDs.insert(node.id)
        saveHiddenUnavailableNodeIDs()
    }

    func showUnavailableWorkspaces(from node: CmxHiveNode) {
        hiddenUnavailableNodeIDs.remove(node.id)
        saveHiddenUnavailableNodeIDs()
    }

    func showAllHiddenUnavailableWorkspaces() {
        hiddenUnavailableNodeIDs = []
        saveHiddenUnavailableNodeIDs()
    }

    @discardableResult
    func unlinkHiveNode(_ node: CmxHiveNode) -> Task<Void, Never>? {
        guard let hiveDiscoveryEndpoint,
              let stackAuthSession else { return nil }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await hiveControlClient.unlinkNode(
                    nodeID: node.rawID,
                    endpoint: hiveDiscoveryEndpoint,
                    stackSession: stackAuthSession,
                    teamID: effectiveHiveTeamID
                )
                removeHiveNodeLocally(node)
                errorText = nil
            } catch {
                errorText = error.localizedDescription
            }
        }
        return task
    }

    func terminalSize(for terminalID: UInt64) -> CmxTerminalSize {
        localTerminalSizesByID[terminalID] ?? terminal(matching: terminalID)?.size ?? .phoneDefault
    }

    func renderSize(for terminalID: UInt64) -> CmxTerminalSize? {
        guard let effectiveSize = effectiveTerminalSizesByID[terminalID] else {
            return nil
        }
        let localSize = terminalSize(for: terminalID)
        let clampedSize = CmxTerminalSize(
            cols: min(localSize.cols, effectiveSize.cols),
            rows: min(localSize.rows, effectiveSize.rows)
        )
        return clampedSize == localSize ? nil : clampedSize
    }

    func outputChunks(for terminalID: UInt64) -> [CmxTerminalOutputChunk] {
        outputChunksByTerminalID[terminalID] ?? []
    }

    func latestOutputChunkID(for terminalID: UInt64) -> Int {
        outputChunksByTerminalID[terminalID]?.last?.id ?? 0
    }

    func registerOutputSink(
        terminalID: UInt64,
        receive: @escaping @MainActor (CmxTerminalOutputChunk) -> Void
    ) {
        pendingSinkOutputByTerminalID[terminalID] = nil
        terminalOutputSink = TerminalOutputSink(terminalID: terminalID, receive: receive)
    }

    func unregisterOutputSink(terminalID: UInt64) {
        guard terminalOutputSink?.terminalID == terminalID else { return }
        terminalOutputSink = nil
        pendingSinkOutputByTerminalID[terminalID] = nil
    }

    func updateTerminalSize(terminalID: UInt64, size: CmxTerminalSize) {
        guard size.cols > 0, size.rows > 0 else { return }
        guard terminalID != Self.placeholderTerminalID else { return }
        let previousRenderSize = renderSize(for: terminalID)
        if terminalSize(for: terminalID) != size {
            localTerminalSizesByID[terminalID] = size
            if previousRenderSize != renderSize(for: terminalID) {
                terminalLayoutRevision += 1
            }
        }
        if terminalScreenVisible, terminalID == selectedTerminal.id {
            sendNativeLayout(
                terminalID: terminalID,
                size: size,
                force: false
            )
            if outputChunksByTerminalID[terminalID, default: []].isEmpty {
                requestPtyReplayForVisibleTerminal()
            }
        }
    }

    func requestPtyReplay(terminalID: UInt64) {
        guard terminalID != Self.placeholderTerminalID else { return }
        guard terminalID == selectedTerminal.id else { return }
        terminalSession?.requestPtyReplay(terminalID: terminalID)
    }

    func sendInput(_ data: Data, terminalID: UInt64) {
        guard terminalID != Self.placeholderTerminalID else { return }
        if terminalID == selectedTerminal.id, let terminalSession {
            terminalSession.sendInput(data, terminalID: terminalID)
            return
        }
        appendOutput(renderEcho(for: data), terminalID: terminalID)
    }

    private func seedTerminalOutput() {
        for terminal in workspaces.flatMap({ $0.spaces }).flatMap({ $0.terminals }) {
            appendOutput(initialOutput(for: terminal), terminalID: terminal.id)
        }
    }

    @discardableResult
    func refreshHiveDiscoveryIfPossible() -> Task<Void, Never>? {
        guard let hiveDiscoveryEndpoint,
              let stackAuthSession else { return nil }
        hiveDiscoveryTask?.cancel()
        isDiscoveringHive = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                isLoadingHiveTeams = true
                do {
                    let teamsSnapshot = try await hiveControlClient.fetchTeams(
                        endpoint: hiveDiscoveryEndpoint,
                        stackSession: stackAuthSession
                    )
                    applyHiveTeamsSnapshot(teamsSnapshot)
                    isLoadingHiveTeams = false
                } catch {
                    isLoadingHiveTeams = false
                    #if DEBUG
                    cmuxDebugLog("ios.connection.hiveTeams.failed error=\(error.localizedDescription)")
                    #endif
                }
                let snapshot = try await hiveDiscoveryClient.fetchHive(
                    endpoint: hiveDiscoveryEndpoint,
                    stackSession: stackAuthSession,
                    teamID: effectiveHiveTeamID
                )
                applyHiveDiscoverySnapshot(snapshot)
                errorText = nil
            } catch is CancellationError {
                return
            } catch {
                isLoadingHiveTeams = false
                errorText = error.localizedDescription
            }
            isDiscoveringHive = false
        }
        hiveDiscoveryTask = task
        return task
    }

    private static var placeholderWorkspace: CmxWorkspace {
        CmxWorkspace(
            id: 0,
            nodeID: 0,
            title: String(localized: "workspace.placeholder.title", defaultValue: "Workspace"),
            preview: "",
            lastActivity: Date(),
            unread: false,
            pinned: false,
            spaces: []
        )
    }

    private static func nonEmptyTicket(_ ticket: String) -> String? {
        let trimmed = ticket.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func appendOutput(_ data: Data, terminalID: UInt64) {
        guard !data.isEmpty else { return }
        let chunk = CmxTerminalOutputChunk(id: nextOutputChunkID, data: data)
        nextOutputChunkID += 1
        outputChunksByTerminalID[terminalID, default: []].append(chunk)
        cachedOutputByteCountByTerminalID[terminalID, default: 0] += data.count
        trimCachedOutput(for: terminalID)
        terminalOutputRevision += 1
        enqueueSinkOutput(chunk, terminalID: terminalID)
    }

    private func enqueueSinkOutput(_ chunk: CmxTerminalOutputChunk, terminalID: UInt64) {
        guard terminalOutputSink?.terminalID == terminalID else { return }
        pendingSinkOutputByTerminalID[terminalID, default: []].append(chunk)
        guard !sinkOutputFlushScheduled else { return }
        sinkOutputFlushScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.flushSinkOutput()
        }
    }

    private func flushSinkOutput() {
        sinkOutputFlushScheduled = false
        guard let terminalOutputSink else {
            pendingSinkOutputByTerminalID.removeAll(keepingCapacity: true)
            return
        }
        let terminalID = terminalOutputSink.terminalID
        guard let chunks = pendingSinkOutputByTerminalID.removeValue(forKey: terminalID),
              !chunks.isEmpty else {
            pendingSinkOutputByTerminalID = pendingSinkOutputByTerminalID.filter { $0.key == terminalID }
            return
        }
        var data = Data()
        data.reserveCapacity(chunks.reduce(0) { $0 + $1.data.count })
        for chunk in chunks {
            data.append(chunk.data)
        }
        terminalOutputSink.receive(
            CmxTerminalOutputChunk(id: chunks.last?.id ?? 0, data: data)
        )
        pendingSinkOutputByTerminalID = pendingSinkOutputByTerminalID.filter { $0.key == terminalID }
        if pendingSinkOutputByTerminalID[terminalID]?.isEmpty == false {
            sinkOutputFlushScheduled = true
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.flushSinkOutput()
            }
        }
    }

    private func clearTerminal(_ terminalID: UInt64) {
        clearCachedOutput(for: terminalID)
    }

    private static func containsRenderableTerminalOutput(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0x1B:
                index = skipTerminalEscapeSequence(in: bytes, startingAt: index)
            case 0x21...0x7E, 0xC2...0xF4:
                return true
            default:
                index += 1
            }
        }
        return false
    }

    private static func skipTerminalEscapeSequence(in bytes: [UInt8], startingAt escapeIndex: Int) -> Int {
        let nextIndex = escapeIndex + 1
        guard nextIndex < bytes.count else { return bytes.count }
        let introducer = bytes[nextIndex]
        switch introducer {
        case 0x5B:
            return skipTerminalCsiSequence(in: bytes, startingAt: nextIndex + 1)
        case 0x5D, 0x50, 0x5E, 0x5F, 0x58:
            return skipTerminalStringEscapeSequence(in: bytes, startingAt: nextIndex + 1)
        case 0x28, 0x29, 0x2A, 0x2B, 0x2D, 0x2E, 0x2F:
            return min(nextIndex + 2, bytes.count)
        default:
            return nextIndex + 1
        }
    }

    private static func skipTerminalCsiSequence(in bytes: [UInt8], startingAt startIndex: Int) -> Int {
        var index = startIndex
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if (0x40...0x7E).contains(byte) {
                return index
            }
        }
        return index
    }

    private static func skipTerminalStringEscapeSequence(in bytes: [UInt8], startingAt startIndex: Int) -> Int {
        var index = startIndex
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x07 {
                return index + 1
            }
            if byte == 0x1B,
               index + 1 < bytes.count,
               bytes[index + 1] == 0x5C {
                return index + 2
            }
            index += 1
        }
        return index
    }

    private func clearCachedOutput(for terminalID: UInt64) {
        outputChunksByTerminalID[terminalID] = []
        cachedOutputByteCountByTerminalID[terminalID] = 0
    }

    private func trimCachedOutput(for terminalID: UInt64) {
        guard var chunks = outputChunksByTerminalID[terminalID],
              chunks.count > Self.maximumCachedTerminalOutputChunks
                || cachedOutputByteCountByTerminalID[terminalID, default: 0] > Self.maximumCachedTerminalOutputBytes else {
            return
        }

        var cachedBytes = cachedOutputByteCountByTerminalID[terminalID]
            ?? chunks.reduce(0) { $0 + $1.data.count }
        while chunks.count > 1,
              chunks.count > Self.maximumCachedTerminalOutputChunks
                || cachedBytes > Self.maximumCachedTerminalOutputBytes {
            cachedBytes -= chunks.removeFirst().data.count
        }
        outputChunksByTerminalID[terminalID] = chunks
        cachedOutputByteCountByTerminalID[terminalID] = max(0, cachedBytes)
    }

    private func pendingNativeWorkspaceSelection(in snapshot: CmxNativeSnapshot) -> (workspaceID: UInt64, index: Int)? {
        guard let pendingHiveAttachTarget else { return nil }
        if let localWorkspaceID = pendingHiveAttachTarget.localWorkspaceID {
            let trimmedLocalID = localWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
            var candidateIDs: [UInt64] = []
            if let numericID = UInt64(trimmedLocalID), numericID != 0 {
                candidateIDs.append(numericID)
            }
            if !trimmedLocalID.isEmpty {
                candidateIDs.append(CmxStableID.uint64(for: "\(pendingHiveAttachTarget.nodeRawID):\(trimmedLocalID)"))
                candidateIDs.append(CmxStableID.uint64(for: trimmedLocalID))
            }
            if let index = snapshot.workspaces.firstIndex(where: { candidateIDs.contains($0.id) }) {
                return (snapshot.workspaces[index].id, index)
            }
        }
        if let index = snapshot.workspaces.firstIndex(where: { $0.title == pendingHiveAttachTarget.title }) {
            return (snapshot.workspaces[index].id, index)
        }
        return nil
    }

    func applyNativeSnapshot(_ snapshot: CmxNativeSnapshot) {
        guard !snapshot.workspaces.isEmpty else {
            // The Rust daemon keeps at least one workspace alive. Empty native
            // snapshots are startup/stale frames, so wait for the next real
            // snapshot instead of replacing the home screen with false empty state.
            #if DEBUG
            cmuxDebugLog("ios.connection.nativeSnapshot.ignored_empty")
            #endif
            return
        }
        let previousSelectedTerminalID = selectedTerminalID
        let previousSelectedRenderSize = renderSize(for: selectedTerminalID)
        let previousActiveWorkspaceID = nativeSnapshot?.activeWorkspaceID
        nativeSnapshot = snapshot
        applyTerminalAppearance(from: snapshot, colorPreference: currentColorPreference)
        effectiveTerminalSizesByID = effectiveTerminalSizes(from: snapshot)
        let nodeID = nodes.first?.id ?? 1
        let activeTabs = snapshot.panels.flattenedTabs
        let activeTerminals = activeTabs.map { tab in
            CmxTerminal(
                id: tab.id,
                title: tab.title,
                size: terminalSize(for: tab.id),
                rows: []
            )
        }
        let activeSpaces = snapshot.spaces.map { space in
            CmxSpace(
                id: space.id,
                title: space.title,
                terminals: space.id == snapshot.activeSpaceID ? activeTerminals : []
            )
        }
        let now = Date()
        workspaces = snapshot.workspaces.map { workspace in
            let isActiveWorkspace = workspace.id == snapshot.activeWorkspaceID
            let spaces = isActiveWorkspace ? activeSpaces : [
                CmxSpace(id: workspace.id, title: workspace.title, terminals: []),
            ]
            return CmxWorkspace(
                id: workspace.id,
                nodeID: nodeID,
                title: workspace.title,
                preview: String(
                    format: String(localized: "workspace.row.detail", defaultValue: "%d spaces, %d terminals"),
                    max(workspace.spaceCount, spaces.count),
                    workspace.terminalCount
                ),
                lastActivity: now,
                unread: workspace.hasActivity,
                pinned: workspace.pinned,
                spaces: spaces,
                localWorkspaceID: String(workspace.id)
            )
        }
        if workspaces.isEmpty {
            localTerminalSizesByID = [:]
            outputChunksByTerminalID = [:]
            cachedOutputByteCountByTerminalID = [:]
            nextOutputChunkID = 1
        }
        let pendingWorkspaceSelection = pendingNativeWorkspaceSelection(in: snapshot)
        if let pendingWorkspaceSelection {
            terminalSession?.sendCommand(.selectWorkspace(index: pendingWorkspaceSelection.index))
            pendingHiveAttachTarget = nil
        }
        selectedWorkspaceID = pendingWorkspaceSelection?.workspaceID
            ?? workspaces.first(where: { $0.id == snapshot.activeWorkspaceID })?.id
            ?? workspaces.first?.id
            ?? 0
        let selectedWorkspace = selectedWorkspace
        selectedSpaceID = selectedWorkspace.spaces.first(where: { $0.id == snapshot.activeSpaceID })?.id
            ?? selectedWorkspace.spaces.first?.id
            ?? 0
        selectedTerminalID = activeTerminals.first(where: { $0.id == snapshot.focusedTabID })?.id
            ?? activeTerminals.first?.id
            ?? Self.placeholderTerminalID
        #if DEBUG
        cmuxDebugLog(
            "ios.connection.nativeSnapshot.applied workspace=\(selectedWorkspaceID) space=\(selectedSpaceID) terminal=\(selectedTerminalID)"
        )
        #endif
        let didChangeActiveWorkspace = snapshot.activeWorkspaceID != previousActiveWorkspaceID
        let didChangeSelectedTerminal = selectedTerminalID != previousSelectedTerminalID
        let didChangeSelectedRenderSize = previousSelectedRenderSize != renderSize(for: selectedTerminalID)
        if didChangeActiveWorkspace {
            clearCachedOutput(for: selectedTerminalID)
        }
        if didChangeSelectedTerminal || didChangeActiveWorkspace {
            lastReplayRequest = nil
        }
        guard terminalScreenVisible else { return }
        syncNativeLayoutForVisibleTerminal(force: didChangeSelectedTerminal || didChangeActiveWorkspace)
        if didChangeSelectedTerminal || didChangeActiveWorkspace || didChangeSelectedRenderSize || needsReplayAfterSessionStart {
            if requestPtyReplayForVisibleTerminalIfCacheIsEmpty() {
                needsReplayAfterSessionStart = false
            }
        }
    }

    func applyHiveDiscoverySnapshot(_ snapshot: CmxHiveDiscoverySnapshot) {
        nodes = snapshot.nodes
        guard !isConnecting, !isConnected else { return }
        workspaces = snapshot.workspaces
        localTerminalSizesByID = [:]
        effectiveTerminalSizesByID = [:]
        outputChunksByTerminalID = [:]
        cachedOutputByteCountByTerminalID = [:]
        nextOutputChunkID = 1
        seedTerminalOutput()
        let sortedVisibleWorkspaces = visibleWorkspaces(matching: "")
        selectedWorkspaceID = sortedVisibleWorkspaces.first(where: { $0.id == selectedWorkspaceID })?.id
            ?? sortedVisibleWorkspaces.first?.id
            ?? workspaces.first?.id
            ?? 0
        let selectedWorkspace = selectedWorkspace
        selectedSpaceID = selectedWorkspace.spaces.first(where: { $0.id == selectedSpaceID })?.id
            ?? selectedWorkspace.spaces.first?.id
            ?? 0
        selectedTerminalID = selectedWorkspace.spaces
            .flatMap(\.terminals)
            .first(where: { $0.id == selectedTerminalID })?.id
            ?? firstTerminalID(in: selectedWorkspace)
            ?? Self.placeholderTerminalID
        saveHiveDiscoveryCache()
    }

    func applyHiveTeamsSnapshot(_ snapshot: CmxHiveTeamsSnapshot) {
        hiveTeams = snapshot.teams
        defaultHiveTeamID = snapshot.defaultTeamID
        if let selectedHiveTeamID,
           !snapshot.teams.contains(where: { $0.id == selectedHiveTeamID }) {
            self.selectedHiveTeamID = nil
            try? hiveTeamPreferenceStore.saveSelectedTeamID(nil)
        }
        saveHiveDiscoveryCache()
    }

    private func restoreCachedHiveDiscoveryIfAvailable() {
        guard let cached = try? hiveDiscoveryCacheStore.load() else { return }
        hiveTeams = cached.teams
        defaultHiveTeamID = cached.defaultTeamID
        if selectedHiveTeamID == nil {
            selectedHiveTeamID = cached.selectedTeamID
        }
        nodes = cached.nodes
        workspaces = cached.workspaces
        let sortedVisibleWorkspaces = visibleWorkspaces(matching: "")
        selectedWorkspaceID = sortedVisibleWorkspaces.first?.id ?? workspaces.first?.id ?? 0
        let selectedWorkspace = selectedWorkspace
        selectedSpaceID = selectedWorkspace.spaces.first?.id ?? 0
        selectedTerminalID = firstTerminalID(in: selectedWorkspace) ?? Self.placeholderTerminalID
    }

    private func saveHiveDiscoveryCache() {
        guard !isConnecting, !isConnected else { return }
        let payload = CmxHiveDiscoveryCachePayload(
            teams: hiveTeams,
            defaultTeamID: defaultHiveTeamID,
            selectedTeamID: selectedHiveTeamID,
            nodes: nodes,
            workspaces: workspaces,
            cachedAt: Date()
        )
        try? hiveDiscoveryCacheStore.save(payload)
    }

    private func updateWorkspace(_ workspaceID: UInt64, mutate: (inout CmxWorkspace) -> Void) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        mutate(&workspaces[index])
    }

    private func removeHiveNodeLocally(_ node: CmxHiveNode) {
        nodes.removeAll { $0.id == node.id }
        workspaces.removeAll { $0.nodeID == node.id }
        hiddenUnavailableNodeIDs.remove(node.id)
        saveHiddenUnavailableNodeIDs()
        selectedWorkspaceID = workspaces.first(where: { $0.id == selectedWorkspaceID })?.id
            ?? workspaces.first?.id
            ?? 0
        let selectedWorkspace = selectedWorkspace
        selectedSpaceID = selectedWorkspace.spaces.first?.id ?? 0
        selectedTerminalID = firstTerminalID(in: selectedWorkspace) ?? Self.placeholderTerminalID
    }

    private func saveHiddenUnavailableNodeIDs() {
        do {
            try hiddenUnavailableNodeStore.saveHiddenNodeIDs(hiddenUnavailableNodeIDs)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func clearWorkspaceState() {
        nodes = []
        workspaces = []
        nativeSnapshot = nil
        selectedWorkspaceID = 0
        selectedSpaceID = 0
        selectedTerminalID = Self.placeholderTerminalID
        localTerminalSizesByID = [:]
        effectiveTerminalSizesByID = [:]
        outputChunksByTerminalID = [:]
        cachedOutputByteCountByTerminalID = [:]
        nextOutputChunkID = 1
        prefetchedWorkspaceIDs = []
        pendingHiveAttachTarget = nil
    }

    func refreshTerminalAppearance(colorPreference: CmxTerminalColorPreference) {
        guard let nativeSnapshot else { return }
        applyTerminalAppearance(from: nativeSnapshot, colorPreference: colorPreference)
    }

    func resumePendingConnectionIfNeeded() {
        guard reconnectPending, reconnectAllowed, !isConnecting, canAttemptReconnect else { return }
        reconnectPending = false
        connect(isAutomaticReconnect: true)
    }

    func refreshConnectionForLifecycleSignal() {
        guard reconnectAllowed, canAttemptReconnect, !isConnecting else { return }
        didUseImmediateReconnectForCurrentLoss = false
        reconnectPending = true
        resumePendingConnectionIfNeeded()
    }

    private func updateConnectedNode(for ticket: CmxBridgeTicket) {
        nodes = [
            CmxHiveNodeFactory.connectedNode(for: ticket),
        ]
    }

    private func syncNativeLayoutForVisibleTerminal(force: Bool = false) {
        guard terminalScreenVisible else { return }
        let terminal = selectedTerminal
        guard terminal.id != Self.placeholderTerminalID else { return }
        sendNativeLayout(terminalID: terminal.id, size: terminal.size, force: force)
    }

    @discardableResult
    private func sendNativeLayout(terminalID: UInt64, size: CmxTerminalSize, force: Bool) -> Bool {
        guard size.cols > 0, size.rows > 0 else { return false }
        if !force, lastSentNativeLayoutByTerminalID[terminalID] == size {
            return false
        }
        lastSentNativeLayoutByTerminalID[terminalID] = size
        #if DEBUG
        cmuxDebugLog("ios.connection.nativeLayout tab=\(terminalID) cols=\(size.cols) rows=\(size.rows) force=\(force ? 1 : 0)")
        #endif
        terminalSession?.sendNativeLayout([
            CmxWireTerminalViewport(
                tabID: terminalID,
                cols: UInt16(clamping: size.cols),
                rows: UInt16(clamping: size.rows)
            ),
        ])
        return terminalSession != nil
    }

    @discardableResult
    private func requestPtyReplayForVisibleTerminal(force: Bool = false) -> Bool {
        guard terminalScreenVisible else { return false }
        let terminal = selectedTerminal
        guard terminal.id != Self.placeholderTerminalID else { return false }
        let request = ReplayRequestKey(
            terminalID: terminal.id,
            size: renderSize(for: terminal.id) ?? terminalSize(for: terminal.id),
            outputRevision: terminalOutputRevision
        )
        if !force, lastReplayRequest == request {
            return false
        }
        lastReplayRequest = request
        #if DEBUG
        cmuxDebugLog("ios.connection.requestPtyReplay tab=\(terminal.id) force=\(force ? 1 : 0)")
        #endif
        terminalSession?.requestPtyReplay(terminalID: terminal.id)
        return terminalSession != nil
    }

    @discardableResult
    private func requestPtyReplayForVisibleTerminalIfCacheIsEmpty() -> Bool {
        let terminal = selectedTerminal
        guard terminal.id != Self.placeholderTerminalID else { return false }
        guard outputChunksByTerminalID[terminal.id, default: []].isEmpty else { return false }
        return requestPtyReplayForVisibleTerminal()
    }

    private func effectiveTerminalSizes(from snapshot: CmxNativeSnapshot) -> [UInt64: CmxTerminalSize] {
        var sizes: [UInt64: CmxTerminalSize] = [:]
        for client in snapshot.attachedClients {
            if client.clientID == currentSessionID {
                continue
            }
            for terminal in client.terminals where terminal.cols > 0 && terminal.rows > 0 {
                let size = CmxTerminalSize(cols: Int(terminal.cols), rows: Int(terminal.rows))
                if let current = sizes[terminal.tabID] {
                    sizes[terminal.tabID] = CmxTerminalSize(
                        cols: min(current.cols, size.cols),
                        rows: min(current.rows, size.rows)
                    )
                } else {
                    sizes[terminal.tabID] = size
                }
            }
        }
        return sizes
    }

    private func connectWithPairingSecret(
        rawTicket: String,
        ticket: CmxBridgeTicket,
        stackAuthSession: CmxStackAuthSession
    ) async {
        do {
            guard let auth = ticket.auth else {
                throw CmxTicketError.missingAuth
            }
            let secret = try await pairingSecretClient.fetchSecret(for: auth, stackSession: stackAuthSession, now: Date())
            try startTerminalSession(rawTicket: rawTicket, ticket: ticket, pairingSecret: secret.secret)
        } catch is CancellationError {
            return
        } catch {
            self.ticket = nil
            latencyMilliseconds = nil
            errorText = error.localizedDescription
            isConnecting = false
            isConnected = false
        }
    }

    private func startTerminalSession(
        rawTicket: String,
        ticket parsed: CmxBridgeTicket,
        pairingSecret: String?
    ) throws {
        let previousSession = terminalSession
        previousSession?.delegate = nil
        previousSession?.disconnect()
        lastSentNativeLayoutByTerminalID = [:]
        lastReplayRequest = nil
        needsReplayAfterSessionStart = true
        currentSessionID = nil
        prefetchedWorkspaceIDs = []
        let session = try terminalSessionFactory.makeSession(
            rawTicket: rawTicket,
            ticket: parsed,
            pairingSecret: pairingSecret,
            stackAuthSession: stackAuthSession
        )
        session.delegate = self
        terminalSession = session
        ticket = parsed
        updateConnectedNode(for: parsed)
        errorText = nil
        isConnecting = true
        isConnected = false
        if selectedTerminal.id != Self.placeholderTerminalID {
            clearTerminal(selectedTerminal.id)
        }
        #if DEBUG
        let selectedTerminalLogID = selectedTerminal.id == Self.placeholderTerminalID ? "none" : "\(selectedTerminal.id)"
        cmuxDebugLog("ios.connection.session.start alpn=\(parsed.alpn) terminal=\(selectedTerminalLogID)")
        #endif
        session.start(viewport: wireViewport(for: selectedTerminal.id))
    }

    private func terminal(matching terminalID: UInt64) -> CmxTerminal? {
        workspaces
            .flatMap(\.spaces)
            .flatMap(\.terminals)
            .first(where: { $0.id == terminalID })
    }

    private func firstTerminalID(in workspace: CmxWorkspace) -> UInt64? {
        workspace.spaces
            .flatMap(\.terminals)
            .first?.id
    }

    private func wireViewport(for terminalID: UInt64) -> CmxWireViewport {
        let size = terminalSize(for: terminalID)
        return CmxWireViewport(
            cols: UInt16(clamping: size.cols),
            rows: UInt16(clamping: size.rows)
        )
    }

    private var currentColorPreference: CmxTerminalColorPreference {
        UITraitCollection.current.userInterfaceStyle == .light ? .light : .dark
    }

    private func applyTerminalAppearance(
        from snapshot: CmxNativeSnapshot,
        colorPreference: CmxTerminalColorPreference
    ) {
        if GhosttyRuntime.applyRemoteConfigOverride(snapshot.ghosttyConfigFragment(colorPreference: colorPreference)) {
            terminalAppearanceRevision += 1
        }
    }

    private func initialOutput(for terminal: CmxTerminal) -> Data {
        let esc = "\u{001B}"
        return Data(("\(esc)[2J\(esc)[H\(terminal.title)\r\n\r\n" + terminal.rows.joined(separator: "\r\n") + "\r\n\r\nios$ ").utf8)
    }

    private func renderEcho(for data: Data) -> Data {
        if data == Data([0x03]) {
            return Data("^C\r\nios$ ".utf8)
        }
        if data == Data([0x04]) {
            return Data("^D\r\nios$ ".utf8)
        }
        if data == Data([0x0C]) {
            return Data("\u{001B}[2J\u{001B}[Hios$ ".utf8)
        }
        if data == Data([0x7F]) {
            return Data("\u{8} \u{8}".utf8)
        }
        let normalized = data.map { byte -> UInt8 in
            byte == 0x0D ? 0x0A : byte
        }
        guard let text = String(bytes: normalized, encoding: .utf8) else {
            return Data()
        }
        if text.contains("\n") {
            return Data(text.replacingOccurrences(of: "\n", with: "\r\nios$ ").utf8)
        }
        return Data(text.utf8)
    }

    private var canAttemptReconnect: Bool {
        appIsActive && hasUsableNetworkPath
    }

    private func startLifecycleObservers() {
        appIsActive = UIApplication.shared.applicationState != .background
        let center = NotificationCenter.default
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.appIsActive = true
                    self?.didUseImmediateReconnectForCurrentLoss = false
                    self?.refreshHiveDiscoveryIfPossible()
                    self?.refreshConnectionForLifecycleSignal()
                }
            }
        )
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.appIsActive = false
                }
            }
        )

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let wasUsable = self.hasUsableNetworkPath
                self.hasUsableNetworkPath = path.status == .satisfied
                if self.hasUsableNetworkPath, !wasUsable {
                    self.didUseImmediateReconnectForCurrentLoss = false
                    self.refreshHiveDiscoveryIfPossible()
                    self.refreshConnectionForLifecycleSignal()
                }
            }
        }
        pathMonitor = monitor
        monitor.start(queue: pathMonitorQueue)
    }

    private func handleTransportLoss(error: Error? = nil) {
        #if DEBUG
        if let error {
            cmuxDebugLog("ios.connection.transportLoss error=\(error.localizedDescription)")
        } else {
            cmuxDebugLog("ios.connection.transportLoss")
        }
        #endif
        if let error {
            errorText = error.localizedDescription
        }
        latencyMilliseconds = nil
        terminalSession = nil
        isConnecting = false
        isConnected = false
        guard reconnectAllowed else { return }
        reconnectPending = true
        guard canAttemptReconnect, !didUseImmediateReconnectForCurrentLoss else { return }
        didUseImmediateReconnectForCurrentLoss = true
        resumePendingConnectionIfNeeded()
    }
}

extension CmxConnectionStore: CmxTerminalSessionDelegate {
    func terminalSession(_ session: any CmxTerminalSession, didReceive message: CmxServerMessage) {
        guard session === terminalSession else { return }
        processTerminalSessionMessages([message])
    }

    func terminalSession(_ session: any CmxTerminalSession, didReceive messages: [CmxServerMessage]) {
        guard session === terminalSession else { return }
        processTerminalSessionMessages(messages)
    }

    private func processTerminalSessionMessages(_ messages: [CmxServerMessage]) {
        var pendingPtyTabID: UInt64?
        var pendingPtyData = Data()

        func flushPendingPtyBytes() {
            guard let tabID = pendingPtyTabID else { return }
            #if DEBUG
            cmuxDebugLog("ios.connection.ptyBytes tab=\(tabID) bytes=\(pendingPtyData.count)")
            #endif
            appendOutput(pendingPtyData, terminalID: tabID)
            pendingPtyTabID = nil
            pendingPtyData.removeAll(keepingCapacity: true)
        }

        for message in messages {
            if case .ptyBytes(let tabID, let data) = message {
                if pendingPtyTabID == tabID {
                    pendingPtyData.append(data)
                } else {
                    flushPendingPtyBytes()
                    pendingPtyTabID = tabID
                    pendingPtyData = data
                }
                continue
            }
            flushPendingPtyBytes()
            processTerminalSessionControlMessage(message)
        }
        flushPendingPtyBytes()
    }

    private func processTerminalSessionControlMessage(_ message: CmxServerMessage) {
        switch message {
        case .welcome(_, let sessionID):
            currentSessionID = sessionID
            #if DEBUG
            cmuxDebugLog("ios.connection.welcome")
            #endif
            isConnecting = false
            isConnected = true
            errorText = nil
            reconnectPending = false
            didUseImmediateReconnectForCurrentLoss = false
        case .ptyBytes:
            break
        case .hostControl, .commandReply:
            break
        case .nativeSnapshot(let snapshot):
            #if DEBUG
            cmuxDebugLog("ios.connection.nativeSnapshot workspaces=\(snapshot.workspaces.count)")
            #endif
            applyNativeSnapshot(snapshot)
        case .terminalGridSnapshot:
            // iOS requests the libghostty renderer, so terminal cells arrive
            // as raw PTY bytes. Server-grid snapshots are ignored if an older
            // bridge sends them anyway.
            break
        case .activeTabChanged, .activeWorkspaceChanged, .activeSpaceChanged, .pong:
            break
        case .bye:
            handleTransportLoss()
        case .error(let message):
            #if DEBUG
            cmuxDebugLog("ios.connection.serverError message=\(message)")
            #endif
            reconnectAllowed = false
            reconnectPending = false
            latencyMilliseconds = nil
            errorText = message
            terminalSession = nil
            isConnecting = false
            isConnected = false
        case .unsupported(let kind):
            errorText = String(
                format: String(localized: "ticket.error.unsupported_server_message", defaultValue: "Unsupported cmx server message %@."),
                kind
            )
        }
    }

    func terminalSession(_ session: any CmxTerminalSession, didUpdateLatencyMilliseconds latencyMilliseconds: UInt32) {
        guard session === terminalSession else { return }
        self.latencyMilliseconds = latencyMilliseconds
        #if DEBUG
        cmuxDebugLog("ios.connection.latency ms=\(latencyMilliseconds)")
        #endif
    }

    func terminalSession(_ session: any CmxTerminalSession, didFail error: Error) {
        guard session === terminalSession else { return }
        #if DEBUG
        cmuxDebugLog("ios.connection.session.fail error=\(error.localizedDescription)")
        #endif
        handleTransportLoss(error: error)
    }

    func terminalSessionDidClose(_ session: any CmxTerminalSession) {
        guard session === terminalSession else { return }
        #if DEBUG
        cmuxDebugLog("ios.connection.session.close")
        #endif
        handleTransportLoss()
    }
}

enum CmxConnectionError: LocalizedError {
    case missingStackAuthSession

    var errorDescription: String? {
        switch self {
        case .missingStackAuthSession:
            String(localized: "ticket.error.stack_auth_required", defaultValue: "Sign in with Stack Auth before using this Rivet pairing ticket.")
        }
    }
}

private enum CmxStringNormalization {
    static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
