import CMUXMobileCore
import Foundation
import Observation
import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

public struct MobileWorkspacePreview: Identifiable, Equatable, Sendable {
    public struct ID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.rawValue = value
        }
    }

    public var id: ID
    public var name: String
    public var terminals: [MobileTerminalPreview]

    public init(id: ID, name: String, terminals: [MobileTerminalPreview]) {
        self.id = id
        self.name = name
        self.terminals = terminals
    }
}

public struct MobileTerminalPreview: Identifiable, Equatable, Sendable {
    public struct ID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.rawValue = value
        }
    }

    public var id: ID
    public var name: String
    public var snapshot: MobileTerminalGhosttySnapshot
    public var isReady: Bool
    public var isFocused: Bool
    public var viewportFit: MobileTerminalViewportFit?

    public init(
        id: ID,
        name: String,
        snapshot: MobileTerminalGhosttySnapshot,
        isReady: Bool = true,
        isFocused: Bool = false,
        viewportFit: MobileTerminalViewportFit? = nil
    ) {
        self.id = id
        self.name = name
        self.snapshot = snapshot
        self.isReady = isReady
        self.isFocused = isFocused
        self.viewportFit = viewportFit
    }

    public init(
        id: ID,
        name: String,
        lines: [String],
        isReady: Bool = true,
        isFocused: Bool = false,
        viewportFit: MobileTerminalViewportFit? = nil
    ) {
        self.id = id
        self.name = name
        self.snapshot = PreviewMobileHost.snapshot(
            terminalID: id.rawValue,
            lines: lines
        )
        self.isReady = isReady
        self.isFocused = isFocused
        self.viewportFit = viewportFit
    }

    public var lines: [String] {
        snapshot.scrollbackRows.map(\.trimmedPlainText) + snapshot.renderedVisibleLines
    }
}

public struct MobileTerminalViewportSize: Codable, Equatable, Sendable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }
}

public struct MobileTerminalViewportFit: Codable, Equatable, Sendable {
    public var effective: MobileTerminalViewportSize
    public var client: MobileTerminalViewportSize?
    public var isCurrentClientLimiting: Bool

    public init(
        effective: MobileTerminalViewportSize,
        client: MobileTerminalViewportSize?,
        isCurrentClientLimiting: Bool
    ) {
        self.effective = effective
        self.client = client
        self.isCurrentClientLimiting = isCurrentClientLimiting
    }

    public var shouldDrawVisibleAreaBorder: Bool {
        shouldDrawVisibleAreaRightBorder || shouldDrawVisibleAreaBottomBorder
    }

    public var shouldDrawVisibleAreaRightBorder: Bool {
        guard let client else { return false }
        return client.columns > effective.columns
    }

    public var shouldDrawVisibleAreaBottomBorder: Bool {
        guard let client else { return false }
        return client.rows > effective.rows
    }

    private enum CodingKeys: String, CodingKey {
        case effective
        case client
        case isCurrentClientLimiting = "is_current_client_limiting"
    }
}

enum MobileTerminalSnapshotRequestPolicy {
    private static let maximumScrollbackRows = 120
    private static let frameSafetyBudget = MobileSyncFrameCodec.defaultMaximumFrameByteCount / 2
    private static let estimatedCellByteCount = 128

    static func maxScrollbackRows(viewportSize: MobileTerminalViewportSize?) -> Int {
        let columns = max(viewportSize?.columns ?? 80, 1)
        let visibleRows = max(viewportSize?.rows ?? 24, 1)
        let bytesPerRow = max(columns * estimatedCellByteCount, 1)
        let totalRowsByBudget = max(visibleRows, frameSafetyBudget / bytesPerRow)
        let scrollbackRowsByBudget = max(0, totalRowsByBudget - visibleRows)
        return min(maximumScrollbackRows, scrollbackRowsByBudget)
    }
}

struct MobileTerminalInputSendBuffer: Equatable, Sendable {
    private(set) var pendingText = ""
    private(set) var isDraining = false

    mutating func enqueue(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        pendingText += text
        guard !isDraining else { return false }
        isDraining = true
        return true
    }

    mutating func nextBatch() -> String? {
        guard !pendingText.isEmpty else {
            isDraining = false
            return nil
        }
        let text = pendingText
        pendingText = ""
        return text
    }
}

public enum MobileConnectionState: Equatable, Sendable {
    case disconnected
    case connected
}

public enum MobileShellPhase: Equatable, Sendable {
    case signIn
    case pairing
    case workspaces
}

public struct CMUXMobileRuntime: Sendable {
    public var supportedRouteKinds: [CmxAttachTransportKind]
    public var transportFactory: any CmxByteTransportFactory
    public var stackAccessTokenProvider: @Sendable () async throws -> String
    public var rpcRequestTimeoutNanoseconds: UInt64
    public var now: @Sendable () -> Date

    private static var defaultStackAccessTokenProvider: @Sendable () async throws -> String {
        {
            try await AuthManager.shared.getAccessToken()
        }
    }

    public init(
        supportedRouteKinds: [CmxAttachTransportKind] = [.tailscale, .debugLoopback, .websocket],
        transportFactory: any CmxByteTransportFactory,
        stackAccessTokenProvider: (@Sendable () async throws -> String)? = nil,
        rpcRequestTimeoutNanoseconds: UInt64 = 10 * 1_000_000_000,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.supportedRouteKinds = supportedRouteKinds
        self.transportFactory = transportFactory
        self.stackAccessTokenProvider = stackAccessTokenProvider ?? Self.defaultStackAccessTokenProvider
        self.rpcRequestTimeoutNanoseconds = rpcRequestTimeoutNanoseconds
        self.now = now
    }

    public init(
        transportFactory: any CmxRouteAwareByteTransportFactory,
        stackAccessTokenProvider: (@Sendable () async throws -> String)? = nil,
        rpcRequestTimeoutNanoseconds: UInt64 = 10 * 1_000_000_000,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.supportedRouteKinds = transportFactory.supportedKinds
        self.transportFactory = transportFactory
        self.stackAccessTokenProvider = stackAccessTokenProvider ?? Self.defaultStackAccessTokenProvider
        self.rpcRequestTimeoutNanoseconds = rpcRequestTimeoutNanoseconds
        self.now = now
    }
}

enum MobileShellRouteAuthPolicy {
    static func manualRouteKind(for host: String) -> CmxAttachTransportKind {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isLoopbackHost(normalizedHost) {
            return .debugLoopback
        }
        return .tailscale
    }

    static func routeAllowsStackAuth(_ route: CmxAttachRoute) -> Bool {
        switch (route.kind, route.endpoint) {
        case (.debugLoopback, let .hostPort(host, _)):
            return isLoopbackHost(host)
        case (.tailscale, let .hostPort(host, _)):
            return isTailscaleDNSHost(host)
        case (.iroh, .peer):
            return true
        default:
            return false
        }
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedHost == "localhost" ||
            normalizedHost == "::1" ||
            isIPv4LoopbackHost(normalizedHost)
    }

    private static func isIPv4LoopbackHost(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return false
        }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty,
                  part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(part),
                  (0...255).contains(value) else {
                return nil
            }
            return value
        }
        return octets.count == 4 && octets[0] == 127
    }

    private static func isTailscaleDNSHost(_ host: String) -> Bool {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasSuffix(".ts.net")
    }
}

@MainActor
@Observable
public final class CMUXMobileShellStore {
    private static let viewportSettlingRefreshCount = 8
    private static let workspaceOpenSettlingRefreshCount = 2
    private static let inputSettlingRefreshCount = 4
    private static let terminalRefreshPollIntervalNanoseconds: UInt64 = 750_000_000

    public private(set) var isSignedIn: Bool
    public private(set) var connectionState: MobileConnectionState
    public private(set) var connectedHostName: String
    public private(set) var connectionError: String?
    public private(set) var activeTicket: CmxAttachTicket?
    public private(set) var activeRoute: CmxAttachRoute?
    public var pairingCode: String
    public var workspaces: [MobileWorkspacePreview]
    public var terminalInputText: String
    public var selectedWorkspaceID: MobileWorkspacePreview.ID? {
        didSet {
            syncSelectedTerminalForWorkspace()
            guard !isSuppressingSelectedWorkspaceRefresh else { return }
            scheduleSelectedTerminalSnapshotRefresh()
        }
    }
    public var selectedTerminalID: MobileTerminalPreview.ID?

    private let runtime: CMUXMobileRuntime?
    private let clientID: String
    private var remoteClient: MobileCoreRPCClient? {
        didSet {
            if remoteClient == nil {
                stopTerminalRefreshPolling()
                cancelSelectedTerminalSnapshotRefresh()
            }
        }
    }
    private var terminalRefreshPollTask: Task<Void, Never>?
    private var selectedTerminalSnapshotRefreshTask: Task<Void, Never>?
    private var isSuppressingSelectedWorkspaceRefresh: Bool
    private var isRefreshingSelectedTerminalSnapshot: Bool
    private var needsSelectedTerminalSnapshotRefresh: Bool
    private var reportedViewportSizesByTerminalID: [MobileTerminalPreview.ID: MobileTerminalViewportSize]
    private var viewportSettlingRefreshesByTerminalID: [MobileTerminalPreview.ID: Int]
    private var rawTerminalInputBuffer: MobileTerminalInputSendBuffer

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
        workspaces: [MobileWorkspacePreview] = []
    ) {
        self.runtime = runtime
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
        self.isSuppressingSelectedWorkspaceRefresh = false
        self.isRefreshingSelectedTerminalSnapshot = false
        self.needsSelectedTerminalSnapshotRefresh = false
        self.reportedViewportSizesByTerminalID = [:]
        self.viewportSettlingRefreshesByTerminalID = [:]
        self.rawTerminalInputBuffer = MobileTerminalInputSendBuffer()
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
        isSignedIn = false
        connectionState = .disconnected
        connectedHostName = ""
        pairingCode = ""
        terminalInputText = ""
        connectionError = nil
        activeTicket = nil
        activeRoute = nil
        remoteClient = nil
        isRefreshingSelectedTerminalSnapshot = false
        needsSelectedTerminalSnapshotRefresh = false
        cancelSelectedTerminalSnapshotRefresh()
        reportedViewportSizesByTerminalID = [:]
        viewportSettlingRefreshesByTerminalID = [:]
        workspaces = PreviewMobileHost.workspaces
        selectedWorkspaceID = workspaces.first?.id
        selectedTerminalID = workspaces.first?.terminals.first?.id
    }

    public func resumeForegroundRefresh() {
        guard remoteClient != nil, connectionState == .connected else { return }
        startTerminalRefreshPolling()
        scheduleSelectedTerminalSnapshotRefresh()
    }

    public func connectPreviewHost() {
        let trimmedCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            return
        }
        if trimmedCode.hasPrefix("cmux-ios://") {
            Task { await connectPairingURL(trimmedCode) }
            return
        }
        remoteClient = nil
        connectionError = nil
        activeTicket = nil
        activeRoute = nil
        connectedHostName = PreviewMobileHost.hostName
        connectionState = .connected
        if selectedWorkspaceID == nil {
            selectedWorkspaceID = workspaces.first?.id
        }
        syncSelectedTerminalForWorkspace()
    }

    public func connectManualHost(name: String, host: String, port: Int) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedHost = Self.normalizedManualHost(host) else {
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

        do {
            let ticket = try await manualHostTicket(
                name: trimmedName,
                host: normalizedHost,
                port: port
            )
            try await connect(ticket: ticket)
        } catch {
            mobileShellLog.error("manual host pairing failed: \(String(describing: error), privacy: .private)")
            connectionError = Self.localizedConnectionError(for: error)
            connectionState = .disconnected
            clearRemoteConnectionContext()
        }
    }

    private static func normalizedManualHost(_ rawHost: String) -> String? {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let host: String
        if trimmed.hasPrefix("[") || trimmed.hasSuffix("]") {
            guard trimmed.hasPrefix("["),
                  trimmed.hasSuffix("]"),
                  trimmed.count > 2 else {
                return nil
            }
            host = String(trimmed.dropFirst().dropLast())
        } else {
            host = trimmed
        }

        guard !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              host.rangeOfCharacter(from: .controlCharacters) == nil,
              host.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#@")) == nil,
              host.range(of: "://") == nil else {
            return nil
        }
        return host
    }

    public func connectPairingURL(_ rawValue: String? = nil) async {
        let rawURL = Self.normalizedPairingURL(rawValue ?? pairingCode)
        let ticket: CmxAttachTicket
        do {
            ticket = try CmxAttachTicketInput.decode(rawURL)
        } catch {
            connectionError = L10n.string("mobile.pairing.invalidCode", defaultValue: "Invalid pairing code.")
            connectionState = .disconnected
            clearRemoteConnectionContext()
            return
        }

        do {
            try await connect(ticket: ticket)
        } catch {
            mobileShellLog.error("pairing failed: \(String(describing: error), privacy: .private)")
            connectionError = Self.localizedConnectionError(for: error)
            connectionState = .disconnected
            clearRemoteConnectionContext()
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
        let routeKind = MobileShellRouteAuthPolicy.manualRouteKind(for: host)
        let directRoute = try CmxAttachRoute(
            id: routeKind.rawValue,
            kind: routeKind,
            endpoint: .hostPort(host: host, port: port)
        )
        let displayName = name.isEmpty ? host : name
        if MobileShellRouteAuthPolicy.routeAllowsStackAuth(directRoute) {
            if let ticket = try? await requestManualAttachTicket(
                route: directRoute,
                displayName: displayName
            ) {
                return ticket
            }
            return try Self.manualHostTicket(
                displayName: displayName,
                macDeviceID: "manual-\(host):\(port)",
                route: directRoute
            )
        }

        let discoveredRoute = try await discoverSecureManualRoute(
            probeRoute: directRoute,
            displayName: displayName
        )
        if let ticket = try? await requestManualAttachTicket(
            route: discoveredRoute,
            displayName: displayName
        ) {
            return ticket
        }
        return try Self.manualHostTicket(
            displayName: displayName,
            macDeviceID: "manual-\(host):\(port)",
            route: discoveredRoute
        )
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

    private func discoverSecureManualRoute(
        probeRoute: CmxAttachRoute,
        displayName: String
    ) async throws -> CmxAttachRoute {
        guard let runtime else {
            throw MobileShellConnectionError.insecureManualRoute
        }
        let probeTicket = try Self.manualHostTicket(
            displayName: displayName,
            macDeviceID: "manual-probe",
            route: probeRoute
        )
        let client = MobileCoreRPCClient(runtime: runtime, route: probeRoute, ticket: probeTicket)
        let resultData = try await client.sendRequest(
            MobileCoreRPCClient.requestData(method: "mobile.host.status")
        )
        let status = try MobileManualHostStatusResponse.decode(resultData)
        let supportedKinds = Set(runtime.supportedRouteKinds)
        let secureRoutes = status.routes.filter { route in
            supportedKinds.contains(route.kind) && MobileShellRouteAuthPolicy.routeAllowsStackAuth(route)
        }
        guard let route = secureRoutes.sorted(by: Self.routeSortsBefore).first else {
            throw MobileShellConnectionError.insecureManualRoute
        }
        return route
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
        let client = MobileCoreRPCClient(runtime: runtime, route: route, ticket: probeTicket)
        let resultData = try await client.sendRequest(
            MobileCoreRPCClient.requestData(
                method: "mobile.attach_ticket.create",
                params: ["ttl_seconds": 3600]
            )
        )
        let response = try MobileManualAttachTicketCreateResponse.decode(resultData)
        return try response.ticket.constrainingRoutes(to: [route], fallbackDisplayName: displayName)
    }

    public func createWorkspace() {
        guard remoteClient == nil else {
            Task { await createRemoteWorkspace() }
            return
        }
        let nextIndex = workspaces.count + 1
        let workspace = MobileWorkspacePreview(
            id: .init(rawValue: "workspace-\(nextIndex)"),
            name: L10n.workspaceName(index: nextIndex),
            terminals: [
                MobileTerminalPreview(
                    id: .init(rawValue: "workspace-\(nextIndex)-terminal-1"),
                    name: L10n.terminalName(index: 1),
                    lines: [
                        "$ cmux mobile preview",
                        "workspace: Workspace \(nextIndex)",
                        "terminal: Terminal 1",
                    ]
                ),
            ]
        )
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
        selectedTerminalID = workspace.terminals.first?.id
    }

    public func createTerminal() {
        guard remoteClient == nil else {
            Task { await createRemoteTerminal() }
            return
        }
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == selectedWorkspace?.id }) else {
            return
        }
        let terminalIndex = workspaces[workspaceIndex].terminals.count + 1
        let terminal = MobileTerminalPreview(
            id: .init(rawValue: "\(workspaces[workspaceIndex].id.rawValue)-terminal-\(terminalIndex)"),
            name: L10n.terminalName(index: terminalIndex),
            lines: [
                "$ cmux mobile preview",
                "workspace: \(workspaces[workspaceIndex].name)",
                "terminal: Terminal \(terminalIndex)",
            ]
        )
        workspaces[workspaceIndex].terminals.append(terminal)
        selectedTerminalID = terminal.id
    }

    public func selectTerminal(_ id: MobileTerminalPreview.ID?) {
        selectedTerminalID = id
        scheduleSelectedTerminalSnapshotRefresh()
    }

    public func reportTerminalViewport(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        viewportSize: MobileTerminalViewportSize
    ) {
        let previousViewportSize = reportedViewportSizesByTerminalID[terminalID]
        reportedViewportSizesByTerminalID[terminalID] = viewportSize
        let currentSnapshotClientSize = selectedTerminal?.viewportFit?.client
        if previousViewportSize != viewportSize || currentSnapshotClientSize != viewportSize {
            viewportSettlingRefreshesByTerminalID[terminalID] = max(
                viewportSettlingRefreshesByTerminalID[terminalID] ?? 0,
                Self.viewportSettlingRefreshCount
            )
        }
        guard remoteClient != nil else {
            return
        }
        guard previousViewportSize != viewportSize || currentSnapshotClientSize != viewportSize else {
            return
        }
        scheduleSelectedTerminalSnapshotRefresh()
    }

    public func openWorkspace(_ id: MobileWorkspacePreview.ID) async {
        setSelectedWorkspaceID(id, refreshSnapshot: false)
        if let terminalID = selectedTerminalID,
           reportedViewportSizesByTerminalID[terminalID] != nil {
            viewportSettlingRefreshesByTerminalID[terminalID] = max(
                viewportSettlingRefreshesByTerminalID[terminalID] ?? 0,
                Self.workspaceOpenSettlingRefreshCount
            )
        }
        await refreshSelectedTerminalSnapshot()
    }

    public func sendTerminalInput() {
        Task { await submitTerminalInput() }
    }

    public func submitTerminalInput() async {
        let text = terminalInputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        terminalInputText = ""
        guard remoteClient != nil else {
            appendPreviewInput(text)
            return
        }
        await sendRemoteTerminalInput(text + "\r")
    }

    public func sendTerminalRawInput(_ text: String) {
        #if DEBUG
        mobileShellLog.debug("enqueue raw terminal input byteCount=\(text.utf8.count, privacy: .public)")
        #endif
        guard rawTerminalInputBuffer.enqueue(text) else { return }
        Task { await drainRawTerminalInputBuffer() }
    }

    public func submitTerminalRawInput(_ text: String) async {
        guard !text.isEmpty else { return }
        guard remoteClient != nil else {
            appendPreviewInput(Self.previewLine(forRawTerminalInput: text))
            return
        }
        await sendRemoteTerminalInput(text)
    }

    private func drainRawTerminalInputBuffer() async {
        while let text = rawTerminalInputBuffer.nextBatch() {
            await submitTerminalRawInput(text)
        }
    }

    private func connect(ticket: CmxAttachTicket) async throws {
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        let supportedRoutes = Self.supportedRoutes(for: ticket, supportedKinds: supportedKinds)
        guard let firstRoute = supportedRoutes.first else {
            connectionError = L10n.string("mobile.pairing.unsupportedRoute", defaultValue: "This pairing code uses an unsupported route.")
            connectionState = .disconnected
            clearRemoteConnectionContext()
            return
        }

        activeTicket = ticket
        activeRoute = firstRoute
        connectedHostName = ticket.macDisplayName ?? ticket.macDeviceID
        remoteClient = nil

        guard let runtime else {
            connectionError = nil
            applyPreviewTicket(ticket, route: firstRoute)
            connectionState = .connected
            return
        }

        let requestData = try MobileCoreRPCClient.requestData(
            method: "workspace.list",
            params: Self.initialWorkspaceListParams(for: ticket)
        )
        var lastError: Error?
        for route in supportedRoutes {
            activeRoute = route
            mobileShellLog.info("pairing trying route kind=\(route.kind.rawValue, privacy: .public) endpoint=\(route.endpoint.logDescription, privacy: .private)")
            let client = MobileCoreRPCClient(runtime: runtime, route: route, ticket: ticket)
            do {
                let resultData = try await client.sendRequest(requestData)
                let response = try MobileSyncWorkspaceListResponse.decode(resultData)
                remoteClient = client
                startTerminalRefreshPolling()
                connectionError = nil
                applyRemoteWorkspaceList(response, preferActiveTicketTarget: true)
                syncSelectedTerminalForWorkspace()
                connectionState = .connected
                await refreshSelectedTerminalSnapshot()
                return
            } catch {
                lastError = error
                mobileShellLog.error(
                    "pairing route failed kind=\(route.kind.rawValue, privacy: .public) endpoint=\(route.endpoint.logDescription, privacy: .private): \(String(describing: error), privacy: .private)"
                )
            }
        }

        clearRemoteConnectionContext()
        throw lastError ?? MobileShellConnectionError.connectionClosed
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

    private static func initialWorkspaceListParams(for ticket: CmxAttachTicket) -> [String: Any] {
        guard UUID(uuidString: ticket.workspaceID) != nil else {
            return [:]
        }
        return ["workspace_id": ticket.workspaceID]
    }

    private func clearActiveConnectionContext() {
        activeTicket = nil
        activeRoute = nil
        connectedHostName = ""
    }

    private func clearRemoteConnectionContext() {
        clearActiveConnectionContext()
        remoteClient = nil
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

    private func createRemoteWorkspace() async {
        guard let client = remoteClient else { return }
        do {
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "workspace.create")
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            applyRemoteWorkspaceList(response)
            if let createdID = response.createdWorkspaceID {
                setSelectedWorkspaceID(MobileWorkspacePreview.ID(rawValue: createdID), refreshSnapshot: false)
            }
            syncSelectedTerminalForWorkspace()
            await refreshSelectedTerminalSnapshot()
        } catch {
            connectionError = Self.localizedConnectionError(for: error)
        }
    }

    private func createRemoteTerminal() async {
        guard let client = remoteClient,
              let workspaceID = selectedWorkspace?.id.rawValue else { return }
        do {
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "terminal.create",
                    params: ["workspace_id": workspaceID]
                )
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            applyRemoteWorkspaceList(response, mergeExistingWorkspaces: true)
            if let createdID = response.createdTerminalID {
                selectedTerminalID = MobileTerminalPreview.ID(rawValue: createdID)
            }
            await refreshSelectedTerminalSnapshot()
        } catch {
            connectionError = Self.localizedConnectionError(for: error)
        }
    }

    private func refreshSelectedTerminalSnapshot() async {
        guard let client = remoteClient,
              let workspace = selectedWorkspace,
              let terminalID = selectedTerminalID?.rawValue else { return }
        guard !isRefreshingSelectedTerminalSnapshot else {
            needsSelectedTerminalSnapshotRefresh = true
            return
        }
        isRefreshingSelectedTerminalSnapshot = true
        defer {
            isRefreshingSelectedTerminalSnapshot = false
            if needsSelectedTerminalSnapshotRefresh {
                needsSelectedTerminalSnapshotRefresh = false
                scheduleSelectedTerminalSnapshotRefresh()
            }
        }
        do {
            mobileShellLog.info("refreshing terminal snapshot workspace=\(workspace.id.rawValue, privacy: .private) terminal=\(terminalID, privacy: .private)")
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "terminal.snapshot",
                    params: terminalSnapshotParams(
                        workspaceID: workspace.id.rawValue,
                        terminalID: terminalID
                    )
                )
            )
            let response = try MobileSyncTerminalSnapshotResponse.decode(resultData)
            replaceTerminalSnapshot(
                workspaceID: workspace.id,
                terminalID: MobileTerminalPreview.ID(rawValue: response.surfaceID ?? terminalID),
                snapshot: response.snapshot,
                isReady: true,
                viewportFit: response.viewportFit
            )
            scheduleViewportSettlingRefreshIfNeeded(
                terminalID: MobileTerminalPreview.ID(rawValue: response.surfaceID ?? terminalID)
            )
        } catch {
            mobileShellLog.error("terminal snapshot refresh failed: \(String(describing: error), privacy: .private)")
            if Self.isTerminalSurfaceNotReady(error) {
                if await refreshReadyFallbackTerminalSnapshot(in: workspace, excluding: terminalID) {
                    connectionError = nil
                    return
                }
                replaceTerminalSnapshot(
                    workspaceID: workspace.id,
                    terminalID: MobileTerminalPreview.ID(rawValue: terminalID),
                    snapshot: PreviewMobileHost.snapshot(
                        terminalID: terminalID,
                        lines: [
                            L10n.string("mobile.terminal.surfaceNotReady", defaultValue: "Terminal surface is still starting."),
                        ]
                    ),
                    isReady: false
                )
                viewportSettlingRefreshesByTerminalID[MobileTerminalPreview.ID(rawValue: terminalID)] = nil
                connectionError = nil
                return
            }
            connectionError = Self.localizedConnectionError(for: error)
        }
    }

    private func refreshReadyFallbackTerminalSnapshot(
        in workspace: MobileWorkspacePreview,
        excluding terminalID: String
    ) async -> Bool {
        guard let client = remoteClient else { return false }
        let excludedTerminalID = MobileTerminalPreview.ID(rawValue: terminalID)
        for candidate in terminalSnapshotFallbackCandidates(
            preferredWorkspaceID: workspace.id,
            excludingTerminalID: excludedTerminalID
        ) {
            do {
                let resultData = try await client.sendRequest(
                    MobileCoreRPCClient.requestData(
                        method: "terminal.snapshot",
                        params: terminalSnapshotParams(
                            workspaceID: candidate.workspaceID.rawValue,
                            terminalID: candidate.terminalID.rawValue
                        )
                    )
                )
                let response = try MobileSyncTerminalSnapshotResponse.decode(resultData)
                let resolvedTerminalID = MobileTerminalPreview.ID(rawValue: response.surfaceID ?? candidate.terminalID.rawValue)
                replaceTerminalSnapshot(
                    workspaceID: candidate.workspaceID,
                    terminalID: resolvedTerminalID,
                    snapshot: response.snapshot,
                    isReady: true,
                    viewportFit: response.viewportFit
                )
                setSelectedWorkspaceID(candidate.workspaceID, refreshSnapshot: false)
                selectedTerminalID = resolvedTerminalID
                mobileShellLog.info("selected fallback ready terminal workspace=\(candidate.workspaceID.rawValue, privacy: .private) terminal=\(resolvedTerminalID.rawValue, privacy: .private)")
                return true
            } catch {
                if Self.isTerminalSurfaceNotReady(error) {
                    continue
                }
                mobileShellLog.error("fallback terminal snapshot failed: \(String(describing: error), privacy: .private)")
                return false
            }
        }
        return false
    }

    private func terminalSnapshotFallbackCandidates(
        preferredWorkspaceID: MobileWorkspacePreview.ID,
        excludingTerminalID: MobileTerminalPreview.ID
    ) -> [MobileTerminalSnapshotCandidate] {
        let candidates = workspaces.flatMap { workspace in
            workspace.terminals.compactMap { terminal -> MobileTerminalSnapshotCandidate? in
                guard workspace.id != preferredWorkspaceID || terminal.id != excludingTerminalID else {
                    return nil
                }
                return MobileTerminalSnapshotCandidate(
                    workspaceID: workspace.id,
                    terminalID: terminal.id,
                    isReady: terminal.isReady
                )
            }
        }

        let readyPreferred = candidates.filter { $0.isReady && $0.workspaceID == preferredWorkspaceID }
        let readyElsewhere = candidates.filter { $0.isReady && $0.workspaceID != preferredWorkspaceID }
        let stalePreferred = candidates.filter { !$0.isReady && $0.workspaceID == preferredWorkspaceID }
        let staleElsewhere = candidates.filter { !$0.isReady && $0.workspaceID != preferredWorkspaceID }
        return readyPreferred + readyElsewhere + stalePreferred + staleElsewhere
    }

    private func terminalSnapshotParams(
        workspaceID: String,
        terminalID: String
    ) -> [String: Any] {
        let terminalID = MobileTerminalPreview.ID(rawValue: terminalID)
        let viewportSize = reportedViewportSizesByTerminalID[terminalID]
        var params: [String: Any] = [
            "workspace_id": workspaceID,
            "surface_id": terminalID.rawValue,
            "max_scrollback_rows": MobileTerminalSnapshotRequestPolicy.maxScrollbackRows(
                viewportSize: viewportSize
            ),
            "client_id": clientID,
        ]
        if let viewportSize {
            params["viewport_columns"] = viewportSize.columns
            params["viewport_rows"] = viewportSize.rows
        }
        return params
    }

    private func sendRemoteTerminalInput(_ text: String) async {
        guard let client = remoteClient,
              let workspace = selectedWorkspace,
              let terminalID = selectedTerminalID?.rawValue else {
            #if DEBUG
            mobileShellLog.info("skip remote terminal input remoteClient=\(self.remoteClient == nil ? 0 : 1, privacy: .public) selectedWorkspace=\(self.selectedWorkspace == nil ? 0 : 1, privacy: .public) selectedTerminal=\(self.selectedTerminalID == nil ? 0 : 1, privacy: .public)")
            #endif
            return
        }
        do {
            #if DEBUG
            mobileShellLog.debug("send remote terminal input byteCount=\(text.utf8.count, privacy: .public) workspace=\(workspace.id.rawValue, privacy: .private) terminal=\(terminalID, privacy: .private)")
            #endif
            let terminalPreviewID = MobileTerminalPreview.ID(rawValue: terminalID)
            viewportSettlingRefreshesByTerminalID[terminalPreviewID] = max(
                viewportSettlingRefreshesByTerminalID[terminalPreviewID] ?? 0,
                Self.inputSettlingRefreshCount
            )
            _ = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "terminal.input",
                    params: [
                        "workspace_id": workspace.id.rawValue,
                        "surface_id": terminalID,
                        "text": text,
                    ]
                )
            )
            scheduleSelectedTerminalSnapshotRefresh()
        } catch {
            connectionError = Self.localizedConnectionError(for: error)
        }
    }

    private func scheduleSelectedTerminalSnapshotRefresh() {
        guard remoteClient != nil else { return }
        guard selectedTerminalSnapshotRefreshTask == nil else { return }
        selectedTerminalSnapshotRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.selectedTerminalSnapshotRefreshTask = nil
            guard !Task.isCancelled else { return }
            await self.refreshSelectedTerminalSnapshot()
        }
    }

    private func startTerminalRefreshPolling() {
        guard remoteClient != nil, terminalRefreshPollTask == nil else { return }
        terminalRefreshPollTask = Task { @MainActor [weak self] in
            defer {
                self?.terminalRefreshPollTask = nil
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.terminalRefreshPollIntervalNanoseconds)
                } catch {
                    break
                }
                guard let self else { break }
                guard self.remoteClient != nil, self.connectionState == .connected else {
                    break
                }
                await self.refreshSelectedTerminalSnapshot()
            }
        }
    }

    private func stopTerminalRefreshPolling() {
        terminalRefreshPollTask?.cancel()
        terminalRefreshPollTask = nil
    }

    private func cancelSelectedTerminalSnapshotRefresh() {
        selectedTerminalSnapshotRefreshTask?.cancel()
        selectedTerminalSnapshotRefreshTask = nil
    }

    private func scheduleViewportSettlingRefreshIfNeeded(terminalID: MobileTerminalPreview.ID) {
        guard let remaining = viewportSettlingRefreshesByTerminalID[terminalID],
              remaining > 0 else {
            viewportSettlingRefreshesByTerminalID[terminalID] = nil
            return
        }
        viewportSettlingRefreshesByTerminalID[terminalID] = remaining - 1
        scheduleSelectedTerminalSnapshotRefresh()
    }

    private func setSelectedWorkspaceID(
        _ id: MobileWorkspacePreview.ID?,
        refreshSnapshot: Bool
    ) {
        guard !refreshSnapshot else {
            selectedWorkspaceID = id
            return
        }
        isSuppressingSelectedWorkspaceRefresh = true
        selectedWorkspaceID = id
        isSuppressingSelectedWorkspaceRefresh = false
    }

    private func applyRemoteWorkspaceList(
        _ response: MobileSyncWorkspaceListResponse,
        preferActiveTicketTarget: Bool = false,
        mergeExistingWorkspaces: Bool = false
    ) {
        let remoteWorkspaces = response.workspaces.map(MobileWorkspacePreview.init(remote:))
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
                ?? workspaces.first?.id,
            refreshSnapshot: false
        )
        syncSelectedTerminalForWorkspace()
    }

    private func selectActiveTicketTargetIfAvailable() -> Bool {
        guard let activeTicket else {
            return false
        }
        let ticketWorkspaceID = MobileWorkspacePreview.ID(rawValue: activeTicket.workspaceID)
        guard let workspace = workspaces.first(where: { $0.id == ticketWorkspaceID }) else {
            return false
        }
        setSelectedWorkspaceID(ticketWorkspaceID, refreshSnapshot: false)
        if let ticketTerminalID = activeTicket.terminalID.map(MobileTerminalPreview.ID.init(rawValue:)),
           workspace.terminals.contains(where: { $0.id == ticketTerminalID }) {
            selectedTerminalID = ticketTerminalID
        } else {
            syncSelectedTerminalForWorkspace()
        }
        return true
    }

    private func replaceTerminalSnapshot(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        snapshot: MobileTerminalGhosttySnapshot,
        isReady: Bool? = nil,
        viewportFit: MobileTerminalViewportFit? = nil
    ) {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let terminalIndex = workspaces[workspaceIndex].terminals.firstIndex(where: { $0.id == terminalID }) else {
            return
        }
        var updatedWorkspaces = workspaces
        updatedWorkspaces[workspaceIndex].terminals[terminalIndex].snapshot = snapshot
        if let isReady {
            updatedWorkspaces[workspaceIndex].terminals[terminalIndex].isReady = isReady
        }
        updatedWorkspaces[workspaceIndex].terminals[terminalIndex].viewportFit = viewportFit
        workspaces = updatedWorkspaces
        mobileShellLog.info("replaced terminal snapshot workspace=\(workspaceID.rawValue, privacy: .private) terminal=\(terminalID.rawValue, privacy: .private) rows=\(snapshot.visibleRows.count, privacy: .public)")
    }

    private static func isTerminalSurfaceNotReady(_ error: Error) -> Bool {
        guard case let MobileShellConnectionError.rpcError(_, message) = error else {
            return false
        }
        return message.localizedCaseInsensitiveContains("surface is not ready")
    }

    private static func localizedConnectionError(for error: Error) -> String {
        guard let connectionError = error as? MobileShellConnectionError else {
            return L10n.string("mobile.pairing.runtimeUnavailable", defaultValue: "Could not connect to the Mac runtime.")
        }
        switch connectionError {
        case .requestTimedOut:
            return L10n.string("mobile.pairing.requestTimedOut", defaultValue: "The Mac did not respond. Check the host and port, then try again.")
        case .insecureManualRoute:
            return L10n.string("mobile.pairing.secureRouteRequired", defaultValue: "Use your Mac's Tailscale MagicDNS name, or pair with a QR/link from that Mac.")
        case .authorizationFailed:
            return L10n.string("mobile.pairing.authorizationFailed", defaultValue: "Sign in to cmux on your Mac with the same account, or pair with a QR/link from that Mac.")
        case .invalidResponse, .connectionClosed, .rpcError:
            return L10n.string("mobile.pairing.runtimeUnavailable", defaultValue: "Could not connect to the Mac runtime.")
        }
    }

    private static func routeSortsBefore(_ left: CmxAttachRoute, _ right: CmxAttachRoute) -> Bool {
        if left.priority == right.priority {
            return left.id < right.id
        }
        return left.priority < right.priority
    }

    private static func previewLine(forRawTerminalInput text: String) -> String {
        switch text {
        case "\u{1B}":
            return "Esc"
        case "\t":
            return "Tab"
        case "\u{1B}[A":
            return "↑"
        case "\u{1B}[B":
            return "↓"
        case "\u{1B}[D":
            return "←"
        case "\u{1B}[C":
            return "→"
        case "\u{03}":
            return "^C"
        case "\u{04}":
            return "^D"
        case "\u{1A}":
            return "^Z"
        case "\u{0C}":
            return "^L"
        default:
            if text.hasSuffix("\r") {
                return String(text.dropLast())
            }
            return text
        }
    }

    private func appendPreviewInput(_ text: String) {
        guard let workspace = selectedWorkspace,
              let terminalID = selectedTerminalID,
              let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspace.id }),
              let terminalIndex = workspaces[workspaceIndex].terminals.firstIndex(where: { $0.id == terminalID }) else {
            return
        }
        let terminal = workspaces[workspaceIndex].terminals[terminalIndex]
        let lines = Array((terminal.lines + ["> \(text)"]).suffix(6))
        workspaces[workspaceIndex].terminals[terminalIndex].snapshot = PreviewMobileHost.snapshot(
            terminalID: terminal.id.rawValue,
            lines: lines
        )
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
                        name: L10n.string("mobile.preview.attachedTerminalName", defaultValue: "Attached Terminal"),
                        lines: [
                            "$ cmux attach",
                            "mac: \(ticket.macDisplayName ?? ticket.macDeviceID)",
                            "route: \(route.kind.rawValue)",
                            "runtime: waiting for transport",
                        ]
                    ),
                ]
            ),
        ]
        selectedWorkspaceID = workspaces.first?.id
        selectedTerminalID = workspaces.first?.terminals.first?.id
    }
}

private struct MobileTerminalSnapshotCandidate: Sendable {
    var workspaceID: MobileWorkspacePreview.ID
    var terminalID: MobileTerminalPreview.ID
    var isReady: Bool
}

private struct MobileManualHostStatusResponse: Decodable, Sendable {
    private struct HostService: Decodable, Sendable {
        var routes: [CmxAttachRoute]
    }

    var routes: [CmxAttachRoute]

    private enum CodingKeys: String, CodingKey {
        case routes
        case hostService = "host_service"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let routes = try container.decodeIfPresent([CmxAttachRoute].self, forKey: .routes) {
            self.routes = routes
            return
        }
        routes = try container.decode(HostService.self, forKey: .hostService).routes
    }

    static func decode(_ data: Data) throws -> MobileManualHostStatusResponse {
        try JSONDecoder().decode(MobileManualHostStatusResponse.self, from: data)
    }
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

private enum MobileShellConnectionError: LocalizedError {
    case invalidResponse
    case connectionClosed
    case requestTimedOut
    case insecureManualRoute
    case authorizationFailed(String)
    case rpcError(String?, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid mobile sync response"
        case .connectionClosed:
            return "Mobile sync connection closed"
        case .requestTimedOut:
            return "Mobile sync request timed out"
        case .insecureManualRoute:
            return "Manual host did not advertise a secure mobile sync route"
        case let .authorizationFailed(message):
            return message
        case let .rpcError(_, message):
            return message
        }
    }
}

private enum CmxAttachTicketInput {
    static func decode(_ rawValue: String) throws -> CmxAttachTicket {
        guard let url = URL(string: rawValue) else {
            throw MobileSyncPairingPayloadError.invalidURL
        }
        if url.scheme == "cmux-ios", url.host == "pair" {
            return try ticket(from: MobileSyncPairingPayload.decodeURL(url))
        }
        guard url.scheme == "cmux-ios",
              url.host == "attach",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encodedPayload = components.queryItems?.first(where: { $0.name == "payload" })?.value,
              let data = base64URLDecode(encodedPayload) else {
            throw MobileSyncPairingPayloadError.invalidURL
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ticket = try decoder.decode(CmxAttachTicket.self, from: data)
        try ticket.validate()
        return ticket
    }

    private static func ticket(from payload: MobileSyncPairingPayload) throws -> CmxAttachTicket {
        let route = try CmxAttachRoute(
            id: payload.transport.rawValue,
            kind: payload.transport,
            endpoint: .hostPort(host: payload.host, port: payload.port)
        )
        return try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: nil,
            macDeviceID: payload.macDeviceID,
            macDisplayName: payload.macDisplayName,
            routes: [route],
            expiresAt: payload.expiresAt
        )
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: 4 - padding))
        }
        return Data(base64Encoded: base64)
    }
}

private final class MobileCoreRPCClient: @unchecked Sendable {
    private let runtime: CMUXMobileRuntime
    private let route: CmxAttachRoute
    private let ticket: CmxAttachTicket

    init(runtime: CMUXMobileRuntime, route: CmxAttachRoute, ticket: CmxAttachTicket) {
        self.runtime = runtime
        self.route = route
        self.ticket = ticket
    }

    static func requestData(
        method: String,
        params: [String: Any] = [:],
        id: String = UUID().uuidString
    ) throws -> Data {
        let request: [String: Any] = [
            "id": id,
            "method": method,
            "params": params,
        ]
        return try JSONSerialization.data(withJSONObject: request)
    }

    func sendRequest(_ requestData: Data) async throws -> Data {
        let transport = try runtime.transportFactory.makeTransport(for: route)
        do {
            let response = try await Self.withRequestTimeout(
                timeoutNanoseconds: runtime.rpcRequestTimeoutNanoseconds
            ) {
                try await transport.connect()
                let authenticatedRequestData = try await self.requestDataWithAuth(requestData)
                let frame = try MobileSyncFrameCodec.encodeFrame(authenticatedRequestData)
                try await transport.send(frame)
                let responseFrame = try await self.receiveFrame(from: transport)
                return try self.decodeResultEnvelope(responseFrame)
            }
            await transport.close()
            return response
        } catch {
            await transport.close()
            throw error
        }
    }

    private func requestDataWithAuth(_ requestData: Data) async throws -> Data {
        guard var request = try JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
            return requestData
        }
        var auth: [String: Any] = [:]
        if let authToken = ticket.authToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !authToken.isEmpty,
           ticket.expiresAt > runtime.now() {
            auth["attach_token"] = authToken
        }
        let shouldSendStackAuth = auth["attach_token"] == nil
            ? Self.requestRequiresAuth(request)
            : Self.requestNeedsStackAuthFallback(request, ticket: ticket)
        if shouldSendStackAuth {
            guard MobileShellRouteAuthPolicy.routeAllowsStackAuth(route) else {
                throw MobileShellConnectionError.insecureManualRoute
            }
            do {
                auth["stack_access_token"] = try await runtime.stackAccessTokenProvider()
            } catch {
                throw MobileShellConnectionError.authorizationFailed(
                    L10n.string(
                        "mobile.pairing.stackAuthTokenUnavailable",
                        defaultValue: "Sign in to cmux on your Mac with the same account, then try again."
                    )
                )
            }
        }
        if !auth.isEmpty {
            request["auth"] = auth
        }
        return try JSONSerialization.data(withJSONObject: request)
    }

    private static func requestNeedsStackAuthFallback(_ request: [String: Any], ticket: CmxAttachTicket) -> Bool {
        guard requestRequiresAuth(request) else {
            return false
        }
        let method = (request["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = request["params"] as? [String: Any] ?? [:]
        let workspaceID = stringParam(params, keys: ["workspace_id", "workspaceID"])
        let terminalID = stringParam(params, keys: ["surface_id", "terminal_id", "terminalID", "tab_id"])

        switch method {
        case "mobile.workspace.list", "workspace.list":
            return workspaceID != ticket.workspaceID
        case "mobile.terminal.create", "terminal.create",
             "mobile.terminal.snapshot", "terminal.snapshot",
             "mobile.terminal.input", "terminal.input":
            guard workspaceID == ticket.workspaceID else {
                return true
            }
            if let ticketTerminalID = ticket.terminalID {
                return terminalID != ticketTerminalID
            }
            return false
        default:
            return true
        }
    }

    private static func requestRequiresAuth(_ request: [String: Any]) -> Bool {
        let method = (request["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return method != "mobile.host.status"
    }

    private static func stringParam(_ params: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = params[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private func receiveFrame(from transport: any CmxByteTransport) async throws -> Data {
        var buffer = Data()
        while true {
            guard let chunk = try await transport.receive() else {
                throw MobileShellConnectionError.connectionClosed
            }
            guard !chunk.isEmpty else {
                continue
            }
            buffer.append(chunk)
            let frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
            if let frame = frames.first {
                return frame
            }
        }
    }

    private func decodeResultEnvelope(_ frame: Data) throws -> Data {
        guard let envelope = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let ok = envelope["ok"] as? Bool else {
            throw MobileShellConnectionError.invalidResponse
        }
        if ok {
            let result = envelope["result"] ?? [:]
            return try JSONSerialization.data(withJSONObject: result)
        }
        if let error = envelope["error"] as? [String: Any],
           let message = error["message"] as? String {
            let code = error["code"] as? String
            if code == "unauthorized" {
                throw MobileShellConnectionError.authorizationFailed(message)
            }
            throw MobileShellConnectionError.rpcError(code, message)
        }
        throw MobileShellConnectionError.invalidResponse
    }

    private static func withRequestTimeout<T: Sendable>(
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timerQueue = DispatchQueue(label: "dev.cmux.mobile.rpc-timeout.\(UUID().uuidString)")
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        let operationTask = Task {
            try await operation()
        }

        return try await withCheckedThrowingContinuation { continuation in
            let state = MobileRequestTimeoutState(
                continuation: continuation,
                operationTask: operationTask,
                timer: timer
            )
            timer.setEventHandler {
                state.timeout()
            }
            timer.schedule(deadline: .now() + .nanoseconds(Int(min(timeoutNanoseconds, UInt64(Int.max)))))
            timer.resume()

            Task {
                do {
                    state.complete(.success(try await operationTask.value))
                } catch {
                    state.complete(.failure(error))
                }
            }
        }
    }
}

private final class MobileRequestTimeoutState<T: Sendable>: @unchecked Sendable {
    // DispatchSourceTimer and Task completion race on different executors; this
    // lock protects the single-resume continuation state.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var operationTask: Task<T, Error>?
    private var timer: DispatchSourceTimer?

    init(
        continuation: CheckedContinuation<T, Error>,
        operationTask: Task<T, Error>,
        timer: DispatchSourceTimer
    ) {
        self.continuation = continuation
        self.operationTask = operationTask
        self.timer = timer
    }

    func complete(_ result: Result<T, Error>) {
        let continuation = takeContinuation(cancelOperation: false)
        switch result {
        case let .success(value):
            continuation?.resume(returning: value)
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }

    func timeout() {
        takeContinuation(cancelOperation: true)?
            .resume(throwing: MobileShellConnectionError.requestTimedOut)
    }

    private func takeContinuation(cancelOperation: Bool) -> CheckedContinuation<T, Error>? {
        lock.lock()
        let continuation = self.continuation
        let operationTask = self.operationTask
        let timer = self.timer
        self.continuation = nil
        self.operationTask = nil
        self.timer = nil
        lock.unlock()

        timer?.cancel()
        if cancelOperation {
            operationTask?.cancel()
        }
        return continuation
    }
}

private extension CmxAttachEndpoint {
    var logDescription: String {
        switch self {
        case let .hostPort(host, port):
            return "\(host):\(port)"
        case let .peer(id, relayHint, directAddrs, relayURL):
            let addressSummary = directAddrs.isEmpty ? "no-direct-addrs" : "\(directAddrs.count)-direct-addrs"
            return "peer:\(id):\(relayHint ?? relayURL ?? "no-relay"):\(addressSummary)"
        case let .url(url):
            return url
        }
    }
}

private struct MobileSyncWorkspaceListResponse: Decodable, Sendable {
    struct Workspace: Decodable, Sendable {
        let id: String
        let title: String
        let currentDirectory: String?
        let isSelected: Bool
        let terminals: [Terminal]

        private enum CodingKeys: String, CodingKey {
            case id
            case title
            case currentDirectory = "current_directory"
            case isSelected = "is_selected"
            case terminals
        }
    }

    struct Terminal: Decodable, Sendable {
        let id: String
        let title: String
        let currentDirectory: String?
        let isFocused: Bool
        let isReady: Bool?

        private enum CodingKeys: String, CodingKey {
            case id
            case title
            case currentDirectory = "current_directory"
            case isFocused = "is_focused"
            case isReady = "is_ready"
        }
    }

    let workspaces: [Workspace]
    let createdWorkspaceID: String?
    let createdTerminalID: String?

    private enum CodingKeys: String, CodingKey {
        case workspaces
        case createdWorkspaceID = "created_workspace_id"
        case createdTerminalID = "created_terminal_id"
    }

    static func decode(_ data: Data) throws -> MobileSyncWorkspaceListResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

private struct MobileSyncTerminalSnapshotResponse: Decodable, Sendable {
    let snapshot: MobileTerminalGhosttySnapshot
    let surfaceID: String?
    let viewportFit: MobileTerminalViewportFit?

    private enum CodingKeys: String, CodingKey {
        case snapshot
        case surfaceID = "surface_id"
        case viewportFit = "viewport_fit"
    }

    static func decode(_ data: Data) throws -> MobileSyncTerminalSnapshotResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(Self.self, from: data)
        try response.snapshot.validate()
        return response
    }
}

private extension MobileWorkspacePreview {
    init(remote: MobileSyncWorkspaceListResponse.Workspace) {
        self.init(
            id: ID(rawValue: remote.id),
            name: remote.title,
            terminals: remote.terminals.map { terminal in
                MobileTerminalPreview(remote: terminal)
            }
        )
    }
}

private extension MobileTerminalPreview {
    init(remote: MobileSyncWorkspaceListResponse.Terminal) {
        self.init(
            id: ID(rawValue: remote.id),
            name: remote.title,
            lines: [
                "$ cmux ios",
                "terminal: \(remote.title)",
                remote.currentDirectory.map { "directory: \($0)" } ?? "directory: unavailable",
            ],
            isReady: remote.isReady ?? true,
            isFocused: remote.isFocused
        )
    }
}

enum PreviewMobileHost {
    static let hostName = "cmux-macbook"

    static let workspaces: [MobileWorkspacePreview] = [
        MobileWorkspacePreview(
            id: "workspace-main",
            name: "cmux",
            terminals: [
                MobileTerminalPreview(
                    id: "terminal-build",
                    name: "Build",
                    lines: [
                        "$ cmux ios status",
                        "Mobile Core: enabled",
                        "Runtime: not connected",
                        "Transport: injectable",
                    ]
                ),
                MobileTerminalPreview(
                    id: "terminal-agent",
                    name: "Agent",
                    lines: [
                        "$ git status --short",
                        "## feat-ios-swift-mobile-core",
                        "$ swift test",
                        "Test Suite passed",
                    ]
                ),
                MobileTerminalPreview(
                    id: "terminal-tui",
                    name: "TUI",
                    snapshot: snapshot(
                        terminalID: "terminal-tui",
                        lines: [
                            "LAZYGIT",
                            "files branches log",
                            "main feat-ios clean",
                            "q quit",
                        ],
                        activeScreen: .alternate,
                        modes: MobileTerminalGhosttyModes(
                            bracketedPaste: true,
                            applicationCursorKeys: true,
                            applicationKeypad: true,
                            mouseTracking: true,
                            cursorVisible: false
                        ),
                        streamOffset: 128
                    )
                ),
            ]
        ),
        MobileWorkspacePreview(
            id: "workspace-docs",
            name: "Docs",
            terminals: [
                MobileTerminalPreview(
                    id: "terminal-notes",
                    name: "Notes",
                    lines: [
                        "$ rg \"CMUXMobileCore\" docs",
                        "docs/ios-swift-mobile-plan.md:iOS shell depends on CMUXMobileCore.",
                    ]
                ),
            ]
        ),
    ]

    static func snapshot(
        terminalID: String,
        lines: [String],
        scrollbackLines: [String] = [],
        activeScreen: MobileTerminalGhosttyScreen = .primary,
        modes: MobileTerminalGhosttyModes = MobileTerminalGhosttyModes(),
        streamOffset: UInt64 = 0
    ) -> MobileTerminalGhosttySnapshot {
        do {
            return try MobileTerminalGhosttySnapshot.fixture(
                terminalID: terminalID,
                columns: 48,
                rows: 6,
                scrollbackLines: scrollbackLines,
                visibleLines: lines,
                activeScreen: activeScreen,
                modes: modes,
                streamOffset: streamOffset
            )
        } catch {
            preconditionFailure("Invalid mobile terminal preview snapshot: \(error)")
        }
    }
}
