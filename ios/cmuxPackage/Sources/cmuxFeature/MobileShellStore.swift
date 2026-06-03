import CMUXMobileCore
import CmuxMobileAuth
import CmuxMobileDiagnostics
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTransport
import Foundation
import Observation
import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)


@MainActor
@Observable
public final class CMUXMobileShellStore {
    private enum TerminalOutputTransport: Equatable {
        case renderGrid
        case rawBytes

        var eventTopics: [String] {
            switch self {
            case .renderGrid:
                return ["workspace.updated", "terminal.render_grid"]
            case .rawBytes:
                return ["workspace.updated", "terminal.bytes"]
            }
        }
    }

    private static let terminalRenderGridCapability = "terminal.render_grid.v1"
    private static let terminalOutputCapabilityTimeoutNanoseconds: UInt64 = 750_000_000

    /// How long the render-grid stream may stay silent (no event of any topic)
    /// before the liveness watchdog assumes the push subscription is dead and
    /// forces a re-subscribe + replay. Picked at the low end of the acceptable
    /// 8-12s window so a wedged stream recovers in a few seconds instead of the
    /// transport's ~85s timeout, while staying well above any normal inter-event
    /// gap on a busy shell.
    private static let renderGridLivenessSilenceThreshold: TimeInterval = 9
    /// Cadence of the liveness watchdog tick. It only reads a timestamp and
    /// compares against the threshold, so a short interval is cheap; it does not
    /// reschedule per received event (an actively-streaming connection just keeps
    /// failing the silence check because `lastTerminalEventAt` stays fresh).
    private static let renderGridLivenessCheckInterval: TimeInterval = 2.5

    public private(set) var isSignedIn: Bool
    public private(set) var connectionState: MobileConnectionState
    public private(set) var connectedHostName: String
    public private(set) var connectionError: String?
    public private(set) var activeTicket: CmxAttachTicket?
    public private(set) var activeRoute: CmxAttachRoute?
    public var hasActiveUnexpiredAttachTicket: Bool {
        guard let activeTicket,
              activeTicket.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        return Self.attachTicketIsUnexpired(activeTicket, now: runtime?.now() ?? Date())
    }
    public var pairingCode: String
    public var workspaces: [MobileWorkspacePreview]
    public var terminalInputText: String
    public var selectedWorkspaceID: MobileWorkspacePreview.ID? {
        didSet {
            syncSelectedTerminalForWorkspace()
        }
    }
    public var selectedTerminalID: MobileTerminalPreview.ID?

    private let runtime: CMUXMobileRuntime?
    private let pairedMacStore: MobilePairedMacStore?
    private let clientID: String
    private var remoteClient: MobileCoreRPCClient? {
        didSet {
            if remoteClient == nil {
                stopTerminalRefreshPolling()
                cancelRemoteOperationTasks()
                resetTerminalOutputTracking()
            }
        }
    }
    private var terminalEventListenerTask: Task<Void, Never>?
    private var terminalEventListenerID: UUID?
    // Liveness watchdog for the render-grid push subscription. The `for await`
    // listener loop blocks indefinitely if the underlying connection half-dies
    // (network blip, Mac stops pushing, background/foreground cycle): the
    // AsyncStream neither yields a new event nor finishes, so the loop sits
    // silent and the phone shows a stale frame while the Mac advances thousands
    // of render-grid deltas. The transport's own timeout (~85s) is far too slow.
    // A `DispatchSourceTimer` ticks independently of the (potentially wedged)
    // stream and compares "now" against the last received event to detect
    // prolonged silence, then tears down + re-subscribes + replays.
    private var renderGridLivenessTimer: DispatchSourceTimer?
    private var renderGridLivenessListenerID: UUID?
    private var lastTerminalEventAt: Date?
    private var terminalSubscriptionRefreshTask: Task<Void, Never>?
    private var createWorkspaceTask: Task<Void, Never>?
    private var createTerminalTask: Task<Void, Never>?
    private var workspaceListRefreshTask: Task<Void, Never>?
    private var createWorkspaceTaskID: UUID?
    private var createTerminalTaskID: UUID?
    private var connectionGeneration: UUID
    private var reportedViewportSizesByTerminalKey: [MobileTerminalViewportKey: MobileTerminalViewportSize]
    private var deliveredTerminalByteEndSeqBySurfaceID: [String: UInt64]
    private var pendingTerminalByteEndSeqBySurfaceID: [String: UInt64]
    private var terminalReplaySurfaceIDsInFlight: Set<String>
    private var terminalOutputTransport: TerminalOutputTransport
    private var rawTerminalInputBuffer: MobileTerminalInputSendBuffer
    private var pairingAttemptID: UUID

    public var phase: MobileShellPhase {
        if !isSignedIn {
            return .signIn
        }
        if connectionState != .connected {
            return .pairing
        }
        return .workspaces
    }

    public var selectedWorkspace: MobileWorkspacePreview? {
        guard let selectedWorkspaceID else {
            return workspaces.first
        }
        return workspaces.first { $0.id == selectedWorkspaceID } ?? workspaces.first
    }

    private var selectedTerminal: MobileTerminalPreview? {
        guard let selectedWorkspace else {
            return nil
        }
        if let selectedTerminalID,
           let terminal = selectedWorkspace.terminals.first(where: { $0.id == selectedTerminalID }) {
            return terminal
        }
        return selectedWorkspace.preferredTerminal
    }

    public init(
        runtime: CMUXMobileRuntime? = nil,
        isSignedIn: Bool = false,
        connectionState: MobileConnectionState = .disconnected,
        connectedHostName: String = "",
        pairingCode: String = "",
        workspaces: [MobileWorkspacePreview] = [],
        pairedMacStore: MobilePairedMacStore? = MobileShellStorePairedMacStoreFactory.shared()
    ) {
        self.runtime = runtime
        self.pairedMacStore = pairedMacStore
        self.clientID = Self.loadClientID()
        self.isSignedIn = isSignedIn
        self.connectionState = connectionState
        self.connectedHostName = connectedHostName
        self.pairingCode = pairingCode
        self.workspaces = workspaces
        self.terminalInputText = ""
        self.connectionError = nil
        self.activeTicket = nil
        self.activeRoute = nil
        self.selectedWorkspaceID = workspaces.first?.id
        self.selectedTerminalID = workspaces.first?.terminals.first?.id
        self.remoteClient = nil
        self.terminalEventListenerTask = nil
        self.terminalEventListenerID = nil
        self.terminalSubscriptionRefreshTask = nil
        self.createWorkspaceTask = nil
        self.createTerminalTask = nil
        self.workspaceListRefreshTask = nil
        self.createWorkspaceTaskID = nil
        self.createTerminalTaskID = nil
        self.connectionGeneration = UUID()
        self.reportedViewportSizesByTerminalKey = [:]
        self.deliveredTerminalByteEndSeqBySurfaceID = [:]
        self.pendingTerminalByteEndSeqBySurfaceID = [:]
        self.terminalReplaySurfaceIDsInFlight = []
        self.terminalOutputTransport = .rawBytes
        self.rawTerminalInputBuffer = MobileTerminalInputSendBuffer()
        self.pairingAttemptID = UUID()
    }

    isolated deinit {
        terminalEventListenerTask?.cancel()
        renderGridLivenessTimer?.cancel()
        terminalSubscriptionRefreshTask?.cancel()
        createWorkspaceTask?.cancel()
        createTerminalTask?.cancel()
        workspaceListRefreshTask?.cancel()
        if let remoteClient {
            Task { await remoteClient.disconnect() }
        }
    }

    public static func preview(runtime: CMUXMobileRuntime? = nil) -> CMUXMobileShellStore {
        CMUXMobileShellStore(runtime: runtime, workspaces: PreviewMobileHost.workspaces)
    }

    private static let clientIDDefaultsKey = "dev.cmux.mobile.clientID"

    private static func loadClientID() -> String {
        if let existing = UserDefaults.standard.string(forKey: clientIDDefaultsKey),
           UUID(uuidString: existing) != nil {
            return existing
        }

        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: clientIDDefaultsKey)
        return created
    }

    public func signIn() {
        isSignedIn = true
        connectionError = nil
    }

    public func signOut() {
        pairingAttemptID = UUID()
        connectionGeneration = UUID()
        isSignedIn = false
        connectionState = .disconnected
        connectedHostName = ""
        pairingCode = ""
        terminalInputText = ""
        connectionError = nil
        activeTicket = nil
        activeRoute = nil
        replaceRemoteClient(with: nil)
        cancelRemoteOperationTasks()
        rawTerminalInputBuffer.clear()
        reportedViewportSizesByTerminalKey = [:]
        workspaces = PreviewMobileHost.workspaces
        selectedWorkspaceID = workspaces.first?.id
        selectedTerminalID = workspaces.first?.terminals.first?.id
    }

    public func resumeForegroundRefresh() {
        startObservingNetworkPathChanges()
        resyncTerminalOutput(reason: "foreground", restartEventStream: true)
    }

    // MARK: - Network recovery

    /// True while an automatic reconnect is in progress after a network change
    /// or drop.
    public private(set) var isRecoveringConnection: Bool = false
    /// True when automatic recovery could not restore the connection; the UI
    /// surfaces a manual Retry control in this state.
    public private(set) var connectionRecoveryFailed: Bool = false

    private var networkPathObservationStarted = false
    private var recoveryInFlight = false
    private var recoveryTask: Task<Void, Never>?
    private var lastReconnectStackUserID: String?

    private enum RecoveryTrigger: CustomStringConvertible {
        case networkChange
        case manual
        var description: String {
            switch self {
            case .networkChange: return "networkChange"
            case .manual: return "manual"
            }
        }
    }

    /// Begin observing meaningful network path changes (Wi-Fi<->cellular,
    /// offline->online) so a live terminal recovers when the network moves out
    /// from under it. Idempotent; only the first call arms the observation.
    func startObservingNetworkPathChanges() {
        guard !networkPathObservationStarted else { return }
        networkPathObservationStarted = true
        observeNetworkPathGeneration()
    }

    private func observeNetworkPathGeneration() {
        withObservationTracking {
            _ = NetworkReachability.shared.pathChangeGeneration
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeNetworkPathGeneration()
                self.recoverMobileConnection(trigger: .networkChange)
            }
        }
    }

    /// User-initiated reconnect from the Retry control.
    public func retryMobileConnection() {
        connectionRecoveryFailed = false
        recoverMobileConnection(trigger: .manual)
    }

    /// Single guarded recovery entry for every trigger (network change, manual
    /// Retry). When still connected, a network move usually only broke the event
    /// stream while input keeps flowing over the surviving connection, so a
    /// resync re-subscribes and requests a render-grid replay to repaint.
    /// Otherwise the connection dropped, so reconnect once; on failure the UI
    /// shows Retry and the next network change re-attempts automatically.
    private func recoverMobileConnection(trigger: RecoveryTrigger) {
        guard remoteClient != nil || pairedMacStore != nil else { return }
        if connectionState == .connected, remoteClient != nil {
            connectionRecoveryFailed = false
            resyncTerminalOutput(reason: "networkRecovery.\(trigger)", restartEventStream: true)
            return
        }
        guard !recoveryInFlight else { return }
        recoveryInFlight = true
        isRecoveringConnection = true
        connectionRecoveryFailed = false
        let stackUserID = lastReconnectStackUserID
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            defer {
                self?.recoveryInFlight = false
                self?.isRecoveringConnection = false
            }
            guard let self, self.connectionState != .connected else { return }
            let reconnected = await self.reconnectActiveMacIfAvailable(stackUserID: stackUserID)
            if !reconnected, !Task.isCancelled {
                self.connectionRecoveryFailed = true
            }
        }
    }

    public func connectPreviewHost() {
        let trimmedCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            return
        }
        if trimmedCode.hasPrefix("cmux-ios://") {
            return
        }
        let attemptID = beginPairingAttempt()
        replaceRemoteClient(with: nil)
        connectionError = nil
        activeTicket = nil
        activeRoute = nil
        connectedHostName = PreviewMobileHost.hostName
        guard isCurrentPairingAttempt(attemptID) else { return }
        connectionState = .connected
        if selectedWorkspaceID == nil {
            selectedWorkspaceID = workspaces.first?.id
        }
        syncSelectedTerminalForWorkspace()
    }

    public func connectPairingInput() async {
        let trimmedCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            return
        }
        if trimmedCode.hasPrefix("cmux-ios://") {
            await connectPairingURL(trimmedCode)
            return
        }
        connectPreviewHost()
    }

    public func connectManualHost(name: String, host: String, port: Int) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedHost = MobileShellRouteAuthPolicy.normalizedManualHost(host) else {
            connectionError = L10n.string("mobile.addDevice.invalidHost", defaultValue: "Enter a host or IP address, without spaces or URL paths.")
            connectionState = .disconnected
            clearRemoteConnectionContext()
            return
        }
        guard (1...65535).contains(port) else {
            connectionError = L10n.string("mobile.addDevice.invalidPort", defaultValue: "Enter a port from 1 to 65535.")
            connectionState = .disconnected
            clearRemoteConnectionContext()
            return
        }

        let directRoute = try? Self.manualHostRoute(host: normalizedHost, port: port)
        let attemptID = beginPairingAttempt()
        do {
            let ticket = try await manualHostTicket(
                name: trimmedName,
                host: normalizedHost,
                port: port
            )
            guard isCurrentPairingAttempt(attemptID) else { return }
            try await connect(ticket: ticket, allowsStackAuthFallback: true)
        } catch is CancellationError {
            guard isCurrentPairingAttempt(attemptID) else { return }
            connectionState = .disconnected
            clearRemoteConnectionContext()
        } catch {
            guard isCurrentPairingAttempt(attemptID) else { return }
            mobileShellLog.error("manual host pairing failed: \(String(describing: error), privacy: .private)")
            connectionError = Self.localizedConnectionError(for: error, route: activeRoute ?? directRoute)
            connectionState = .disconnected
            clearRemoteConnectionContext()
        }
    }

    /// On launch (after StackAuth has bootstrapped), call this to reconnect
    /// to the last-active paired Mac. Pulls (route, displayName, macDeviceID)
    /// from SQLite and re-mints an attach ticket via the StackAuth-authenticated
    /// manual host flow. Auth tokens never persist; we always re-mint.
    @discardableResult
    public func reconnectActiveMacIfAvailable(stackUserID: String?) async -> Bool {
        lastReconnectStackUserID = stackUserID
        startObservingNetworkPathChanges()
        guard let pairedMacStore else { return false }
        guard isSignedIn else { return false }
        let saved: MobilePairedMac?
        do {
            saved = try await pairedMacStore.activeMac(stackUserID: stackUserID)
        } catch {
            mobileShellLog.error("paired mac store activeMac failed: \(String(describing: error), privacy: .public)")
            return false
        }
        guard let mac = saved else { return false }
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        guard let (host, port) = Self.firstReconnectHostPortRoute(
            mac.routes,
            supportedKinds: supportedKinds
        ) else { return false }
        await connectManualHost(name: mac.displayName ?? host, host: host, port: port)
        return connectionState == .connected
    }

    static func firstReconnectHostPortRoute(
        _ routes: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind]
    ) -> (String, Int)? {
        let supportedKinds = Set(supportedKinds)
        for route in routes.sorted(by: routeSortsBefore) {
            if !supportedKinds.isEmpty, !supportedKinds.contains(route.kind) {
                continue
            }
            if case let .hostPort(host, port) = route.endpoint {
                return (host, port)
            }
        }
        return nil
    }

    private func persistPairedMacFromTicket(_ ticket: CmxAttachTicket) async {
        guard let pairedMacStore else { return }
        guard !ticket.macDeviceID.isEmpty else { return }
        // Strip routes that we can't reconnect to without server-side state
        // (manual-workspace routes have no real macDeviceID and aren't useful).
        guard ticket.macDeviceID != "manual-ticket-request",
              !ticket.macDeviceID.hasPrefix("manual-") else { return }
        let stackUserID = AuthManager.shared.currentUser?.id
        do {
            try await pairedMacStore.upsert(
                macDeviceID: ticket.macDeviceID,
                displayName: ticket.macDisplayName,
                routes: ticket.routes,
                markActive: true,
                stackUserID: stackUserID
            )
        } catch {
            mobileShellLog.error("paired mac store upsert failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func manualHostRoute(host: String, port: Int) throws -> CmxAttachRoute {
        let routeKind = MobileShellRouteAuthPolicy.manualRouteKind(for: host)
        return try CmxAttachRoute(
            id: routeKind.rawValue,
            kind: routeKind,
            endpoint: .hostPort(host: host, port: port)
        )
    }

    @discardableResult
    public func connectPairingURL(_ rawValue: String? = nil) async -> Bool {
        await connectPairingURLResult(rawValue).didConnect
    }

    @discardableResult
    public func connectPairingURLResult(_ rawValue: String? = nil) async -> MobilePairingURLConnectionResult {
        let rawURL = Self.normalizedPairingURL(rawValue ?? pairingCode)
        let attemptID = beginPairingAttempt()
        let ticket: CmxAttachTicket
        do {
            ticket = try CmxAttachTicketInput.decode(rawURL)
        } catch {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            connectionError = L10n.string("mobile.pairing.invalidCode", defaultValue: "Invalid pairing code.")
            connectionState = .disconnected
            clearRemoteConnectionContext()
            return .failed
        }

        do {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            try await connect(ticket: ticket)
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            return connectionState == .connected && activeTicket != nil ? .connected : .failed
        } catch is CancellationError {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            connectionState = .disconnected
            clearRemoteConnectionContext()
            return .failed
        } catch {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            mobileShellLog.error("pairing failed: \(String(describing: error), privacy: .private)")
            connectionError = Self.localizedConnectionError(for: error, route: activeRoute)
            connectionState = .disconnected
            clearRemoteConnectionContext()
            return .failed
        }
    }

    public func cancelPairing() {
        pairingAttemptID = UUID()
        connectionError = nil
        connectionState = .disconnected
        clearRemoteConnectionContext()
    }

    /// Disconnect from the currently paired Mac and forget it so the next
    /// session starts from a fresh QR scan. Clears in-memory state and the
    /// persisted active flag (other macs in SQLite stay, but none are marked
    /// active so reconnect-on-launch is a no-op until the user pairs again).
    public func disconnectAndForgetActiveMac() {
        let staleMacID = activeTicket?.macDeviceID
        pairingAttemptID = UUID()
        connectionError = nil
        connectionState = .disconnected
        clearRemoteConnectionContext()
        if let pairedMacStore, let macID = staleMacID {
            // Fire-and-forget: forgetting the persisted mac is cleanup that must
            // not block the synchronous disconnect UI state update above.
            Task {
                do {
                    try await pairedMacStore.remove(macDeviceID: macID)
                } catch {
                    mobileShellLog.error("forgetActiveMac removal failed: \(String(describing: error), privacy: .private)")
                }
            }
        }
    }

    private static func normalizedPairingURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("cmux-ios://") else {
            return trimmed
        }
        let scalars = trimmed.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private func manualHostTicket(name: String, host: String, port: Int) async throws -> CmxAttachTicket {
        let directRoute = try Self.manualHostRoute(host: host, port: port)
        let displayName = name.isEmpty ? host : name
        if MobileShellRouteAuthPolicy.routeAllowsStackAuth(directRoute) {
            do {
                let ticket = try await requestManualAttachTicket(
                    route: directRoute,
                    displayName: displayName
                )
                return ticket
            } catch {
                guard Self.shouldFallbackToSyntheticManualTicket(after: error) else {
                    throw error
                }
            }
            return try Self.manualHostTicket(
                displayName: displayName,
                macDeviceID: "manual-\(host):\(port)",
                route: directRoute
            )
        }
        return try Self.manualHostTicket(
            displayName: displayName,
            macDeviceID: "manual-\(host):\(port)",
            route: directRoute
        )
    }

    private static func shouldFallbackToSyntheticManualTicket(after error: Error) -> Bool {
        guard case let MobileShellConnectionError.rpcError(code, message) = error else {
            return false
        }
        let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let normalizedCode,
           ["method_not_found", "not_found", "unknown_method", "unsupported_method"].contains(normalizedCode) {
            return true
        }
        return normalizedMessage.contains("unknown method")
            || normalizedMessage.contains("method not found")
            || normalizedMessage.contains("unsupported method")
            || normalizedMessage.contains("ticket unavailable")
            || normalizedMessage.contains("ticket not available")
    }

    private static func manualHostTicket(
        displayName: String,
        macDeviceID: String,
        route: CmxAttachRoute
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "manual-workspace",
            terminalID: nil,
            macDeviceID: macDeviceID,
            macDisplayName: displayName,
            routes: [route],
            expiresAt: Date().addingTimeInterval(60 * 60)
        )
    }

    private func requestManualAttachTicket(
        route: CmxAttachRoute,
        displayName: String
    ) async throws -> CmxAttachTicket {
        guard let runtime else {
            throw MobileShellConnectionError.insecureManualRoute
        }
        let probeTicket = try Self.manualHostTicket(
            displayName: displayName,
            macDeviceID: "manual-ticket-request",
            route: route
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: probeTicket,
            allowsStackAuthFallback: true
        )
        let resultData = try await client.sendRequest(
            MobileCoreRPCClient.requestData(
                method: "mobile.attach_ticket.create",
                params: [
                    "ttl_seconds": 3600,
                    "scope": "mac",
                ]
            ),
            timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
        )
        let response = try MobileManualAttachTicketCreateResponse.decode(resultData)
        return try response.ticket.constrainingRoutes(to: [route], fallbackDisplayName: displayName)
    }

    public func createWorkspace() {
        guard remoteClient == nil else {
            guard createWorkspaceTask == nil else { return }
            let taskID = UUID()
            createWorkspaceTaskID = taskID
            createWorkspaceTask = Task { @MainActor [weak self] in
                defer { self?.clearCreateWorkspaceTask(id: taskID) }
                guard let self else { return }
                await self.createRemoteWorkspace()
            }
            return
        }
        let nextIndex = workspaces.count + 1
        let workspace = MobileWorkspacePreview(
            id: .init(rawValue: "workspace-\(nextIndex)"),
            name: L10n.workspaceName(index: nextIndex),
            terminals: [
                MobileTerminalPreview(
                    id: .init(rawValue: "workspace-\(nextIndex)-terminal-1"),
                    name: L10n.terminalName(index: 1)
                ),
            ]
        )
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
        selectedTerminalID = workspace.terminals.first?.id
    }

    public func createTerminal() {
        guard remoteClient == nil else {
            guard createTerminalTask == nil else { return }
            let taskID = UUID()
            createTerminalTaskID = taskID
            createTerminalTask = Task { @MainActor [weak self] in
                defer { self?.clearCreateTerminalTask(id: taskID) }
                guard let self else { return }
                await self.createRemoteTerminal()
            }
            return
        }
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == selectedWorkspace?.id }) else {
            return
        }
        let terminalIndex = workspaces[workspaceIndex].terminals.count + 1
        let terminal = MobileTerminalPreview(
            id: .init(rawValue: "\(workspaces[workspaceIndex].id.rawValue)-terminal-\(terminalIndex)"),
            name: L10n.terminalName(index: terminalIndex)
        )
        workspaces[workspaceIndex].terminals.append(terminal)
        selectedTerminalID = terminal.id
    }

    public func selectTerminal(_ id: MobileTerminalPreview.ID?) {
        selectedTerminalID = id
    }

    public func reportTerminalViewport(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        viewportSize: MobileTerminalViewportSize
    ) {
        let key = viewportKey(workspaceID: workspaceID, terminalID: terminalID)
        reportedViewportSizesByTerminalKey[key] = viewportSize
    }

    public func openWorkspace(_ id: MobileWorkspacePreview.ID) async {
        setSelectedWorkspaceID(id)
    }

    public func sendTerminalInput() {
        Task { @MainActor [weak self] in
            await self?.submitTerminalInput()
        }
    }

    public func submitTerminalInput() async {
        let text = terminalInputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        terminalInputText = ""
        guard remoteClient != nil else { return }
        await sendRemoteTerminalInput(text + "\r")
    }

    public func sendTerminalRawInput(_ text: String) {
        #if DEBUG
        mobileShellLog.debug("enqueue raw terminal input byteCount=\(text.utf8.count, privacy: .public)")
        #endif
        guard let workspaceID = selectedWorkspace?.id,
              let terminalID = selectedTerminalID else {
            #if DEBUG
            mobileShellLog.info("skip raw terminal input enqueue selectedWorkspace=\(self.selectedWorkspace == nil ? 0 : 1, privacy: .public) selectedTerminal=\(self.selectedTerminalID == nil ? 0 : 1, privacy: .public)")
            #endif
            return
        }
        switch rawTerminalInputBuffer.enqueue(
            text,
            workspaceID: workspaceID,
            terminalID: terminalID
        ) {
        case .startDraining:
            Task { @MainActor [weak self] in
                await self?.drainRawTerminalInputBuffer()
            }
        case .queued:
            return
        case .rejected:
            mobileShellLog.error("disconnecting mobile terminal input because pending byte count exceeded limit")
            connectionError = L10n.string(
                "mobile.terminal.inputQueueFull",
                defaultValue: "The terminal can't accept more input right now. Wait a moment and retry, or reopen the terminal if it stays unavailable."
            )
            connectionState = .disconnected
            clearRemoteConnectionContext()
        }
    }

    public func submitTerminalRawInput(_ text: String) async {
        guard !text.isEmpty else { return }
        guard let workspaceID = selectedWorkspace?.id,
              let terminalID = selectedTerminalID else {
            return
        }
        await submitTerminalRawInput(text, workspaceID: workspaceID, terminalID: terminalID)
    }

    /// Raw-bytes overload. The libghostty render path on iOS uses this
    /// for input that may include binary sequences (mouse reports,
    /// kitty keyboard, IME byte streams). The wire RPC encodes bytes
    /// as the UTF-8-stringified payload of `mobile.terminal.input`,
    /// then the Mac decodes back to Data. If we ever need true binary
    /// fidelity (paste of mid-codepoint bytes, etc.), upgrade the
    /// `input` param to a base64 field.
    public func submitTerminalRawInput(_ data: Data, surfaceID: String) async {
        guard !data.isEmpty else { return }
        guard let text = String(data: data, encoding: .utf8) else {
            return
        }
        let workspaceCandidate = workspaces.first(where: { workspace in
            workspace.terminals.contains(where: { $0.id.rawValue == surfaceID })
        })
        guard let workspace = workspaceCandidate else { return }
        let terminalID = MobileTerminalPreview.ID(rawValue: surfaceID)
        await submitTerminalRawInput(text, workspaceID: workspace.id, terminalID: terminalID)
    }

    private func submitTerminalRawInput(
        _ text: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) async {
        guard !text.isEmpty else { return }
        guard remoteClient != nil else { return }
        await sendRemoteTerminalInput(text, workspaceID: workspaceID, terminalID: terminalID)
    }

    private func drainRawTerminalInputBuffer() async {
        while let chunk = rawTerminalInputBuffer.nextBatch() {
            await submitTerminalRawInput(
                chunk.text,
                workspaceID: chunk.workspaceID,
                terminalID: chunk.terminalID
            )
        }
    }

    private func connect(
        ticket: CmxAttachTicket,
        allowsStackAuthFallback: Bool? = nil
    ) async throws {
        let generation = UUID()
        connectionGeneration = generation
        cancelRemoteOperationTasks()
        rawTerminalInputBuffer.clear()
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        let supportedRoutes = Self.supportedRoutes(for: ticket, supportedKinds: supportedKinds)
        guard let firstRoute = supportedRoutes.first else {
            connectionError = L10n.string("mobile.pairing.unsupportedRoute", defaultValue: "This pairing code is not supported.")
            connectionState = .disconnected
            clearRemoteConnectionContext()
            return
        }
        guard Self.attachTicketIsUnexpired(ticket, now: runtime?.now() ?? Date()) else {
            connectionError = Self.localizedConnectionError(for: MobileShellConnectionError.attachTicketExpired, route: firstRoute)
            connectionState = .disconnected
            clearRemoteConnectionContext()
            throw MobileShellConnectionError.attachTicketExpired
        }

        activeTicket = ticket
        activeRoute = firstRoute
        connectedHostName = ticket.macDisplayName ?? ticket.macDeviceID
        replaceRemoteClient(with: nil)

        guard let runtime else {
            guard generation == connectionGeneration else { return }
            connectionError = nil
            applyPreviewTicket(ticket, route: firstRoute)
            connectionState = .connected
            return
        }

        let workspaceListRequests = try Self.initialWorkspaceListRequests(for: ticket)
        let routeAllowsStackAuthFallback = allowsStackAuthFallback
            ?? supportedRoutes.allSatisfy(MobileShellRouteAuthPolicy.routeAllowsImplicitPairLinkStackAuth)
        var lastError: Error?
        for route in supportedRoutes {
            activeRoute = route
            mobileShellLog.info("pairing trying route kind=\(route.kind.rawValue, privacy: .public) endpoint=\(route.endpoint.logDescription, privacy: .private)")
            let client = MobileCoreRPCClient(
                runtime: runtime,
                route: route,
                ticket: ticket,
                allowsStackAuthFallback: routeAllowsStackAuthFallback
            )
            for workspaceListRequest in workspaceListRequests {
                do {
                    let resultData = try await client.sendRequest(
                        workspaceListRequest.data,
                        timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
                    )
                    let response = try MobileSyncWorkspaceListResponse.decode(resultData)
                    guard generation == connectionGeneration, isSignedIn else { return }
                    replaceRemoteClient(with: client)
                    startTerminalRefreshPolling()
                    connectionError = nil
                    await persistPairedMacFromTicket(ticket)
                    applyRemoteWorkspaceList(response, preferActiveTicketTarget: workspaceListRequest.preferActiveTicketTarget)
                    syncSelectedTerminalForWorkspace()
                    connectionState = .connected
                    if workspaceListRequest.isScoped {
                        scheduleFullWorkspaceListRefreshIfAvailable(
                            client: client,
                            route: route,
                            generation: generation
                        )
                    }
                    return
                } catch {
                    lastError = error
                    guard generation == connectionGeneration, isSignedIn else { return }
                    mobileShellLog.error(
                        "pairing route failed kind=\(route.kind.rawValue, privacy: .public) endpoint=\(route.endpoint.logDescription, privacy: .private) scoped=\(workspaceListRequest.isScoped ? 1 : 0, privacy: .public): \(String(describing: error), privacy: .private)"
                    )
                }
            }
        }

        clearRemoteConnectionContext()
        throw lastError ?? MobileShellConnectionError.connectionClosed
    }

    private struct WorkspaceListRequest {
        var data: Data
        var isScoped: Bool
        var preferActiveTicketTarget: Bool
    }

    private static func supportedRoutes(
        for ticket: CmxAttachTicket,
        supportedKinds: [CmxAttachTransportKind]
    ) -> [CmxAttachRoute] {
        let orderedRoutes = ticket.routes.sorted(by: routeSortsBefore)
        guard !supportedKinds.isEmpty else {
            return orderedRoutes
        }
        let supportedKinds = Set(supportedKinds)
        return orderedRoutes.filter { route in
            supportedKinds.contains(route.kind)
        }
    }

    private static func attachTicketIsUnexpired(_ ticket: CmxAttachTicket, now: Date) -> Bool {
        ticket.expiresAt > now
    }

    private static func initialWorkspaceListParams(for ticket: CmxAttachTicket) -> [String: Any] {
        guard UUID(uuidString: ticket.workspaceID) != nil else {
            return [:]
        }
        var params: [String: Any] = ["workspace_id": ticket.workspaceID]
        if let terminalID = ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !terminalID.isEmpty {
            params["terminal_id"] = terminalID
        }
        return params
    }

    private static func initialWorkspaceListRequests(for ticket: CmxAttachTicket) throws -> [WorkspaceListRequest] {
        let scopedParams = initialWorkspaceListParams(for: ticket)
        let hasAttachToken = ticket.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        var requests: [WorkspaceListRequest] = []
        if hasAttachToken {
            requests.append(
                WorkspaceListRequest(
                    data: try MobileCoreRPCClient.requestData(method: "workspace.list", params: [:]),
                    isScoped: false,
                    preferActiveTicketTarget: true
                )
            )
        }

        if !scopedParams.isEmpty {
            requests.append(
                WorkspaceListRequest(
                    data: try MobileCoreRPCClient.requestData(method: "workspace.list", params: scopedParams),
                    isScoped: !scopedParams.isEmpty,
                    preferActiveTicketTarget: true
                )
            )
        }

        if requests.isEmpty {
            requests.append(
                WorkspaceListRequest(
                    data: try MobileCoreRPCClient.requestData(method: "workspace.list", params: [:]),
                    isScoped: false,
                    preferActiveTicketTarget: true
                )
            )
        }
        return requests
    }

    private func scheduleFullWorkspaceListRefreshIfAvailable(
        client: MobileCoreRPCClient,
        route: CmxAttachRoute,
        generation: UUID
    ) {
        guard workspaceListRefreshTask == nil else { return }
        workspaceListRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.workspaceListRefreshTask = nil }
            _ = await self.refreshAllWorkspacesWithAttachTokenIfAvailable(
                client: client,
                route: route,
                generation: generation,
                timeoutNanoseconds: self.runtime?.rpcRequestTimeoutNanoseconds
            )
        }
    }

    private func refreshAllWorkspacesWithAttachTokenIfAvailable(
        client: MobileCoreRPCClient,
        route: CmxAttachRoute,
        generation: UUID,
        timeoutNanoseconds: UInt64? = nil
    ) async -> Bool {
        guard MobileShellRouteAuthPolicy.routeAllowsStackAuth(route),
              let attachToken = activeTicket?.authToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !attachToken.isEmpty else {
            return false
        }
        do {
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "workspace.list",
                    params: [:]
                ),
                timeoutNanoseconds: timeoutNanoseconds ?? runtime?.pairingRequestTimeoutNanoseconds
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            guard isCurrentRemoteConnection(client: client, generation: generation) else {
                return false
            }
            let activeTicketWorkspaceID = activeTicket.map { MobileWorkspacePreview.ID(rawValue: $0.workspaceID) }
            applyRemoteWorkspaceList(
                response,
                preferActiveTicketTarget: selectedWorkspaceID == nil || selectedWorkspaceID == activeTicketWorkspaceID
            )
            return true
        } catch {
            mobileShellLog.info("full mobile workspace list unavailable after scoped attach: \(String(describing: error), privacy: .private)")
            if isCurrentRemoteConnection(client: client, generation: generation) {
                _ = disconnectForAuthorizationFailureIfNeeded(error)
            }
            return false
        }
    }

    private func clearActiveConnectionContext() {
        activeTicket = nil
        activeRoute = nil
        connectedHostName = ""
    }

    private func clearRemoteConnectionContext() {
        connectionGeneration = UUID()
        cancelRemoteOperationTasks()
        clearActiveConnectionContext()
        replaceRemoteClient(with: nil)
        rawTerminalInputBuffer.clear()
    }

    /// Set `remoteClient` to a new value (possibly nil) and disconnect the
    /// previous one so we don't leak a persistent transport.
    private func replaceRemoteClient(with newValue: MobileCoreRPCClient?) {
        let previous = remoteClient
        remoteClient = newValue
        if let previous, previous !== newValue {
            Task { await previous.disconnect() }
        }
    }

    private func cancelRemoteOperationTasks() {
        terminalSubscriptionRefreshTask?.cancel()
        terminalSubscriptionRefreshTask = nil
        createWorkspaceTask?.cancel()
        createWorkspaceTask = nil
        createWorkspaceTaskID = nil
        createTerminalTask?.cancel()
        createTerminalTask = nil
        createTerminalTaskID = nil
        workspaceListRefreshTask?.cancel()
        workspaceListRefreshTask = nil
    }

    private func resetTerminalOutputTracking() {
        deliveredTerminalByteEndSeqBySurfaceID = [:]
        pendingTerminalByteEndSeqBySurfaceID = [:]
        terminalReplaySurfaceIDsInFlight = []
        terminalOutputTransport = .rawBytes
        terminalSubscriptionRefreshTask?.cancel()
        terminalSubscriptionRefreshTask = nil
        stopRenderGridLivenessWatchdog(listenerID: nil)
        lastTerminalEventAt = nil
    }

    private func beginPairingAttempt() -> UUID {
        let attemptID = UUID()
        pairingAttemptID = attemptID
        connectionGeneration = UUID()
        cancelRemoteOperationTasks()
        rawTerminalInputBuffer.clear()
        connectionError = nil
        return attemptID
    }

    private func isCurrentPairingAttempt(_ attemptID: UUID) -> Bool {
        pairingAttemptID == attemptID && isSignedIn
    }

    private func clearCreateWorkspaceTask(id: UUID) {
        guard createWorkspaceTaskID == id else { return }
        createWorkspaceTask = nil
        createWorkspaceTaskID = nil
    }

    private func clearCreateTerminalTask(id: UUID) {
        guard createTerminalTaskID == id else { return }
        createTerminalTask = nil
        createTerminalTaskID = nil
    }

    private func isCurrentRemoteOperation(client: MobileCoreRPCClient, generation: UUID) -> Bool {
        isCurrentRemoteConnection(client: client, generation: generation)
            && connectionState == .connected
    }

    private func isCurrentRemoteConnection(client: MobileCoreRPCClient, generation: UUID) -> Bool {
        generation == connectionGeneration
            && client === remoteClient
            && isSignedIn
    }

    private func syncSelectedTerminalForWorkspace() {
        guard let selectedWorkspace else {
            selectedTerminalID = nil
            return
        }
        if let selectedTerminalID,
           let selectedTerminal = selectedWorkspace.terminals.first(where: { $0.id == selectedTerminalID }),
           selectedTerminal.isReady || !selectedWorkspace.hasReadyTerminal {
            return
        }
        selectedTerminalID = selectedWorkspace.preferredTerminal?.id
    }

    private func viewportKey(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) -> MobileTerminalViewportKey {
        MobileTerminalViewportKey(workspaceID: workspaceID, terminalID: terminalID)
    }

    private func createRemoteWorkspace() async {
        guard let client = remoteClient else { return }
        let generation = connectionGeneration
        do {
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "workspace.create")
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            guard isCurrentRemoteOperation(client: client, generation: generation),
                  !Task.isCancelled else { return }
            applyRemoteWorkspaceList(response, mergeExistingWorkspaces: true)
            if let createdID = response.createdWorkspaceID {
                let createdWorkspaceID = MobileWorkspacePreview.ID(rawValue: createdID)
                setSelectedWorkspaceID(createdWorkspaceID)
            }
            syncSelectedTerminalForWorkspace()
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
            connectionError = Self.localizedConnectionError(for: error)
        }
    }

    private func createRemoteTerminal() async {
        guard let client = remoteClient,
              let workspaceID = selectedWorkspace?.id.rawValue else { return }
        let requestedWorkspaceID = MobileWorkspacePreview.ID(rawValue: workspaceID)
        let generation = connectionGeneration
        do {
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "terminal.create",
                    params: ["workspace_id": workspaceID]
                )
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            guard isCurrentRemoteOperation(client: client, generation: generation),
                  !Task.isCancelled else { return }
            applyRemoteWorkspaceList(response, mergeExistingWorkspaces: true)
            if selectedWorkspaceID == requestedWorkspaceID,
               let createdID = response.createdTerminalID {
                selectedTerminalID = MobileTerminalPreview.ID(rawValue: createdID)
            }
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
            connectionError = Self.localizedConnectionError(for: error)
        }
    }

    private func sendRemoteTerminalInput(_ text: String) async {
        guard let workspaceID = selectedWorkspace?.id,
              let terminalID = selectedTerminalID else {
            #if DEBUG
            mobileShellLog.info("skip remote terminal input selectedWorkspace=\(self.selectedWorkspace == nil ? 0 : 1, privacy: .public) selectedTerminal=\(self.selectedTerminalID == nil ? 0 : 1, privacy: .public)")
            #endif
            return
        }
        await sendRemoteTerminalInput(text, workspaceID: workspaceID, terminalID: terminalID)
    }

    private func sendRemoteTerminalInput(
        _ text: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) async {
        guard let client = remoteClient else {
            #if DEBUG
            mobileShellLog.info("skip remote terminal input remoteClient=0")
            #endif
            return
        }
        let generation = connectionGeneration
        do {
            #if DEBUG
            mobileShellLog.debug("send remote terminal input byteCount=\(text.utf8.count, privacy: .public) workspace=\(workspaceID.rawValue, privacy: .private) terminal=\(terminalID.rawValue, privacy: .private)")
            #endif
            let key = viewportKey(workspaceID: workspaceID, terminalID: terminalID)
            var params: [String: Any] = [
                "workspace_id": workspaceID.rawValue,
                "surface_id": terminalID.rawValue,
                "text": text,
                "client_id": clientID,
            ]
            if let viewportSize = reportedViewportSizesByTerminalKey[key] {
                params["viewport_columns"] = viewportSize.columns
                params["viewport_rows"] = viewportSize.rows
            }
            let responseData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "terminal.input",
                    params: params
                )
            )
            guard isCurrentRemoteOperation(client: client, generation: generation) else { return }
            handleTerminalInputResponse(responseData, surfaceID: terminalID.rawValue)
        } catch {
            guard generation == connectionGeneration else { return }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
            connectionError = Self.localizedConnectionError(for: error)
        }
    }

    private var terminalEventStreamID: String {
        "ios-terminal-events-\(clientID)"
    }

    private func requestTerminalEventSubscription(
        client: MobileCoreRPCClient,
        reason: String,
        topics: [String]
    ) async -> Bool {
        let requestData: Data
        do {
            requestData = try MobileCoreRPCClient.requestData(
                method: "mobile.events.subscribe",
                params: [
                    "stream_id": terminalEventStreamID,
                    "topics": topics,
                ]
            )
        } catch {
            mobileShellLog.error("subscribe payload encode failed: \(String(describing: error), privacy: .private)")
            return false
        }
        let responseData: Data
        do {
            responseData = try await client.sendRequest(requestData)
        } catch {
            mobileShellLog.error("subscribe failed reason=\(reason, privacy: .public): \(String(describing: error), privacy: .private)")
            return false
        }
        let responseObject = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        guard let object = responseObject,
              let streamID = object["stream_id"] as? String,
              !streamID.isEmpty else {
            mobileShellLog.error("subscribe response missing stream_id reason=\(reason, privacy: .public)")
            return false
        }
        #if DEBUG
        mobileShellLog.info("subscribe active reason=\(reason, privacy: .public) streamID=\(streamID, privacy: .public)")
        #endif
        return true
    }

    private func resolveTerminalOutputTransport(client: MobileCoreRPCClient) async -> TerminalOutputTransport {
        let fallback: TerminalOutputTransport = .rawBytes
        do {
            let data = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "mobile.host.status", params: [:]),
                timeoutNanoseconds: Self.terminalOutputCapabilityTimeoutNanoseconds
            )
            guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                terminalOutputTransport = fallback
                return fallback
            }
            let capabilities = payload["capabilities"] as? [String] ?? []
            let fidelity = payload["terminal_fidelity"] as? String
            let transport: TerminalOutputTransport = capabilities.contains(Self.terminalRenderGridCapability) ||
                fidelity == "render_grid" ? .renderGrid : .rawBytes
            terminalOutputTransport = transport
            liveAnchormuxLog("sync.transport=\(transport == .renderGrid ? "render_grid" : "raw_bytes")")
            return transport
        } catch {
            terminalOutputTransport = fallback
            liveAnchormuxLog("sync.transport=raw_bytes reason=status_failed")
            return fallback
        }
    }

    private func refreshTerminalEventSubscription(reason: String) {
        guard let client = remoteClient, connectionState == .connected else { return }
        guard runtime?.supportsServerPushEvents ?? true else { return }
        guard terminalSubscriptionRefreshTask == nil else { return }
        terminalSubscriptionRefreshTask = Task { @MainActor [weak self] in
            defer { self?.terminalSubscriptionRefreshTask = nil }
            guard let self else { return }
            let topics = self.terminalOutputTransport.eventTopics
            _ = await self.requestTerminalEventSubscription(
                client: client,
                reason: reason,
                topics: topics
            )
        }
    }

    private func startTerminalRefreshPolling() {
        guard let client = remoteClient else { return }
        guard runtime?.supportsServerPushEvents ?? true else { return }
        guard terminalEventListenerTask == nil else { return }
        let listenerID = UUID()
        terminalEventListenerID = listenerID
        // Arm the liveness watchdog for this subscription generation. Done only
        // inside the push-events path (after the guard above) so scripted
        // transport tests, which set `supportsServerPushEvents = false`, never
        // schedule speculative re-subscribes. A fresh subscription gets a full
        // silence window before it can be judged dead.
        startRenderGridLivenessWatchdog(listenerID: listenerID)
        terminalEventListenerTask = Task { @MainActor [weak self] in
            defer {
                if self?.terminalEventListenerID == listenerID {
                    self?.terminalEventListenerTask = nil
                    self?.terminalEventListenerID = nil
                    // Only this generation's watchdog is torn down here. The
                    // `== listenerID` guard matters because `restartEventStream`
                    // does stop()+start() and the old listener's defer can run
                    // asynchronously after the new listener+watchdog are armed;
                    // without the guard a stale teardown would cancel the fresh
                    // watchdog.
                    self?.stopRenderGridLivenessWatchdog(listenerID: listenerID)
                }
            }

            let outputTransport = await self?.resolveTerminalOutputTransport(client: client) ?? .rawBytes
            let topics = outputTransport.eventTopics
            let stream = await client.subscribe(to: Set(topics))
            let subscribed = await self?.requestTerminalEventSubscription(
                client: client,
                reason: "start",
                topics: topics
            ) ?? false
            guard subscribed else {
                liveAnchormuxLog("sync.subscribe_failed reason=start")
                return
            }
            liveAnchormuxLog("sync.subscribe_ok topics=\(topics.count) transport=\(outputTransport)")
            // Keep the listener alive without keeping the shell store alive.
            for await event in stream {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.remoteClient === client, self.connectionState == .connected else { return }
                // Any yielded envelope proves the transport is still pushing, so
                // it resets the liveness window (not just render_grid events).
                self.lastTerminalEventAt = self.runtime?.now() ?? Date()
                if event.topic == "workspace.updated" {
                    self.scheduleWorkspaceListRefreshFromEvent()
                } else if event.topic == "terminal.render_grid" {
                    self.handleTerminalRenderGridEvent(event)
                } else if event.topic == "terminal.bytes" {
                    // Raw PTY bytes coming from the Mac surface's libghostty
                    // pty-tee. This is the compatibility fallback when the Mac
                    // host does not advertise `terminal.render_grid.v1`.
                    self.handleTerminalBytesEvent(event)
                }
            }
            guard let self else { return }
            self.handleTerminalEventStreamEnded(listenerID: listenerID, client: client)
        }
    }

    private func handleTerminalEventStreamEnded(listenerID: UUID, client: MobileCoreRPCClient) {
        guard !Task.isCancelled,
              terminalEventListenerID == listenerID,
              remoteClient === client,
              connectionState == .connected else {
            return
        }
        mobileShellLog.info("terminal event stream ended, restarting")
        liveAnchormuxLog("sync.stream_ended restarting (render-grid push stopped; falling back to poll)")
        terminalEventListenerTask = nil
        terminalEventListenerID = nil
        startTerminalRefreshPolling()
        scheduleWorkspaceListRefreshFromEvent()
    }

    // MARK: - Render-grid liveness watchdog

    /// Start a repeating `DispatchSourceTimer` that watches for prolonged silence
    /// on the render-grid push subscription identified by `listenerID`.
    ///
    /// The listener's `for await` loop blocks indefinitely when the underlying
    /// connection half-dies, so we cannot detect death from inside it. This timer
    /// ticks independently and, on each tick, hops to the main actor to compare
    /// `lastTerminalEventAt` against `renderGridLivenessSilenceThreshold`. While
    /// events keep arriving, `lastTerminalEventAt` stays fresh and every tick is a
    /// no-op, so an actively-streaming connection never triggers recovery; only a
    /// genuinely silent stream crosses the threshold.
    private func startRenderGridLivenessWatchdog(listenerID: UUID) {
        stopRenderGridLivenessWatchdog(listenerID: nil)
        renderGridLivenessListenerID = listenerID
        // Reset the window so a freshly-armed subscription gets the full silence
        // budget before it can be judged dead.
        lastTerminalEventAt = runtime?.now() ?? Date()
        // DispatchSourceTimer is the allowed low-level primitive for periodic
        // event delivery. It fires on the MAIN queue on purpose: the handler is
        // inferred @MainActor (it touches main-actor store state), and a timer on
        // a background queue made that @MainActor handler run off the main
        // executor, which Swift 6 traps as EXC_BREAKPOINT
        // (swift_task_isCurrentExecutor -> dispatch_assert_queue_fail). Running
        // on .main keeps isolation and executor in agreement; the work is just a
        // timestamp comparison every few seconds, so main-queue cost is trivial.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = Self.renderGridLivenessCheckInterval
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(500)
        )
        timer.setEventHandler { [weak self] in
            // Genuinely on the main queue (timer queue is .main), so assumeIsolated
            // is sound and avoids an async Task hop.
            MainActor.assumeIsolated {
                self?.checkRenderGridLiveness(listenerID: listenerID)
            }
        }
        renderGridLivenessTimer = timer
        timer.resume()
    }

    /// Cancel the liveness watchdog. When `listenerID` is non-nil the cancel only
    /// applies if it matches the armed generation, so a stale listener's async
    /// `defer` cannot tear down a watchdog that a newer subscription just armed.
    private func stopRenderGridLivenessWatchdog(listenerID: UUID?) {
        if let listenerID, renderGridLivenessListenerID != listenerID {
            return
        }
        renderGridLivenessTimer?.cancel()
        renderGridLivenessTimer = nil
        renderGridLivenessListenerID = nil
    }

    /// One watchdog tick on the main actor: if the subscription generation still
    /// matches, the store is connected, and the stream has been silent past the
    /// threshold, tear down + re-subscribe + replay via the existing resync path.
    private func checkRenderGridLiveness(listenerID: UUID) {
        guard renderGridLivenessListenerID == listenerID else { return }
        guard remoteClient != nil, connectionState == .connected else { return }
        guard terminalEventListenerID == listenerID else { return }
        let now = runtime?.now() ?? Date()
        let last = lastTerminalEventAt ?? now
        let silent = now.timeIntervalSince(last)
        guard silent >= Self.renderGridLivenessSilenceThreshold else { return }
        let silentMs = Int(silent * 1000)
        liveAnchormuxLog("sync.liveness re-subscribe silentMs=\(silentMs)")
        mobileShellLog.info("render-grid stream silent for \(silentMs, privacy: .public)ms, re-subscribing")
        // resyncTerminalOutput(restartEventStream: true) stops the wedged listener
        // (which cancels this watchdog via stopTerminalRefreshPolling) and starts a
        // fresh subscription + watchdog, then replays every surface so the phone
        // catches up on the deltas it missed while the stream was silent.
        resyncTerminalOutput(reason: "liveness", restartEventStream: true)
    }

    private func resyncTerminalOutput(
        reason: String,
        restartEventStream: Bool,
        surfaceIDs requestedSurfaceIDs: [String]? = nil
    ) {
        guard remoteClient != nil, connectionState == .connected else { return }
        if restartEventStream {
            stopTerminalRefreshPolling()
            startTerminalRefreshPolling()
        } else if terminalEventListenerTask == nil {
            startTerminalRefreshPolling()
        } else {
            refreshTerminalEventSubscription(reason: reason)
        }

        let surfaceIDs = requestedSurfaceIDs ?? Array(terminalByteSinksBySurfaceID.keys)
        liveAnchormuxLog(
            "sync.resync reason=\(reason) restart=\(restartEventStream) surfaces=\(surfaceIDs.count)"
        )
        for surfaceID in surfaceIDs {
            requestTerminalReplay(surfaceID: surfaceID)
        }
    }

    private func handleTerminalInputResponse(_ data: Data, surfaceID: String) {
        guard terminalByteSinksBySurfaceID[surfaceID] != nil,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let remoteSeq = (payload["terminal_seq"] as? NSNumber)?.uint64Value else {
            return
        }
        let localSeq = deliveredTerminalByteEndSeqBySurfaceID[surfaceID] ?? 0
        guard remoteSeq > localSeq else { return }
        if terminalOutputTransport == .renderGrid,
           terminalEventListenerTask != nil {
            let pendingSeq = pendingTerminalByteEndSeqBySurfaceID[surfaceID]
            pendingTerminalByteEndSeqBySurfaceID[surfaceID] = max(remoteSeq, pendingSeq ?? 0)
            if let pendingSeq, localSeq < pendingSeq {
                liveAnchormuxLog("sync.input_seq_still_behind surface=\(surfaceID) local=\(localSeq) pending=\(pendingSeq) remote=\(remoteSeq)")
                mobileShellLog.info("terminal render-grid still behind after input surface=\(surfaceID, privacy: .public) localSeq=\(localSeq, privacy: .public) pendingSeq=\(pendingSeq, privacy: .public) remoteSeq=\(remoteSeq, privacy: .public)")
                resyncTerminalOutput(
                    reason: "input_seq_still_behind",
                    restartEventStream: true,
                    surfaceIDs: [surfaceID]
                )
            } else {
                liveAnchormuxLog("sync.input_seq_wait surface=\(surfaceID) local=\(localSeq) remote=\(remoteSeq)")
                refreshTerminalEventSubscription(reason: "input_seq_wait")
            }
            return
        }
        liveAnchormuxLog("sync.input_seq_behind surface=\(surfaceID) local=\(localSeq) remote=\(remoteSeq)")
        mobileShellLog.info("terminal output behind after input surface=\(surfaceID, privacy: .public) localSeq=\(localSeq, privacy: .public) remoteSeq=\(remoteSeq, privacy: .public)")
        resyncTerminalOutput(
            reason: "input_seq_behind",
            restartEventStream: false,
            surfaceIDs: [surfaceID]
        )
    }

    private func markTerminalBytesDelivered(surfaceID: String, endSeq: UInt64) {
        let current = deliveredTerminalByteEndSeqBySurfaceID[surfaceID] ?? 0
        deliveredTerminalByteEndSeqBySurfaceID[surfaceID] = max(current, endSeq)
        if let pendingSeq = pendingTerminalByteEndSeqBySurfaceID[surfaceID],
           endSeq >= pendingSeq {
            pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
            liveAnchormuxLog("sync.input_seq_caught_up surface=\(surfaceID) seq=\(endSeq)")
        }
    }

    private static func terminalSnapshotReplacementBytes(_ snapshotBytes: Data) -> Data {
        var bytes = Data("\u{1B}c\u{1B}[H\u{1B}[2J\u{1B}[3J".utf8)
        bytes.append(snapshotBytes)
        return bytes
    }

    /// Per-surface byte sinks for the libghostty render path. A mounted
    /// `GhosttySurfaceView` registers itself here and receives VT patch bytes
    /// derived from render-grid frames. Raw PTY bytes still use the same sink as
    /// a compatibility fallback for older Mac hosts.
    private var terminalByteSinksBySurfaceID: [String: (Data) -> Void] = [:]

    public func registerTerminalByteSink(
        surfaceID: String,
        sink: @escaping (Data) -> Void
    ) {
        terminalByteSinksBySurfaceID[surfaceID] = sink
        deliveredTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        #if DEBUG
        mobileShellLog.info("CMUX_REPLAY register sink surface=\(surfaceID, privacy: .public) connected=\(self.connectionState == .connected, privacy: .public) hasClient=\(self.remoteClient != nil, privacy: .public) workspaceCount=\(self.workspaces.count, privacy: .public)")
        #endif
        requestTerminalReplay(surfaceID: surfaceID)
    }

    public func unregisterTerminalByteSink(surfaceID: String) {
        terminalByteSinksBySurfaceID.removeValue(forKey: surfaceID)
        deliveredTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        // Tell the Mac this device is no longer viewing the surface so it stops
        // pinning the shared grid to our viewport and clears the macOS border.
        clearTerminalViewport(surfaceID: surfaceID)
    }

    /// Report this device's natural terminal grid to the Mac and return the
    /// effective grid the Mac computed (the smallest across all attached
    /// devices, capped to the Mac pane). The caller pins its libghostty surface
    /// to that grid so every device renders the same cols×rows with a viewport
    /// border around the live area (tmux-style shared resize).
    public func updateTerminalViewport(
        surfaceID: String,
        columns: Int,
        rows: Int
    ) async -> (columns: Int, rows: Int)? {
        guard columns > 0, rows > 0,
              let client = remoteClient,
              let workspaceID = workspaceID(forTerminalID: surfaceID) else {
            return nil
        }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.viewport",
                params: [
                    "workspace_id": workspaceID.rawValue,
                    "surface_id": surfaceID,
                    "client_id": clientID,
                    "viewport_columns": columns,
                    "viewport_rows": rows,
                ]
            )
            let data = try await client.sendRequest(request)
            guard remoteClient === client else { return nil }
            guard
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let cols = (payload["columns"] as? NSNumber)?.intValue,
                let effectiveRows = (payload["rows"] as? NSNumber)?.intValue,
                cols > 0, effectiveRows > 0
            else {
                return nil
            }
            return (cols, effectiveRows)
        } catch {
            mobileShellLog.error("viewport report failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Tell the Mac to drop this device's viewport pin for a surface (on
    /// detach). Fire-and-forget; the Mac also clears on connection close.
    public func clearTerminalViewport(surfaceID: String) {
        guard let client = remoteClient,
              let workspaceID = workspaceID(forTerminalID: surfaceID) else {
            return
        }
        let id = clientID
        Task { @MainActor in
            let request = try? MobileCoreRPCClient.requestData(
                method: "mobile.terminal.viewport",
                params: [
                    "workspace_id": workspaceID.rawValue,
                    "surface_id": surfaceID,
                    "client_id": id,
                    "clear": true,
                ]
            )
            guard let request else { return }
            _ = try? await client.sendRequest(request)
        }
    }

    /// Cold-attach/self-heal replay. Prefer the Mac's bounded render-grid
    /// snapshot, replacing the local iOS terminal state before live bytes
    /// resume. The VT snapshot and raw byte ring remain fallbacks, but neither
    /// is the target architecture: a byte tail is not a complete screen state
    /// for TUIs, and a VT export is still a replay stream rather than state.
    private func requestTerminalReplay(surfaceID: String) {
        guard let client = remoteClient else {
            #if DEBUG
            mobileShellLog.error("CMUX_REPLAY skip surface=\(surfaceID, privacy: .public) reason=no_remote_client")
            #endif
            return
        }
        guard let workspaceID = workspaceID(forTerminalID: surfaceID) else {
            #if DEBUG
            mobileShellLog.error("CMUX_REPLAY skip surface=\(surfaceID, privacy: .public) reason=workspace_not_found")
            #endif
            return
        }
        guard !terminalReplaySurfaceIDsInFlight.contains(surfaceID) else {
            #if DEBUG
            mobileShellLog.info("CMUX_REPLAY skip surface=\(surfaceID, privacy: .public) reason=in_flight")
            #endif
            return
        }
        terminalReplaySurfaceIDsInFlight.insert(surfaceID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.terminalReplaySurfaceIDsInFlight.remove(surfaceID) }
            do {
                let request = try MobileCoreRPCClient.requestData(
                    method: "mobile.terminal.replay",
                    params: [
                        "workspace_id": workspaceID.rawValue,
                        "surface_id": surfaceID,
                    ]
                )
                let data = try await client.sendRequest(request)
                guard self.remoteClient === client else { return }
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let b64 = payload?["data_b64"] as? String
                let bytes = b64.flatMap { Data(base64Encoded: $0) }
                let snapshotB64 = payload?["snapshot_data_b64"] as? String
                let snapshotBytes = snapshotB64.flatMap { Data(base64Encoded: $0) }
                let decodedRenderGrid = payload?["render_grid"].flatMap {
                    try? MobileTerminalRenderGridFrame.decodeJSONObject($0)
                }
                let renderGrid = decodedRenderGrid?.surfaceID == surfaceID ? decodedRenderGrid : nil
                let replaySeq = renderGrid?.stateSeq ?? (payload?["seq"] as? NSNumber)?.uint64Value
                #if DEBUG
                let seq = replaySeq ?? 0
                let cols = (payload?["columns"] as? NSNumber)?.intValue ?? -1
                let rows = (payload?["rows"] as? NSNumber)?.intValue ?? -1
                mobileShellLog.info("CMUX_REPLAY response surface=\(surfaceID, privacy: .public) byteCount=\(bytes?.count ?? -1, privacy: .public) snapshotBytes=\(snapshotBytes?.count ?? -1, privacy: .public) renderGrid=\(renderGrid != nil, privacy: .public) seq=\(seq, privacy: .public) macGrid=\(cols, privacy: .public)x\(rows, privacy: .public) hasSink=\(self.terminalByteSinksBySurfaceID[surfaceID] != nil, privacy: .public)")
                #endif
                if let replaySeq,
                   let deliveredSeq = self.deliveredTerminalByteEndSeqBySurfaceID[surfaceID],
                   deliveredSeq > replaySeq {
                    liveAnchormuxLog("CMUX_REPLAY stale surface=\(surfaceID) delivered=\(deliveredSeq) replay=\(replaySeq)")
                    return
                }
                let deliverBytes: Data?
                if let renderGrid {
                    deliverBytes = renderGrid.vtPatchBytes()
                    liveAnchormuxLog("CMUX_REPLAY render_grid surface=\(surfaceID) spans=\(renderGrid.rowSpans.count) seq=\(renderGrid.stateSeq)")
                } else if let snapshotBytes, !snapshotBytes.isEmpty {
                    deliverBytes = Self.terminalSnapshotReplacementBytes(snapshotBytes)
                    liveAnchormuxLog("CMUX_REPLAY snapshot surface=\(surfaceID) bytes=\(snapshotBytes.count) seq=\(replaySeq ?? 0)")
                } else {
                    deliverBytes = bytes
                    liveAnchormuxLog("CMUX_REPLAY raw_tail surface=\(surfaceID) bytes=\(bytes?.count ?? -1) seq=\(replaySeq ?? 0)")
                }
                if let replaySeq {
                    self.markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: replaySeq)
                }
                guard let deliverBytes, !deliverBytes.isEmpty else {
                    return
                }
                self.terminalByteSinksBySurfaceID[surfaceID]?(deliverBytes)
            } catch {
                mobileShellLog.error("CMUX_REPLAY failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    private func workspaceID(forTerminalID terminalID: String) -> MobileWorkspacePreview.ID? {
        for workspace in workspaces {
            if workspace.terminals.contains(where: { $0.id.rawValue == terminalID }) {
                return workspace.id
            }
        }
        return nil
    }

    private func handleTerminalRenderGridEvent(_ event: MobileEventEnvelope) {
        guard
            let json = event.payloadJSON,
            let payload = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else {
            return
        }
        let frameObject: Any = payload["render_grid"] ?? payload
        guard let renderGrid = try? MobileTerminalRenderGridFrame.decodeJSONObject(frameObject),
              terminalByteSinksBySurfaceID[renderGrid.surfaceID] != nil else {
            return
        }
        if let deliveredSeq = deliveredTerminalByteEndSeqBySurfaceID[renderGrid.surfaceID],
           deliveredSeq > renderGrid.stateSeq {
            liveAnchormuxLog(
                "sync.render_grid_stale surface=\(renderGrid.surfaceID) delivered=\(deliveredSeq) frame=\(renderGrid.stateSeq)"
            )
            return
        }
        let bytes = renderGrid.vtPatchBytes()
        markTerminalBytesDelivered(surfaceID: renderGrid.surfaceID, endSeq: renderGrid.stateSeq)
        #if DEBUG
        mobileShellLog.info("CMUX_REPLAY live render_grid surface=\(renderGrid.surfaceID, privacy: .public) full=\(renderGrid.full, privacy: .public) spans=\(renderGrid.rowSpans.count, privacy: .public) cleared=\(renderGrid.clearedRows.count, privacy: .public) seq=\(renderGrid.stateSeq, privacy: .public) hasSink=true")
        #endif
        guard !bytes.isEmpty else { return }
        terminalByteSinksBySurfaceID[renderGrid.surfaceID]?(bytes)
    }

    private func handleTerminalBytesEvent(_ event: MobileEventEnvelope) {
        guard
            let json = event.payloadJSON,
            let payload = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let surfaceID = payload["surface_id"] as? String,
            let b64 = payload["data_b64"] as? String,
            let bytes = Data(base64Encoded: b64)
        else {
            return
        }
        #if DEBUG
        let seq = (payload["seq"] as? NSNumber)?.uint64Value ?? 0
        mobileShellLog.info("CMUX_REPLAY live bytes surface=\(surfaceID, privacy: .public) byteCount=\(bytes.count, privacy: .public) seq=\(seq, privacy: .public) hasSink=\(self.terminalByteSinksBySurfaceID[surfaceID] != nil, privacy: .public)")
        #endif
        guard let seq = (payload["seq"] as? NSNumber)?.uint64Value else {
            terminalByteSinksBySurfaceID[surfaceID]?(bytes)
            return
        }
        let endSeq = seq &+ UInt64(bytes.count)
        if let deliveredSeq = deliveredTerminalByteEndSeqBySurfaceID[surfaceID] {
            if seq > deliveredSeq {
                liveAnchormuxLog("sync.byte_gap surface=\(surfaceID) delivered=\(deliveredSeq) next=\(seq)")
                mobileShellLog.info("terminal byte gap surface=\(surfaceID, privacy: .public) deliveredSeq=\(deliveredSeq, privacy: .public) nextSeq=\(seq, privacy: .public)")
                resyncTerminalOutput(
                    reason: "seq_gap",
                    restartEventStream: false,
                    surfaceIDs: [surfaceID]
                )
                return
            }
            if endSeq <= deliveredSeq {
                return
            }
            let overlap = deliveredSeq - seq
            let deliverBytes = Data(bytes.dropFirst(Int(overlap)))
            terminalByteSinksBySurfaceID[surfaceID]?(deliverBytes)
            markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: endSeq)
            return
        }
        terminalByteSinksBySurfaceID[surfaceID]?(bytes)
        markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: endSeq)
    }

    private func scheduleWorkspaceListRefreshFromEvent() {
        guard let client = remoteClient else { return }
        workspaceListRefreshTask?.cancel()
        workspaceListRefreshTask = Task { @MainActor [weak self] in
            defer { self?.workspaceListRefreshTask = nil }
            guard let self else { return }
            do {
                let request = try MobileCoreRPCClient.requestData(method: "mobile.workspace.list", params: [:])
                let data = try await client.sendRequest(request)
                let response = try MobileSyncWorkspaceListResponse.decode(data)
                guard self.remoteClient === client, self.connectionState == .connected else { return }
                self.applyRemoteWorkspaceList(response, preferActiveTicketTarget: false)
                self.syncSelectedTerminalForWorkspace()
            } catch {
                mobileShellLog.error("workspace list event refresh failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    private func stopTerminalRefreshPolling() {
        terminalEventListenerTask?.cancel()
        terminalEventListenerTask = nil
        terminalEventListenerID = nil
        stopRenderGridLivenessWatchdog(listenerID: nil)
    }

    private func setSelectedWorkspaceID(_ id: MobileWorkspacePreview.ID?) {
        selectedWorkspaceID = id
    }

    private func applyRemoteWorkspaceList(
        _ response: MobileSyncWorkspaceListResponse,
        preferActiveTicketTarget: Bool = false,
        mergeExistingWorkspaces: Bool = false
    ) {
        let remoteWorkspaces = remoteWorkspacesPreservingSnapshots(from: response)
        if mergeExistingWorkspaces {
            var mergedWorkspaces = workspaces
            for remoteWorkspace in remoteWorkspaces {
                if let existingIndex = mergedWorkspaces.firstIndex(where: { $0.id == remoteWorkspace.id }) {
                    mergedWorkspaces[existingIndex] = remoteWorkspace
                } else {
                    mergedWorkspaces.append(remoteWorkspace)
                }
            }
            workspaces = mergedWorkspaces
        } else {
            workspaces = remoteWorkspaces
        }
        if preferActiveTicketTarget, selectActiveTicketTargetIfAvailable() {
            return
        }
        if let selectedWorkspaceID,
           workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            syncSelectedTerminalForWorkspace()
            return
        }
        setSelectedWorkspaceID(
            response.workspaces.first(where: \.isSelected)
                .map { MobileWorkspacePreview.ID(rawValue: $0.id) }
                ?? workspaces.first?.id
        )
        syncSelectedTerminalForWorkspace()
    }

    private func remoteWorkspacesPreservingSnapshots(
        from response: MobileSyncWorkspaceListResponse
    ) -> [MobileWorkspacePreview] {
        response.workspaces.map { remoteWorkspace in
            var workspace = MobileWorkspacePreview(remote: remoteWorkspace)
            guard let existingWorkspace = workspaces.first(where: { $0.id == workspace.id }) else {
                return workspace
            }
            workspace.terminals = workspace.terminals.map { remoteTerminal in
                guard let existingTerminal = existingWorkspace.terminals.first(where: { $0.id == remoteTerminal.id }) else {
                    return remoteTerminal
                }
                var terminal = remoteTerminal
                terminal.viewportFit = existingTerminal.viewportFit
                return terminal
            }
            return workspace
        }
    }

    private func selectActiveTicketTargetIfAvailable() -> Bool {
        guard let activeTicket else {
            return false
        }
        let ticketWorkspaceID = MobileWorkspacePreview.ID(rawValue: activeTicket.workspaceID)
        guard let workspace = workspaces.first(where: { $0.id == ticketWorkspaceID }) else {
            return false
        }
        setSelectedWorkspaceID(ticketWorkspaceID)
        if let ticketTerminalID = activeTicket.terminalID.map(MobileTerminalPreview.ID.init(rawValue:)),
           workspace.terminals.contains(where: { $0.id == ticketTerminalID }) {
            selectedTerminalID = ticketTerminalID
        } else {
            syncSelectedTerminalForWorkspace()
        }
        return true
    }

    private func disconnectForAuthorizationFailureIfNeeded(_ error: Error) -> Bool {
        guard Self.shouldDisconnectForAuthorizationFailure(error) else {
            return false
        }
        connectionError = Self.localizedConnectionError(for: error, route: activeRoute)
        connectionState = .disconnected
        clearRemoteConnectionContext()
        return true
    }

    private static func shouldDisconnectForAuthorizationFailure(_ error: Error) -> Bool {
        guard let connectionError = error as? MobileShellConnectionError else {
            return false
        }
        switch connectionError {
        case .attachTicketExpired, .authorizationFailed, .insecureManualRoute:
            return true
        case let .rpcError(code, message):
            let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let normalizedCode,
               ["unauthorized", "forbidden", "invalid_token", "token_expired", "expired_token", "auth_required"].contains(normalizedCode) {
                return true
            }
            let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalizedMessage.contains("unauthorized")
                || normalizedMessage.contains("forbidden")
                || normalizedMessage.contains("invalid token")
                || normalizedMessage.contains("expired token")
                || normalizedMessage.contains("token expired")
        case .invalidResponse, .connectionClosed, .requestTimedOut:
            return false
        }
    }

    private static func localizedConnectionError(for error: Error, route: CmxAttachRoute? = nil) -> String {
        let hostPort = route.flatMap(Self.hostPortDescription(for:))
        if let networkError = error as? CmxNetworkByteTransportError {
            switch networkError {
            case .connectionTimedOut:
                return localizedHostPortConnectionError(
                    key: "mobile.pairing.connectionTimedOutFormat",
                    defaultValue: "No response from %@:%d. Make sure the host app is open and accepting mobile connections.",
                    fallbackKey: "mobile.pairing.requestTimedOut",
                    fallbackDefaultValue: "The computer did not respond. Check the host and port, then try again.",
                    hostPort: hostPort
                )
            case .connectionFailed, .notConnected, .alreadyClosed:
                return localizedHostPortConnectionError(
                    key: "mobile.pairing.connectionFailedFormat",
                    defaultValue: "Could not reach %@:%d. Check that the host is reachable over Tailscale or LAN and that the port is correct.",
                    fallbackKey: "mobile.pairing.runtimeUnavailable",
                    fallbackDefaultValue: "Could not connect to your computer.",
                    hostPort: hostPort
                )
            case .receiveFailed, .sendFailed:
                return localizedHostPortConnectionError(
                    key: "mobile.pairing.connectionDroppedFormat",
                    defaultValue: "Connected to %@:%d, but the host closed the connection. Check that the host app is still running.",
                    fallbackKey: "mobile.pairing.runtimeUnavailable",
                    fallbackDefaultValue: "Could not connect to your computer.",
                    hostPort: hostPort
                )
            case .emptyHost, .invalidPort, .invalidMaximumReceiveLength, .unsupportedRouteKind, .unsupportedEndpoint, .receiveAlreadyInProgress, .sendAlreadyInProgress:
                break
            }
        }
        guard let connectionError = error as? MobileShellConnectionError else {
            return L10n.string("mobile.pairing.runtimeUnavailable", defaultValue: "Could not connect to your computer.")
        }
        switch connectionError {
        case .requestTimedOut:
            return localizedHostPortConnectionError(
                key: "mobile.pairing.connectionTimedOutFormat",
                defaultValue: "No response from %@:%d. Make sure the host app is open and accepting mobile connections.",
                fallbackKey: "mobile.pairing.requestTimedOut",
                fallbackDefaultValue: "The computer did not respond. Check the host and port, then try again.",
                hostPort: hostPort
            )
        case .insecureManualRoute:
            return L10n.string("mobile.pairing.secureRouteRequired", defaultValue: "This pairing route is not allowed. Enter a host and port, or pair with a QR/link from that computer.")
        case .attachTicketExpired:
            return L10n.string("mobile.pairing.attachTicketExpired", defaultValue: "This pairing link expired. Pair again with a fresh QR/link from that computer.")
        case .authorizationFailed:
            return L10n.string("mobile.pairing.authorizationFailed", defaultValue: "Sign in on your computer with the same account, or pair with a QR/link from that computer.")
        case .invalidResponse, .connectionClosed, .rpcError:
            return L10n.string("mobile.pairing.runtimeUnavailable", defaultValue: "Could not connect to your computer.")
        }
    }

    private static func localizedHostPortConnectionError(
        key: StaticString,
        defaultValue: String.LocalizationValue,
        fallbackKey: StaticString,
        fallbackDefaultValue: String.LocalizationValue,
        hostPort: (host: String, port: Int)?
    ) -> String {
        guard let hostPort else {
            return L10n.string(fallbackKey, defaultValue: fallbackDefaultValue)
        }
        return String(
            format: L10n.string(key, defaultValue: defaultValue),
            hostPort.host,
            hostPort.port
        )
    }

    private static func hostPortDescription(for route: CmxAttachRoute) -> (host: String, port: Int)? {
        guard case let .hostPort(host, port) = route.endpoint else {
            return nil
        }
        return (host, port)
    }

    private static func routeSortsBefore(_ left: CmxAttachRoute, _ right: CmxAttachRoute) -> Bool {
        if left.priority == right.priority {
            return left.id < right.id
        }
        return left.priority < right.priority
    }

    private func applyPreviewTicket(_ ticket: CmxAttachTicket, route: CmxAttachRoute) {
        let terminalID = ticket.terminalID ?? "attached-terminal"
        workspaces = [
            MobileWorkspacePreview(
                id: .init(rawValue: ticket.workspaceID),
                name: L10n.string("mobile.preview.attachedWorkspaceName", defaultValue: "Attached Workspace"),
                terminals: [
                    MobileTerminalPreview(
                        id: .init(rawValue: terminalID),
                        name: L10n.string("mobile.preview.attachedTerminalName", defaultValue: "Attached Terminal")
                    ),
                ]
            ),
        ]
        selectedWorkspaceID = workspaces.first?.id
        selectedTerminalID = workspaces.first?.terminals.first?.id
    }
}

private struct MobileTerminalViewportKey: Hashable, Sendable {
    var workspaceID: MobileWorkspacePreview.ID
    var terminalID: MobileTerminalPreview.ID
}

private struct MobileManualAttachTicketCreateResponse: Decodable, Sendable {
    var ticket: CmxAttachTicket

    static func decode(_ data: Data) throws -> MobileManualAttachTicketCreateResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MobileManualAttachTicketCreateResponse.self, from: data)
    }
}

private extension CmxAttachTicket {
    func constrainingRoutes(
        to routes: [CmxAttachRoute],
        fallbackDisplayName: String
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: workspaceID,
            terminalID: terminalID,
            macDeviceID: macDeviceID,
            macDisplayName: macDisplayName ?? fallbackDisplayName,
            routes: routes,
            expiresAt: expiresAt,
            authToken: authToken
        )
    }

}

private extension MobileWorkspacePreview {
    var preferredTerminal: MobileTerminalPreview? {
        terminals.first { $0.isReady && $0.isFocused }
            ?? terminals.first { $0.isReady }
            ?? terminals.first { $0.isFocused }
            ?? terminals.first
    }

    var hasReadyTerminal: Bool {
        terminals.contains(where: \.isReady)
    }
}

