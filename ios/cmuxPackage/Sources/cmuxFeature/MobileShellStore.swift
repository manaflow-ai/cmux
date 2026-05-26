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
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.supportedRouteKinds = supportedRouteKinds
        self.transportFactory = transportFactory
        self.stackAccessTokenProvider = stackAccessTokenProvider ?? Self.defaultStackAccessTokenProvider
        self.rpcRequestTimeoutNanoseconds = rpcRequestTimeoutNanoseconds
        self.pairingRequestTimeoutNanoseconds = pairingRequestTimeoutNanoseconds
        self.now = now
    }

    public init(
        transportFactory: any CmxRouteAwareByteTransportFactory,
        stackAccessTokenProvider: (@Sendable () async throws -> String)? = nil,
        rpcRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultRPCRequestTimeoutNanoseconds,
        pairingRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultPairingRequestTimeoutNanoseconds,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.supportedRouteKinds = transportFactory.supportedKinds
        self.transportFactory = transportFactory
        self.stackAccessTokenProvider = stackAccessTokenProvider ?? Self.defaultStackAccessTokenProvider
        self.rpcRequestTimeoutNanoseconds = rpcRequestTimeoutNanoseconds
        self.pairingRequestTimeoutNanoseconds = pairingRequestTimeoutNanoseconds
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
            return normalizedManualNetworkHost(host) != nil
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
                cancelRemoteOperationTasks()
                lowerFidelityDeferralRefreshesByTerminalKey = [:]
                viewportEchoSettlingKeys = []
                viewportMatchedEchoByTerminalKey = []
            }
        }
    }
    private var terminalRefreshPollTask: Task<Void, Never>?
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
        self.terminalRefreshPollTask = nil
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
        remoteClient = nil
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
        remoteClient = nil
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
        throw MobileShellConnectionError.insecureManualRoute
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
        scheduleSelectedTerminalSnapshotRefresh()
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

        activeTicket = ticket
        activeRoute = firstRoute
        connectedHostName = ticket.macDisplayName ?? ticket.macDeviceID
        remoteClient = nil

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
                    remoteClient = client
                    startTerminalRefreshPolling()
                    connectionError = nil
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
        remoteClient = nil
        rawTerminalInputBuffer.clear()
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
        let transport = try runtime.transportFactory.makeTransport(for: route)
        do {
            let response = try await Self.withRequestTimeout(
                timeoutNanoseconds: timeoutNanoseconds ?? runtime.rpcRequestTimeoutNanoseconds
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
        let requestNeedsAuth = Self.requestRequiresAuth(request)
        let requestIsCoveredByAttachTicket = !Self.requestNeedsStackAuthFallback(request, ticket: ticket)
        var auth: [String: Any] = [:]
        if let authToken = ticket.authToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           requestNeedsAuth,
           !authToken.isEmpty,
           ticket.expiresAt > runtime.now(),
           requestIsCoveredByAttachTicket {
            auth["attach_token"] = authToken
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
        if let workspaceSelection, workspaceSelection != ticket.workspaceID {
            return false
        }

        if let ticketTerminalID = ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ticketTerminalID.isEmpty {
            return terminalSelection == ticketTerminalID
        }

        return workspaceSelection == ticket.workspaceID
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
