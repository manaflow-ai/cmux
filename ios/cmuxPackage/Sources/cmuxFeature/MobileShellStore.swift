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
    private static let maximumScrollbackRows = 0
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

enum MobileTerminalInputEnqueueResult: Equatable, Sendable {
    case startDraining
    case queued
    case rejected
}

struct MobileTerminalInputSendBuffer: Equatable, Sendable {
    static let maximumPendingByteCount = 64 * 1024

    struct Chunk: Equatable, Sendable {
        var workspaceID: MobileWorkspacePreview.ID
        var terminalID: MobileTerminalPreview.ID
        var text: String
    }

    private(set) var pendingChunks: [Chunk] = []
    private(set) var pendingByteCount = 0
    private(set) var isDraining = false

    mutating func enqueue(
        _ text: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) -> MobileTerminalInputEnqueueResult {
        guard !text.isEmpty else { return .queued }
        let byteCount = text.utf8.count
        guard pendingByteCount + byteCount <= Self.maximumPendingByteCount else {
            return .rejected
        }
        if var last = pendingChunks.last,
           last.workspaceID == workspaceID,
           last.terminalID == terminalID {
            last.text += text
            pendingChunks[pendingChunks.count - 1] = last
        } else {
            pendingChunks.append(
                Chunk(
                    workspaceID: workspaceID,
                    terminalID: terminalID,
                    text: text
                )
            )
        }
        pendingByteCount += byteCount
        guard !isDraining else { return .queued }
        isDraining = true
        return .startDraining
    }

    mutating func nextBatch() -> Chunk? {
        guard !pendingChunks.isEmpty else {
            isDraining = false
            return nil
        }
        let chunk = pendingChunks.removeFirst()
        pendingByteCount = max(0, pendingByteCount - chunk.text.utf8.count)
        return chunk
    }

    mutating func clear() {
        pendingChunks.removeAll()
        pendingByteCount = 0
        isDraining = false
    }
}

public enum MobileConnectionState: Equatable, Sendable {
    case disconnected
    case connected
}

public enum MobilePairingURLConnectionResult: Equatable, Sendable {
    case connected
    case failed
    case superseded

    public var didConnect: Bool {
        self == .connected
    }
}

public enum MobileShellPhase: Equatable, Sendable {
    case signIn
    case pairing
    case workspaces
}

public struct CMUXMobileRuntime: Sendable {
    public static let defaultRPCRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    public static let defaultPairingRequestTimeoutNanoseconds: UInt64 = 8 * 1_000_000_000

    public var supportedRouteKinds: [CmxAttachTransportKind]
    public var transportFactory: any CmxByteTransportFactory
    public var stackAccessTokenProvider: @Sendable () async throws -> String
    public var rpcRequestTimeoutNanoseconds: UInt64
    public var pairingRequestTimeoutNanoseconds: UInt64
    public var now: @Sendable () -> Date
    /// When false, `MobileShellStore` skips background terminal refresh.
    /// Scripted transport tests set this off so background subscribe/poll
    /// requests don't consume responses intended for foreground methods.
    /// Production sets it on (the default), and falls back to the legacy
    /// 750ms poll only when a connected Mac does not support events.
    public var supportsServerPushEvents: Bool

    private static var defaultStackAccessTokenProvider: @Sendable () async throws -> String {
        {
            #if DEBUG
            if let token = MobileShellDevStackAuthTokenProvider.token() {
                return token
            }
            #endif
            return try await AuthManager.shared.getAccessToken()
        }
    }

    public init(
        supportedRouteKinds: [CmxAttachTransportKind] = [.tailscale, .debugLoopback],
        transportFactory: any CmxByteTransportFactory,
        stackAccessTokenProvider: (@Sendable () async throws -> String)? = nil,
        rpcRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultRPCRequestTimeoutNanoseconds,
        pairingRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultPairingRequestTimeoutNanoseconds,
        now: @escaping @Sendable () -> Date = Date.init,
        supportsServerPushEvents: Bool = true
    ) {
        self.supportedRouteKinds = supportedRouteKinds
        self.transportFactory = transportFactory
        self.stackAccessTokenProvider = stackAccessTokenProvider ?? Self.defaultStackAccessTokenProvider
        self.rpcRequestTimeoutNanoseconds = rpcRequestTimeoutNanoseconds
        self.pairingRequestTimeoutNanoseconds = pairingRequestTimeoutNanoseconds
        self.now = now
        self.supportsServerPushEvents = supportsServerPushEvents
    }

    public init(
        transportFactory: any CmxRouteAwareByteTransportFactory,
        stackAccessTokenProvider: (@Sendable () async throws -> String)? = nil,
        rpcRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultRPCRequestTimeoutNanoseconds,
        pairingRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultPairingRequestTimeoutNanoseconds,
        now: @escaping @Sendable () -> Date = Date.init,
        supportsServerPushEvents: Bool = true
    ) {
        self.supportedRouteKinds = transportFactory.supportedKinds
        self.transportFactory = transportFactory
        self.stackAccessTokenProvider = stackAccessTokenProvider ?? Self.defaultStackAccessTokenProvider
        self.rpcRequestTimeoutNanoseconds = rpcRequestTimeoutNanoseconds
        self.pairingRequestTimeoutNanoseconds = pairingRequestTimeoutNanoseconds
        self.supportsServerPushEvents = supportsServerPushEvents
        self.now = now
    }
}

#if DEBUG
enum MobileShellDevStackAuthTokenProvider {
    static let environmentKey = "CMUX_MOBILE_DEV_STACK_AUTH_TOKEN"

    static func token(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let token = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }
}
#endif

enum MobileShellRouteAuthPolicy {
    static func normalizedManualHost(_ rawHost: String) -> String? {
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
            return isTailscaleHost(host) || isPrivateLANHost(host) || isLocalDNSHost(host)
        case (.iroh, .peer):
            return true
        default:
            return false
        }
    }

    static func routeAllowsImplicitPairLinkStackAuth(_ route: CmxAttachRoute) -> Bool {
        switch (route.kind, route.endpoint) {
        case (.debugLoopback, let .hostPort(host, _)):
            return isLoopbackHost(host)
        default:
            return false
        }
    }

    static func manualHostNeedsTrustWarning(_ host: String) -> Bool {
        guard let normalizedHost = normalizedManualNetworkHost(host) else {
            return false
        }
        return !isLoopbackHost(normalizedHost) && !isTailscaleHost(normalizedHost)
    }

    private static func normalizedManualNetworkHost(_ host: String) -> String? {
        normalizedManualHost(host)?.lowercased()
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedHost == "localhost" ||
            normalizedHost == "::1" ||
            isIPv4LoopbackHost(normalizedHost)
    }

    private static func isIPv4LoopbackHost(_ host: String) -> Bool {
        guard let octets = ipv4Octets(host) else {
            return false
        }
        return octets[0] == 127
    }

    private static func isTailscaleHost(_ host: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return isTailscaleDNSHost(normalizedHost) || isTailscaleIPv4Host(normalizedHost)
    }

    private static func isTailscaleIPv4Host(_ host: String) -> Bool {
        guard let octets = ipv4Octets(host) else {
            return false
        }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return nil
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
        guard octets.count == 4 else {
            return nil
        }
        return octets
    }

    private static func isTailscaleDNSHost(_ host: String) -> Bool {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasSuffix(".ts.net")
    }

    private static func isPrivateLANHost(_ host: String) -> Bool {
        guard let octets = ipv4Octets(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            return false
        }
        return octets[0] == 10 ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168) ||
            (octets[0] == 169 && octets[1] == 254)
    }

    private static func isLocalDNSHost(_ host: String) -> Bool {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasSuffix(".local")
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
            guard !isSuppressingSelectedWorkspaceRefresh else { return }
            scheduleSelectedTerminalSnapshotRefresh()
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
                cancelSelectedTerminalSnapshotRefresh()
                cancelRemoteOperationTasks()
                lowerFidelityDeferralRefreshesByTerminalKey = [:]
                viewportEchoSettlingKeys = []
                viewportMatchedEchoByTerminalKey = []
            }
        }
    }
    private var terminalRefreshPollTask: Task<Void, Never>?
    private var terminalEventListenerTask: Task<Void, Never>?
    private var terminalEventListenerID: UUID?
    private var selectedTerminalSnapshotRefreshTask: Task<Void, Never>?
    private var createWorkspaceTask: Task<Void, Never>?
    private var createTerminalTask: Task<Void, Never>?
    private var workspaceListRefreshTask: Task<Void, Never>?
    private var createWorkspaceTaskID: UUID?
    private var createTerminalTaskID: UUID?
    private var connectionGeneration: UUID
    private var isSuppressingSelectedWorkspaceRefresh: Bool
    private var isRefreshingSelectedTerminalSnapshot: Bool
    private var needsSelectedTerminalSnapshotRefresh: Bool
    private var lowerFidelityDeferralRefreshesByTerminalKey: [MobileTerminalViewportKey: Int]
    private var reportedViewportSizesByTerminalKey: [MobileTerminalViewportKey: MobileTerminalViewportSize]
    private var viewportSettlingRefreshesByTerminalKey: [MobileTerminalViewportKey: Int]
    private var viewportEchoSettlingKeys: Set<MobileTerminalViewportKey>
    private var viewportMatchedEchoByTerminalKey: Set<MobileTerminalViewportKey>
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
        self.terminalRefreshPollTask = nil
        self.terminalEventListenerID = nil
        self.selectedTerminalSnapshotRefreshTask = nil
        self.createWorkspaceTask = nil
        self.createTerminalTask = nil
        self.workspaceListRefreshTask = nil
        self.createWorkspaceTaskID = nil
        self.createTerminalTaskID = nil
        self.connectionGeneration = UUID()
        self.isSuppressingSelectedWorkspaceRefresh = false
        self.isRefreshingSelectedTerminalSnapshot = false
        self.needsSelectedTerminalSnapshotRefresh = false
        self.lowerFidelityDeferralRefreshesByTerminalKey = [:]
        self.reportedViewportSizesByTerminalKey = [:]
        self.viewportSettlingRefreshesByTerminalKey = [:]
        self.viewportEchoSettlingKeys = []
        self.viewportMatchedEchoByTerminalKey = []
        self.rawTerminalInputBuffer = MobileTerminalInputSendBuffer()
        self.pairingAttemptID = UUID()
    }

    isolated deinit {
        terminalRefreshPollTask?.cancel()
        terminalEventListenerTask?.cancel()
        selectedTerminalSnapshotRefreshTask?.cancel()
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
        isRefreshingSelectedTerminalSnapshot = false
        needsSelectedTerminalSnapshotRefresh = false
        cancelSelectedTerminalSnapshotRefresh()
        cancelRemoteOperationTasks()
        rawTerminalInputBuffer.clear()
        lowerFidelityDeferralRefreshesByTerminalKey = [:]
        reportedViewportSizesByTerminalKey = [:]
        viewportSettlingRefreshesByTerminalKey = [:]
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
        guard let pairedMacStore else { return false }
        guard isSignedIn else { return false }
        let saved: MobilePairedMac?
        do {
            saved = try pairedMacStore.activeMac(stackUserID: stackUserID)
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

    private func persistPairedMacFromTicket(_ ticket: CmxAttachTicket) {
        guard let pairedMacStore else { return }
        guard !ticket.macDeviceID.isEmpty else { return }
        // Strip routes that we can't reconnect to without server-side state
        // (manual-workspace routes have no real macDeviceID and aren't useful).
        guard ticket.macDeviceID != "manual-ticket-request",
              !ticket.macDeviceID.hasPrefix("manual-") else { return }
        let stackUserID = AuthManager.shared.currentUser?.id
        do {
            try pairedMacStore.upsert(
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
            do {
                try pairedMacStore.remove(macDeviceID: macID)
            } catch {
                mobileShellLog.error("forgetActiveMac removal failed: \(String(describing: error), privacy: .private)")
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
                params: ["ttl_seconds": 3600]
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
        selectedTerminalSnapshotRefreshTask?.cancel()
        selectedTerminalSnapshotRefreshTask = nil
        if isRefreshingSelectedTerminalSnapshot {
            needsSelectedTerminalSnapshotRefresh = true
        }
        scheduleSelectedTerminalSnapshotRefresh(yieldBeforeRefresh: false)
    }

    public func reportTerminalViewport(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        viewportSize: MobileTerminalViewportSize
    ) {
        let key = viewportKey(workspaceID: workspaceID, terminalID: terminalID)
        let previousViewportSize = reportedViewportSizesByTerminalKey[key]
        reportedViewportSizesByTerminalKey[key] = viewportSize
        let currentSnapshotClientSize = terminalSnapshotClientSize(workspaceID: workspaceID, terminalID: terminalID)
        if previousViewportSize != viewportSize || currentSnapshotClientSize != viewportSize {
            viewportEchoSettlingKeys.insert(key)
            viewportMatchedEchoByTerminalKey.remove(key)
            viewportSettlingRefreshesByTerminalKey[key] = max(
                viewportSettlingRefreshesByTerminalKey[key] ?? 0,
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
           let key = selectedTerminalViewportKey(workspaceID: id, terminalID: terminalID),
           reportedViewportSizesByTerminalKey[key] != nil {
            viewportEchoSettlingKeys.remove(key)
            viewportMatchedEchoByTerminalKey.remove(key)
            viewportSettlingRefreshesByTerminalKey[key] = max(
                viewportSettlingRefreshesByTerminalKey[key] ?? 0,
                Self.workspaceOpenSettlingRefreshCount
            )
        }
        await refreshSelectedTerminalSnapshot()
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

    private func submitTerminalRawInput(
        _ text: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) async {
        guard !text.isEmpty else { return }
        guard remoteClient != nil else {
            appendPreviewInput(Self.previewLine(forRawTerminalInput: text))
            return
        }
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
                    persistPairedMacFromTicket(ticket)
                    applyRemoteWorkspaceList(response, preferActiveTicketTarget: workspaceListRequest.preferActiveTicketTarget)
                    syncSelectedTerminalForWorkspace()
                    connectionState = .connected
                    await refreshSelectedTerminalSnapshot()
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
        createWorkspaceTask?.cancel()
        createWorkspaceTask = nil
        createWorkspaceTaskID = nil
        createTerminalTask?.cancel()
        createTerminalTask = nil
        createTerminalTaskID = nil
        workspaceListRefreshTask?.cancel()
        workspaceListRefreshTask = nil
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

    private func selectedTerminalViewportKey(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) -> MobileTerminalViewportKey? {
        guard workspaces.contains(where: { workspace in
            workspace.id == workspaceID && workspace.terminals.contains(where: { $0.id == terminalID })
        }) else {
            return nil
        }
        return viewportKey(workspaceID: workspaceID, terminalID: terminalID)
    }

    private func terminalSnapshotClientSize(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) -> MobileTerminalViewportSize? {
        workspaces
            .first { $0.id == workspaceID }?
            .terminals
            .first { $0.id == terminalID }?
            .viewportFit?
            .client
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
                setSelectedWorkspaceID(createdWorkspaceID, refreshSnapshot: false)
                syncSelectedTerminalForWorkspace()
                seedCreatedTerminalSnapshot(workspaceID: createdWorkspaceID, terminalID: selectedTerminalID)
            } else {
                syncSelectedTerminalForWorkspace()
            }
            scheduleSelectedTerminalSnapshotRefresh()
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
            var createdTerminalID: MobileTerminalPreview.ID?
            if selectedWorkspaceID == requestedWorkspaceID,
               let createdID = response.createdTerminalID {
                createdTerminalID = MobileTerminalPreview.ID(rawValue: createdID)
                selectedTerminalID = createdTerminalID
            }
            if let createdTerminalID {
                seedCreatedTerminalSnapshot(workspaceID: requestedWorkspaceID, terminalID: createdTerminalID)
            }
            scheduleSelectedTerminalSnapshotRefresh()
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
            connectionError = Self.localizedConnectionError(for: error)
        }
    }

    private func seedCreatedTerminalSnapshot(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID?
    ) {
        guard let terminalID,
              let workspace = workspaces.first(where: { $0.id == workspaceID }),
              let terminal = workspace.terminals.first(where: { $0.id == terminalID }) else {
            return
        }
        replaceTerminalSnapshot(
            workspaceID: workspaceID,
            terminalID: terminalID,
            snapshot: PreviewMobileHost.snapshot(
                terminalID: terminalID.rawValue,
                lines: [
                    "$ cmux ios",
                    "workspace: \(workspace.name)",
                    "terminal: \(terminal.name)",
                ]
            ),
            isReady: true
        )
    }

    private func refreshSelectedTerminalSnapshot() async {
        guard let client = remoteClient,
              let workspace = selectedWorkspace,
              let terminalID = selectedTerminalID?.rawValue else { return }
        let generation = connectionGeneration
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
            guard isCurrentRemoteOperation(client: client, generation: generation) else { return }
            let responseTerminalID = MobileTerminalPreview.ID(rawValue: response.surfaceID ?? terminalID)
            let terminalSnapshot = terminalSnapshotByReusingStylesIfNeeded(
                workspaceID: workspace.id,
                terminalID: responseTerminalID,
                snapshot: response.snapshot,
                fidelity: response.fidelity
            )
            if !terminalSnapshot.reusedStyles && shouldDeferLowerFidelityTerminalSnapshot(
                workspaceID: workspace.id,
                terminalID: responseTerminalID,
                snapshot: response.snapshot,
                fidelity: response.fidelity
            ) {
                scheduleSelectedTerminalSnapshotRefresh()
                return
            }
            if terminalSnapshot.reusedStyles {
                scheduleStyledSnapshotRefreshAfterPlainTextFallback(
                    workspaceID: workspace.id,
                    terminalID: responseTerminalID
                )
            } else {
                clearLowerFidelityDeferralIfSnapshotHasStyledCells(
                    workspaceID: workspace.id,
                    terminalID: responseTerminalID,
                    snapshot: response.snapshot,
                    fidelity: response.fidelity
                )
            }
            replaceTerminalSnapshot(
                workspaceID: workspace.id,
                terminalID: responseTerminalID,
                snapshot: terminalSnapshot.snapshot,
                isReady: true,
                viewportFit: response.viewportFit
            )
            scheduleViewportSettlingRefreshIfNeeded(
                workspaceID: workspace.id,
                terminalID: responseTerminalID,
                viewportFit: response.viewportFit
            )
        } catch {
            let requestedTerminalID = MobileTerminalPreview.ID(rawValue: terminalID)
            guard generation == connectionGeneration else { return }
            guard isStillSelectedTerminal(workspaceID: workspace.id, terminalID: requestedTerminalID) else {
                connectionError = nil
                return
            }
            mobileShellLog.error("terminal snapshot refresh failed: \(String(describing: error), privacy: .private)")
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
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
                let key = viewportKey(
                    workspaceID: workspace.id,
                    terminalID: MobileTerminalPreview.ID(rawValue: terminalID)
                )
                lowerFidelityDeferralRefreshesByTerminalKey[key] = nil
                viewportSettlingRefreshesByTerminalKey[key] = nil
                viewportEchoSettlingKeys.remove(key)
                viewportMatchedEchoByTerminalKey.remove(key)
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
        let generation = connectionGeneration
        let excludedTerminalID = MobileTerminalPreview.ID(rawValue: terminalID)
        guard isStillSelectedTerminal(workspaceID: workspace.id, terminalID: excludedTerminalID) else {
            return false
        }
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
                guard isCurrentRemoteOperation(client: client, generation: generation) else { return false }
                guard isStillSelectedTerminal(workspaceID: workspace.id, terminalID: excludedTerminalID) else {
                    return false
                }
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
                guard generation == connectionGeneration else { return false }
                guard isStillSelectedTerminal(workspaceID: workspace.id, terminalID: excludedTerminalID) else {
                    return false
                }
                if Self.isTerminalSurfaceNotReady(error) {
                    continue
                }
                if disconnectForAuthorizationFailureIfNeeded(error) {
                    return false
                }
                mobileShellLog.error("fallback terminal snapshot failed: \(String(describing: error), privacy: .private)")
                return false
            }
        }
        return false
    }

    private func isStillSelectedTerminal(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) -> Bool {
        selectedWorkspace?.id == workspaceID && selectedTerminalID == terminalID
    }

    private func terminalSnapshotFallbackCandidates(
        preferredWorkspaceID: MobileWorkspacePreview.ID,
        excludingTerminalID: MobileTerminalPreview.ID
    ) -> [MobileTerminalSnapshotCandidate] {
        let candidates = workspaces
            .filter { $0.id == preferredWorkspaceID }
            .flatMap { workspace in
                workspace.terminals.compactMap { terminal -> MobileTerminalSnapshotCandidate? in
                    guard terminal.id != excludingTerminalID else {
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
        let stalePreferred = candidates.filter { !$0.isReady && $0.workspaceID == preferredWorkspaceID }
        return readyPreferred + stalePreferred
    }

    private func terminalSnapshotParams(
        workspaceID: String,
        terminalID: String
    ) -> [String: Any] {
        let terminalID = MobileTerminalPreview.ID(rawValue: terminalID)
        let viewportSize = reportedViewportSizesByTerminalKey[
            viewportKey(
                workspaceID: MobileWorkspacePreview.ID(rawValue: workspaceID),
                terminalID: terminalID
            )
        ]
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
            viewportEchoSettlingKeys.remove(key)
            viewportMatchedEchoByTerminalKey.remove(key)
            lowerFidelityDeferralRefreshesByTerminalKey[key] = max(
                lowerFidelityDeferralRefreshesByTerminalKey[key] ?? 0,
                Self.inputSettlingRefreshCount
            )
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
            _ = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "terminal.input",
                    params: params
                )
            )
            guard isCurrentRemoteOperation(client: client, generation: generation) else { return }
            if selectedWorkspace?.id == workspaceID, selectedTerminalID == terminalID {
                scheduleSelectedTerminalSnapshotRefresh()
            }
        } catch {
            guard generation == connectionGeneration else { return }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
            connectionError = Self.localizedConnectionError(for: error)
        }
    }

    private func scheduleSelectedTerminalSnapshotRefresh(yieldBeforeRefresh: Bool = true) {
        guard remoteClient != nil else { return }
        guard selectedTerminalSnapshotRefreshTask == nil else { return }
        selectedTerminalSnapshotRefreshTask = Task { @MainActor [weak self, yieldBeforeRefresh] in
            if yieldBeforeRefresh {
                await Task.yield()
            }
            guard let self else { return }
            self.selectedTerminalSnapshotRefreshTask = nil
            guard !Task.isCancelled else { return }
            await self.refreshSelectedTerminalSnapshot()
        }
    }

    private func startTerminalRefreshPolling() {
        guard let client = remoteClient else { return }
        guard runtime?.supportsServerPushEvents ?? true else {
            // Server doesn't speak the event subscription protocol. Fall
            // back to the legacy 750 ms poller so the iPhone still catches
            // grid mutations.
            startLegacyTerminalRefreshPolling()
            return
        }
        // Push events make user-driven changes show up immediately. We
        // only spin up the legacy 750 ms `Task.sleep` poller as a fallback
        // when event subscription fails. With events live there are no
        // sleeps on the macOS->iOS render path.
        guard terminalEventListenerTask == nil else { return }
        let listenerID = UUID()
        terminalEventListenerID = listenerID
        terminalEventListenerTask = Task { @MainActor [weak self] in
            defer {
                if self?.terminalEventListenerID == listenerID {
                    self?.terminalEventListenerTask = nil
                    self?.terminalEventListenerID = nil
                }
            }

            let stream = await client.subscribe(to: ["terminal.updated", "workspace.updated"])
            let requestData: Data
            do {
                requestData = try MobileCoreRPCClient.requestData(
                    method: "mobile.events.subscribe",
                    params: ["topics": ["terminal.updated", "workspace.updated"]]
                )
            } catch {
                mobileShellLog.error("subscribe payload encode failed: \(String(describing: error), privacy: .private)")
                return
            }
            let responseData: Data
            do {
                responseData = try await client.sendRequest(requestData)
            } catch let MobileShellConnectionError.rpcError(code, _) where code == "method_not_found" {
                self?.startLegacyTerminalRefreshPolling()
                return
            } catch {
                mobileShellLog.error("subscribe failed, falling back to legacy polling: \(String(describing: error), privacy: .private)")
                self?.startLegacyTerminalRefreshPolling()
                return
            }
            // Require a well-formed subscribe ack ({"stream_id": "..."}) so we
            // don't latch onto a stray response from a Mac that doesn't know
            // about events.v1. Anything else means the request reached an old
            // handler and shouldn't activate the event path.
            let responseObject = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            guard let object = responseObject, (object["stream_id"] as? String)?.isEmpty == false else {
                self?.startLegacyTerminalRefreshPolling()
                return
            }
            // Keep the listener alive without keeping the shell store alive.
            for await event in stream {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.remoteClient === client, self.connectionState == .connected else { return }
                if event.topic == "terminal.updated" {
                    guard self.shouldRefreshSelectedTerminal(for: event) else {
                        continue
                    }
                    await self.refreshSelectedTerminalSnapshot()
                } else if event.topic == "workspace.updated" {
                    self.scheduleWorkspaceListRefreshFromEvent()
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
              isSignedIn else {
            return
        }
        mobileShellLog.info("terminal event stream ended, falling back to legacy polling")
        startLegacyTerminalRefreshPolling()
        if connectionState == .connected {
            scheduleSelectedTerminalSnapshotRefresh(yieldBeforeRefresh: false)
        }
    }

    private func shouldRefreshSelectedTerminal(for event: MobileEventEnvelope) -> Bool {
        guard let eventSurfaceID = Self.surfaceID(from: event) else {
            return true
        }
        return selectedTerminalID?.rawValue == eventSurfaceID
    }

    private static func surfaceID(from event: MobileEventEnvelope) -> String? {
        guard let payloadJSON = event.payloadJSON,
              let payload = try? JSONSerialization.jsonObject(with: payloadJSON) as? [String: Any],
              let surfaceID = payload["surface_id"] as? String else {
            return nil
        }
        let trimmed = surfaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

    private func startLegacyTerminalRefreshPolling() {
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
        terminalEventListenerTask?.cancel()
        terminalEventListenerTask = nil
        terminalEventListenerID = nil
    }

    private func cancelSelectedTerminalSnapshotRefresh() {
        selectedTerminalSnapshotRefreshTask?.cancel()
        selectedTerminalSnapshotRefreshTask = nil
    }

    private func scheduleViewportSettlingRefreshIfNeeded(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        viewportFit: MobileTerminalViewportFit?
    ) {
        let key = viewportKey(workspaceID: workspaceID, terminalID: terminalID)
        guard let remaining = viewportSettlingRefreshesByTerminalKey[key],
              remaining > 0 else {
            viewportSettlingRefreshesByTerminalKey[key] = nil
            viewportEchoSettlingKeys.remove(key)
            viewportMatchedEchoByTerminalKey.remove(key)
            return
        }

        let reportedViewportSize = reportedViewportSizesByTerminalKey[key]
        if viewportEchoSettlingKeys.contains(key),
           let reportedViewportSize,
           viewportFit?.client == reportedViewportSize {
            guard viewportMatchedEchoByTerminalKey.contains(key) else {
                viewportMatchedEchoByTerminalKey.insert(key)
                scheduleSelectedTerminalSnapshotRefresh()
                return
            }
            viewportSettlingRefreshesByTerminalKey[key] = nil
            viewportEchoSettlingKeys.remove(key)
            viewportMatchedEchoByTerminalKey.remove(key)
            return
        }
        viewportMatchedEchoByTerminalKey.remove(key)
        viewportSettlingRefreshesByTerminalKey[key] = remaining - 1
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
                ?? workspaces.first?.id,
            refreshSnapshot: false
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
                terminal.snapshot = existingTerminal.snapshot
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

    private func shouldDeferLowerFidelityTerminalSnapshot(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        snapshot: MobileTerminalGhosttySnapshot,
        fidelity: String?
    ) -> Bool {
        guard fidelity == "plain_text",
              !snapshot.hasExplicitCellStyles,
              let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let terminalIndex = workspaces[workspaceIndex].terminals.firstIndex(where: { $0.id == terminalID }),
              workspaces[workspaceIndex].terminals[terminalIndex].snapshot.hasExplicitCellStyles else {
            return false
        }

        let key = viewportKey(workspaceID: workspaceID, terminalID: terminalID)
        let lowerFidelityRemainingRefreshes = lowerFidelityDeferralRefreshesByTerminalKey[key] ?? 0
        let viewportRemainingRefreshes = viewportSettlingRefreshesByTerminalKey[key] ?? 0
        guard lowerFidelityRemainingRefreshes > 0 || viewportRemainingRefreshes > 0 else {
            return false
        }
        if lowerFidelityRemainingRefreshes > 0 {
            lowerFidelityDeferralRefreshesByTerminalKey[key] = lowerFidelityRemainingRefreshes - 1
        }
        if viewportRemainingRefreshes > 0 {
            viewportSettlingRefreshesByTerminalKey[key] = viewportRemainingRefreshes - 1
        }
        let remainingRefreshes = max(
            lowerFidelityRemainingRefreshes - 1,
            viewportRemainingRefreshes - 1
        )
        mobileShellLog.info("deferred lower fidelity terminal snapshot workspace=\(workspaceID.rawValue, privacy: .private) terminal=\(terminalID.rawValue, privacy: .private) remaining=\(remainingRefreshes, privacy: .public)")
        return true
    }

    private func terminalSnapshotByReusingStylesIfNeeded(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        snapshot: MobileTerminalGhosttySnapshot,
        fidelity: String?
    ) -> (snapshot: MobileTerminalGhosttySnapshot, reusedStyles: Bool) {
        guard fidelity == "plain_text",
              !snapshot.hasExplicitCellStyles,
              let previousSnapshot = terminalSnapshot(workspaceID: workspaceID, terminalID: terminalID),
              previousSnapshot.hasExplicitCellStyles else {
            return (snapshot, false)
        }

        let styledSnapshot = snapshot.reusingExplicitCellStyles(from: previousSnapshot)
        return (styledSnapshot, styledSnapshot != snapshot)
    }

    private func terminalSnapshot(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) -> MobileTerminalGhosttySnapshot? {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let terminalIndex = workspaces[workspaceIndex].terminals.firstIndex(where: { $0.id == terminalID }) else {
            return nil
        }
        return workspaces[workspaceIndex].terminals[terminalIndex].snapshot
    }

    private func scheduleStyledSnapshotRefreshAfterPlainTextFallback(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) {
        let key = viewportKey(workspaceID: workspaceID, terminalID: terminalID)
        let lowerFidelityRemainingRefreshes = max(0, (lowerFidelityDeferralRefreshesByTerminalKey[key] ?? 0) - 1)
        let viewportRemainingRefreshes = max(0, (viewportSettlingRefreshesByTerminalKey[key] ?? 0) - 1)
        if lowerFidelityRemainingRefreshes > 0 {
            lowerFidelityDeferralRefreshesByTerminalKey[key] = lowerFidelityRemainingRefreshes
        } else {
            lowerFidelityDeferralRefreshesByTerminalKey[key] = nil
        }
        if viewportRemainingRefreshes > 0 {
            viewportSettlingRefreshesByTerminalKey[key] = viewportRemainingRefreshes
        } else {
            viewportSettlingRefreshesByTerminalKey[key] = nil
        }

        let remainingRefreshes = max(lowerFidelityRemainingRefreshes, viewportRemainingRefreshes)
        guard remainingRefreshes > 0 else {
            return
        }
        mobileShellLog.info("accepted style-preserved lower fidelity terminal snapshot workspace=\(workspaceID.rawValue, privacy: .private) terminal=\(terminalID.rawValue, privacy: .private) remaining=\(remainingRefreshes, privacy: .public)")
        scheduleSelectedTerminalSnapshotRefresh()
    }

    private func clearLowerFidelityDeferralIfSnapshotHasStyledCells(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        snapshot: MobileTerminalGhosttySnapshot,
        fidelity: String?
    ) {
        guard fidelity != "plain_text" || snapshot.hasExplicitCellStyles else {
            return
        }
        let key = viewportKey(workspaceID: workspaceID, terminalID: terminalID)
        lowerFidelityDeferralRefreshesByTerminalKey[key] = nil
    }

    private static func isTerminalSurfaceNotReady(_ error: Error) -> Bool {
        guard case let MobileShellConnectionError.rpcError(_, message) = error else {
            return false
        }
        return message.localizedCaseInsensitiveContains("surface is not ready")
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

private enum MobileShellConnectionError: LocalizedError {
    case invalidResponse
    case connectionClosed
    case requestTimedOut
    case insecureManualRoute
    case attachTicketExpired
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
        case .attachTicketExpired:
            return "Mobile attach ticket expired"
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
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: nil,
            macDeviceID: payload.macDeviceID,
            macDisplayName: payload.macDisplayName,
            routes: [route],
            expiresAt: payload.expiresAt
        )
        try ticket.validate()
        return ticket
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

final class MobileCoreRPCClient: @unchecked Sendable {
    private let runtime: CMUXMobileRuntime
    private let route: CmxAttachRoute
    private let ticket: CmxAttachTicket
    private let allowsStackAuthFallback: Bool
    private let session: MobileCoreRPCSession

    init(
        runtime: CMUXMobileRuntime,
        route: CmxAttachRoute,
        ticket: CmxAttachTicket,
        allowsStackAuthFallback: Bool = false
    ) {
        self.runtime = runtime
        self.route = route
        self.ticket = ticket
        self.allowsStackAuthFallback = allowsStackAuthFallback
        self.session = MobileCoreRPCSession(
            makeTransport: { [route, runtime] in
                try runtime.transportFactory.makeTransport(for: route)
            }
        )
    }

    /// Tear down the persistent transport (called when the client is
    /// replaced or the user signs out).
    func disconnect() async {
        await session.tearDown(error: .connectionClosed)
    }

    /// Subscribe to server-pushed events. Returns a stream of envelopes
    /// matching any of the requested topics. Cancel by terminating iteration.
    func subscribe(to topics: Set<String>) async -> AsyncStream<MobileEventEnvelope> {
        await session.addEventListener(topics: topics).stream
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

    func sendRequest(_ requestData: Data, timeoutNanoseconds: UInt64? = nil) async throws -> Data {
        // Multiplexed over a persistent transport: each request gets a unique
        // id, the session's reader task routes the response back here. No
        // connect/close per RPC, no head-of-line blocking between calls.
        let (id, augmented) = try Self.requestWithGuaranteedID(requestData)
        let authenticated = try await requestDataWithAuth(augmented)
        return try await Self.withRequestTimeout(
            timeoutNanoseconds: timeoutNanoseconds ?? runtime.rpcRequestTimeoutNanoseconds
        ) {
            try await self.session.send(payload: authenticated, requestID: id)
        }
    }

    private static func requestWithGuaranteedID(_ requestData: Data) throws -> (String, Data) {
        guard var dict = try JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
            throw MobileShellConnectionError.invalidResponse
        }
        let id: String
        if let existing = dict["id"] as? String, !existing.isEmpty {
            id = existing
        } else {
            id = UUID().uuidString
            dict["id"] = id
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return (id, data)
    }

    private func requestDataWithAuth(_ requestData: Data) async throws -> Data {
        guard var request = try JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
            return requestData
        }
        let requestNeedsAuth = Self.requestRequiresAuth(request)
        let requestIsCoveredByAttachTicket = !Self.requestNeedsStackAuthFallback(request, ticket: ticket)
        var auth: [String: Any] = [:]
        let attachToken = ticket.authToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttachToken = attachToken?.isEmpty == false
        if let attachToken,
           requestNeedsAuth,
           hasAttachToken,
           requestIsCoveredByAttachTicket {
            if ticket.expiresAt > runtime.now() {
                auth["attach_token"] = attachToken
            } else if !allowsStackAuthFallback || !MobileShellRouteAuthPolicy.routeAllowsStackAuth(route) {
                throw MobileShellConnectionError.attachTicketExpired
            }
        }
        let shouldSendStackAuth = requestNeedsAuth && auth["attach_token"] == nil
        if shouldSendStackAuth {
            guard allowsStackAuthFallback,
                  MobileShellRouteAuthPolicy.routeAllowsStackAuth(route) else {
                throw MobileShellConnectionError.insecureManualRoute
            }
            do {
                auth["stack_access_token"] = try await runtime.stackAccessTokenProvider()
            } catch {
                throw MobileShellConnectionError.authorizationFailed(
                    L10n.string(
                        "mobile.pairing.stackAuthTokenUnavailable",
                        defaultValue: "Sign in on your computer with the same account, then try again."
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
        let workspaceSelection = stringParamSelection(params, keys: ["workspace_id"])
        let terminalSelection = stringParamSelection(params, keys: ["surface_id", "terminal_id", "tab_id"])
        if workspaceSelection.hasConflict ||
            terminalSelection.hasConflict ||
            containsIgnoredAliasParameters(params) {
            return true
        }

        switch method {
        case "mobile.workspace.list", "workspace.list":
            return false
        case "workspace.create":
            return false
        case "mobile.terminal.create", "terminal.create":
            return false
        case "mobile.terminal.snapshot", "terminal.snapshot",
             "mobile.terminal.input", "terminal.input":
            return !ticketCoversTerminalRequest(
                ticket: ticket,
                workspaceSelection: workspaceSelection.value,
                terminalSelection: terminalSelection.value
            )
        case "mobile.events.subscribe", "mobile.events.unsubscribe":
            return false
        default:
            return true
        }
    }

    private static func requestRequiresAuth(_ request: [String: Any]) -> Bool {
        let method = (request["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return method != "mobile.host.status"
    }

    private static func ticketCoversTerminalRequest(
        ticket: CmxAttachTicket,
        workspaceSelection: String?,
        terminalSelection: String?
    ) -> Bool {
        let ticketWorkspaceID = ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty workspaceID means the ticket is Mac-wide (general pairing).
        // It covers any workspace/terminal on the paired Mac.
        if ticketWorkspaceID.isEmpty {
            return true
        }
        if let workspaceSelection, workspaceSelection != ticketWorkspaceID {
            return false
        }

        if let ticketTerminalID = ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ticketTerminalID.isEmpty {
            return terminalSelection == ticketTerminalID
        }

        return workspaceSelection == ticketWorkspaceID
    }

    private static func containsIgnoredAliasParameters(_ params: [String: Any]) -> Bool {
        params["workspaceID"] != nil || params["terminalID"] != nil
    }

    private static func stringParamSelection(
        _ params: [String: Any],
        keys: [String]
    ) -> StringParamSelection {
        var selected: String?
        for key in keys {
            if let value = params[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if let selected, selected != trimmed {
                        return StringParamSelection(value: selected, hasConflict: true)
                    }
                    selected = selected ?? trimmed
                }
            }
        }
        return StringParamSelection(value: selected, hasConflict: false)
    }

    private struct StringParamSelection {
        let value: String?
        let hasConflict: Bool
    }

    private static func withRequestTimeout<T: Sendable>(
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw MobileShellConnectionError.requestTimedOut
            }
            do {
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}

#if DEBUG
extension MobileCoreRPCClient {
    static func debugWithRequestTimeout<T: Sendable>(
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withRequestTimeout(
            timeoutNanoseconds: timeoutNanoseconds,
            operation: operation
        )
    }
}
#endif

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
    let fidelity: String?
    let viewportFit: MobileTerminalViewportFit?

    private enum CodingKeys: String, CodingKey {
        case snapshot
        case surfaceID = "surface_id"
        case fidelity
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

// MARK: - MobileCoreRPCSession

/// One server-pushed event delivered over the persistent transport.
public struct MobileEventEnvelope: Sendable {
    public let topic: String
    public let payloadJSON: Data?
    public let streamID: String?
}

/// Owns a single persistent transport for a `MobileCoreRPCClient`, multiplexes
/// requests by id, and dispatches server-pushed events to registered listeners.
/// No polling: the reader task runs continuously, parking on `transport.receive()`
/// until the kernel delivers bytes. There is no `Task.sleep` or `asyncAfter`
/// anywhere in this class; the only Task.sleep elsewhere in the file is the
/// race-deadline in `withRequestTimeout`.
private actor MobileCoreRPCSession {
    typealias TransportFactory = @Sendable () throws -> any CmxByteTransport
    typealias PendingContinuation = CheckedContinuation<Result<Data, MobileShellConnectionError>, Never>

    struct EventSubscription {
        let id: UUID
        let stream: AsyncStream<MobileEventEnvelope>
    }

    private struct EventListener {
        let topics: Set<String>
        let continuation: AsyncStream<MobileEventEnvelope>.Continuation
    }

    private struct PendingWrite: Sendable {
        let requestID: String
        let frame: Data
    }

    private let makeTransport: TransportFactory
    private var transport: (any CmxByteTransport)?
    private var connectionTask: (id: UUID, task: Task<any CmxByteTransport, Error>)?
    private var installedConnectionID: UUID?
    private var readerTask: Task<Void, Never>?
    private var pending: [String: PendingContinuation] = [:]
    private var queuedRequestIDs: Set<String> = []
    private var cancelledQueuedRequestIDs: Set<String> = []
    private var listeners: [UUID: EventListener] = [:]
    private var isTearingDown: Bool = false
    /// Pending writes drained by `writerTask`. Serializes `transport.send` so
    /// two concurrent `send(payload:requestID:)` callers never trip
    /// `CmxNetworkByteTransport.sendAlreadyInProgress`. AsyncStream backed so
    /// the writer parks on `await` instead of polling.
    private var writeQueue: AsyncStream<PendingWrite>.Continuation?
    private var writerTask: Task<Void, Never>?

    init(makeTransport: @escaping TransportFactory) {
        self.makeTransport = makeTransport
    }

    deinit {
        connectionTask?.task.cancel()
        readerTask?.cancel()
        writerTask?.cancel()
        writeQueue?.finish()
    }

    func send(payload: Data, requestID: String) async throws -> Data {
        _ = try await ensureConnected()
        let frame = try MobileSyncFrameCodec.encodeFrame(payload)

        let result: Result<Data, MobileShellConnectionError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Register BEFORE handing the frame to the writer so a fast
                // response can't race past us. Writer pulls frames serially
                // from `writeQueue`, so concurrent senders never overlap a
                // `transport.send()` call.
                pending[requestID] = continuation
                guard let queue = writeQueue else {
                    pending.removeValue(forKey: requestID)
                    continuation.resume(returning: .failure(.connectionClosed))
                    return
                }
                queuedRequestIDs.insert(requestID)
                _ = queue.yield(PendingWrite(requestID: requestID, frame: frame))
            }
        } onCancel: {
            Task {
                await self.cancelPendingRequest(requestID: requestID)
            }
        }
        switch result {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        }
    }

    func addEventListener(topics: Set<String>) -> EventSubscription {
        let id = UUID()
        var continuation: AsyncStream<MobileEventEnvelope>.Continuation!
        let stream = AsyncStream<MobileEventEnvelope>(bufferingPolicy: .bufferingNewest(256)) { cont in
            continuation = cont
        }
        listeners[id] = EventListener(topics: topics, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeListener(id: id) }
        }
        return EventSubscription(id: id, stream: stream)
    }

    func removeListener(id: UUID) {
        listeners.removeValue(forKey: id)
    }

    func tearDown(error: MobileShellConnectionError) async {
        guard !isTearingDown else { return }
        isTearingDown = true
        let pendingSnapshot = pending
        pending.removeAll()
        queuedRequestIDs.removeAll()
        cancelledQueuedRequestIDs.removeAll()
        for (_, cont) in pendingSnapshot {
            cont.resume(returning: .failure(error))
        }
        let listenerSnapshot = listeners
        listeners.removeAll()
        for (_, listener) in listenerSnapshot {
            listener.continuation.finish()
        }
        // Stop the writer loop before closing the transport so we don't try to
        // write into a half-closed socket and never trigger
        // sendAlreadyInProgress on a torn-down state.
        writeQueue?.finish()
        writeQueue = nil
        writerTask?.cancel()
        writerTask = nil
        connectionTask?.task.cancel()
        connectionTask = nil
        installedConnectionID = nil
        if let transport {
            await transport.close()
        }
        transport = nil
        readerTask?.cancel()
        readerTask = nil
        isTearingDown = false
    }

    // MARK: - private

    private func ensureConnected() async throws -> any CmxByteTransport {
        if let transport { return transport }

        let connectionID: UUID
        let task: Task<any CmxByteTransport, Error>
        if let existing = connectionTask {
            connectionID = existing.id
            task = existing.task
        } else {
            let candidate = try makeTransport()
            connectionID = UUID()
            task = Task {
                try await candidate.connect()
                return candidate
            }
            connectionTask = (id: connectionID, task: task)
        }

        let candidate: any CmxByteTransport
        do {
            candidate = try await task.value
        } catch {
            if connectionTask?.id == connectionID {
                connectionTask = nil
            }
            throw error
        }

        if let transport {
            if installedConnectionID != connectionID {
                await candidate.close()
            }
            return transport
        }

        guard connectionTask?.id == connectionID else {
            await candidate.close()
            throw MobileShellConnectionError.connectionClosed
        }

        connectionTask = nil
        installedConnectionID = connectionID
        transport = candidate
        // Reader: dispatches inbound frames by id (response) or topic (event).
        readerTask = Task { [weak self] in
            await self?.readLoop(transport: candidate)
        }
        // Writer: drains queued frames one at a time so concurrent send()
        // callers don't trigger CmxNetworkByteTransport.sendAlreadyInProgress.
        // Failures tear the whole session down which fails every pending
        // continuation.
        let (stream, continuation) = AsyncStream<PendingWrite>.makeStream(bufferingPolicy: .unbounded)
        writeQueue = continuation
        writerTask = Task { [weak self] in
            await self?.writeLoop(transport: candidate, frames: stream)
        }
        return candidate
    }

    private func writeLoop(transport: any CmxByteTransport, frames: AsyncStream<PendingWrite>) async {
        for await write in frames {
            if Task.isCancelled { return }
            guard shouldSendQueuedWrite(requestID: write.requestID) else {
                continue
            }
            do {
                try await transport.send(write.frame)
            } catch {
                await tearDown(error: .connectionClosed)
                return
            }
        }
    }

    private func readLoop(transport: any CmxByteTransport) async {
        var buffer = Data()
        while !Task.isCancelled {
            let chunk: Data?
            do {
                chunk = try await transport.receive()
            } catch {
                await tearDown(error: .connectionClosed)
                return
            }
            guard let chunk, !chunk.isEmpty else {
                if chunk == nil {
                    await tearDown(error: .connectionClosed)
                    return
                }
                continue
            }
            buffer.append(chunk)
            let frames: [Data]
            do {
                frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
            } catch {
                await tearDown(error: .invalidResponse)
                return
            }
            for frame in frames {
                dispatch(frame: frame)
            }
        }
    }

    private func dispatch(frame: Data) {
        let parsed = try? JSONSerialization.jsonObject(with: frame) as? [String: Any]
        guard let envelope = parsed else { return }
        if (envelope["kind"] as? String) == "event" {
            guard let topic = envelope["topic"] as? String else { return }
            let payloadData: Data?
            if let payload = envelope["payload"] {
                payloadData = try? JSONSerialization.data(withJSONObject: payload)
            } else {
                payloadData = nil
            }
            let streamID = envelope["stream_id"] as? String
            let event = MobileEventEnvelope(topic: topic, payloadJSON: payloadData, streamID: streamID)
            for (_, listener) in listeners where listener.topics.contains(topic) {
                listener.continuation.yield(event)
            }
            return
        }
        guard let id = envelope["id"] as? String else { return }
        guard let cont = pending.removeValue(forKey: id) else { return }
        if (envelope["ok"] as? Bool) == true {
            let result = envelope["result"] ?? [:]
            if let data = try? JSONSerialization.data(withJSONObject: result) {
                cont.resume(returning: .success(data))
            } else {
                cont.resume(returning: .failure(.invalidResponse))
            }
            return
        }
        let errorPayload = envelope["error"] as? [String: Any]
        let message = (errorPayload?["message"] as? String) ?? "RPC error"
        let code = errorPayload?["code"] as? String
        if code == "unauthorized" {
            cont.resume(returning: .failure(.authorizationFailed(message)))
        } else {
            cont.resume(returning: .failure(.rpcError(code, message)))
        }
    }

    private func failPending(requestID: String, error: MobileShellConnectionError) {
        guard let cont = pending.removeValue(forKey: requestID) else { return }
        cont.resume(returning: .failure(error))
    }

    private func cancelPendingRequest(requestID: String) {
        guard let cont = pending.removeValue(forKey: requestID) else { return }
        if queuedRequestIDs.remove(requestID) != nil {
            cancelledQueuedRequestIDs.insert(requestID)
        }
        cont.resume(returning: .failure(.requestTimedOut))
    }

    private func shouldSendQueuedWrite(requestID: String) -> Bool {
        let wasQueued = queuedRequestIDs.remove(requestID) != nil
        if cancelledQueuedRequestIDs.remove(requestID) != nil {
            return false
        }
        return wasQueued && pending[requestID] != nil
    }
}
