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

    public init(id: ID, name: String, snapshot: MobileTerminalGhosttySnapshot) {
        self.id = id
        self.name = name
        self.snapshot = snapshot
    }

    public init(id: ID, name: String, lines: [String]) {
        self.id = id
        self.name = name
        self.snapshot = PreviewMobileHost.snapshot(
            terminalID: id.rawValue,
            lines: lines
        )
    }

    public var lines: [String] {
        snapshot.scrollbackRows.map(\.trimmedPlainText) + snapshot.renderedVisibleLines
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

    public init(
        supportedRouteKinds: [CmxAttachTransportKind] = [.tailscale, .debugLoopback, .websocket],
        transportFactory: any CmxByteTransportFactory
    ) {
        self.supportedRouteKinds = supportedRouteKinds
        self.transportFactory = transportFactory
    }

    public init(transportFactory: any CmxRouteAwareByteTransportFactory) {
        self.supportedRouteKinds = transportFactory.supportedKinds
        self.transportFactory = transportFactory
    }
}

@MainActor
@Observable
public final class CMUXMobileShellStore {
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
            scheduleSelectedTerminalSnapshotRefresh()
        }
    }
    public var selectedTerminalID: MobileTerminalPreview.ID?

    private let runtime: CMUXMobileRuntime?
    private var remoteClient: MobileCoreRPCClient?

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

    public init(
        runtime: CMUXMobileRuntime? = nil,
        isSignedIn: Bool = false,
        connectionState: MobileConnectionState = .disconnected,
        connectedHostName: String = "",
        pairingCode: String = "",
        workspaces: [MobileWorkspacePreview] = []
    ) {
        self.runtime = runtime
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
    }

    public static func preview(runtime: CMUXMobileRuntime? = nil) -> CMUXMobileShellStore {
        CMUXMobileShellStore(runtime: runtime, workspaces: PreviewMobileHost.workspaces)
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
        workspaces = PreviewMobileHost.workspaces
        selectedWorkspaceID = workspaces.first?.id
        selectedTerminalID = workspaces.first?.terminals.first?.id
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
            return
        }
        guard (1...65535).contains(port) else {
            connectionError = L10n.string("mobile.addDevice.invalidPort", defaultValue: "Enter a port from 1 to 65535.")
            connectionState = .disconnected
            return
        }

        do {
            let routeKind = Self.manualRouteKind(for: normalizedHost)
            let route = try CmxAttachRoute(
                id: routeKind.rawValue,
                kind: routeKind,
                endpoint: .hostPort(host: normalizedHost, port: port)
            )
            let ticket = try CmxAttachTicket(
                workspaceID: "manual-workspace",
                terminalID: nil,
                macDeviceID: "manual-\(normalizedHost):\(port)",
                macDisplayName: trimmedName.isEmpty ? normalizedHost : trimmedName,
                routes: [route],
                expiresAt: Date().addingTimeInterval(60 * 60)
            )
            try await connect(ticket: ticket)
        } catch {
            mobileShellLog.error("manual host pairing failed: \(String(describing: error), privacy: .public)")
            connectionError = L10n.string("mobile.pairing.runtimeUnavailable", defaultValue: "Could not connect to the Mac runtime.")
            connectionState = .disconnected
            remoteClient = nil
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
            remoteClient = nil
            activeTicket = nil
            activeRoute = nil
            return
        }

        do {
            try await connect(ticket: ticket)
        } catch {
            mobileShellLog.error("pairing failed: \(String(describing: error), privacy: .public)")
            connectionError = L10n.string("mobile.pairing.runtimeUnavailable", defaultValue: "Could not connect to the Mac runtime.")
            connectionState = .disconnected
            remoteClient = nil
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

    private static func manualRouteKind(for host: String) -> CmxAttachTransportKind {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedHost == "localhost" ||
            normalizedHost == "::1" ||
            normalizedHost.hasPrefix("127.") {
            return .debugLoopback
        }
        return .tailscale
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

    public func openWorkspace(_ id: MobileWorkspacePreview.ID) async {
        selectedWorkspaceID = id
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
        await sendRemoteTerminalInput(text)
    }

    private func connect(ticket: CmxAttachTicket) async throws {
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        guard let route = ticket.preferredRoute(supportedKinds: supportedKinds) else {
            connectionError = L10n.string("mobile.pairing.unsupportedRoute", defaultValue: "This pairing code uses an unsupported route.")
            connectionState = .disconnected
            return
        }

        activeTicket = ticket
        activeRoute = route
        connectedHostName = ticket.macDisplayName ?? ticket.macDeviceID
        mobileShellLog.info("pairing selected route kind=\(route.kind.rawValue, privacy: .public) endpoint=\(route.endpoint.logDescription, privacy: .public)")

        guard let runtime else {
            remoteClient = nil
            connectionError = nil
            applyPreviewTicket(ticket, route: route)
            connectionState = .connected
            return
        }

        let client = MobileCoreRPCClient(runtime: runtime, route: route)
        let resultData = try await client.sendRequest(
            MobileCoreRPCClient.requestData(method: "workspace.list")
        )
        let response = try MobileSyncWorkspaceListResponse.decode(resultData)
        remoteClient = client
        connectionError = nil
        applyRemoteWorkspaceList(response)
        syncSelectedTerminalForWorkspace()
        connectionState = .connected
        await refreshSelectedTerminalSnapshot()
    }

    private func syncSelectedTerminalForWorkspace() {
        guard let selectedWorkspace else {
            selectedTerminalID = nil
            return
        }
        if let selectedTerminalID,
           selectedWorkspace.terminals.contains(where: { $0.id == selectedTerminalID }) {
            return
        }
        selectedTerminalID = selectedWorkspace.terminals.first?.id
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
                selectedWorkspaceID = MobileWorkspacePreview.ID(rawValue: createdID)
            }
            syncSelectedTerminalForWorkspace()
            await refreshSelectedTerminalSnapshot()
        } catch {
            connectionError = L10n.string("mobile.pairing.runtimeUnavailable", defaultValue: "Could not connect to the Mac runtime.")
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
            applyRemoteWorkspaceList(response)
            if let createdID = response.createdTerminalID {
                selectedTerminalID = MobileTerminalPreview.ID(rawValue: createdID)
            }
            await refreshSelectedTerminalSnapshot()
        } catch {
            connectionError = L10n.string("mobile.pairing.runtimeUnavailable", defaultValue: "Could not connect to the Mac runtime.")
        }
    }

    private func refreshSelectedTerminalSnapshot() async {
        guard let client = remoteClient,
              let workspace = selectedWorkspace,
              let terminalID = selectedTerminalID?.rawValue else { return }
        do {
            mobileShellLog.info("refreshing terminal snapshot workspace=\(workspace.id.rawValue, privacy: .public) terminal=\(terminalID, privacy: .public)")
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "terminal.snapshot",
                    params: [
                        "workspace_id": workspace.id.rawValue,
                        "surface_id": terminalID,
                        "max_scrollback_rows": 500,
                    ]
                )
            )
            let response = try MobileSyncTerminalSnapshotResponse.decode(resultData)
            replaceTerminalSnapshot(
                workspaceID: workspace.id,
                terminalID: MobileTerminalPreview.ID(rawValue: response.surfaceID ?? terminalID),
                snapshot: response.snapshot
            )
        } catch {
            mobileShellLog.error("terminal snapshot refresh failed: \(String(describing: error), privacy: .public)")
            if Self.isTerminalSurfaceNotReady(error) {
                replaceTerminalSnapshot(
                    workspaceID: workspace.id,
                    terminalID: MobileTerminalPreview.ID(rawValue: terminalID),
                    snapshot: PreviewMobileHost.snapshot(
                        terminalID: terminalID,
                        lines: [
                            L10n.string("mobile.terminal.surfaceNotReady", defaultValue: "Terminal surface is still starting."),
                        ]
                    )
                )
                connectionError = nil
                return
            }
            connectionError = L10n.string("mobile.pairing.runtimeUnavailable", defaultValue: "Could not connect to the Mac runtime.")
        }
    }

    private func sendRemoteTerminalInput(_ text: String) async {
        guard let client = remoteClient,
              let workspace = selectedWorkspace,
              let terminalID = selectedTerminalID?.rawValue else { return }
        do {
            _ = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "terminal.input",
                    params: [
                        "workspace_id": workspace.id.rawValue,
                        "surface_id": terminalID,
                        "text": text + "\r",
                    ]
                )
            )
            await refreshSelectedTerminalSnapshot()
        } catch {
            connectionError = L10n.string("mobile.pairing.runtimeUnavailable", defaultValue: "Could not connect to the Mac runtime.")
        }
    }

    private func scheduleSelectedTerminalSnapshotRefresh() {
        guard remoteClient != nil else { return }
        Task { await refreshSelectedTerminalSnapshot() }
    }

    private func applyRemoteWorkspaceList(_ response: MobileSyncWorkspaceListResponse) {
        workspaces = response.workspaces.map(MobileWorkspacePreview.init(remote:))
        if let selectedWorkspaceID,
           workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            return
        }
        selectedWorkspaceID = response.workspaces.first(where: \.isSelected)
            .map { MobileWorkspacePreview.ID(rawValue: $0.id) }
            ?? workspaces.first?.id
    }

    private func replaceTerminalSnapshot(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        snapshot: MobileTerminalGhosttySnapshot
    ) {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let terminalIndex = workspaces[workspaceIndex].terminals.firstIndex(where: { $0.id == terminalID }) else {
            return
        }
        var updatedWorkspaces = workspaces
        updatedWorkspaces[workspaceIndex].terminals[terminalIndex].snapshot = snapshot
        workspaces = updatedWorkspaces
        mobileShellLog.info("replaced terminal snapshot workspace=\(workspaceID.rawValue, privacy: .public) terminal=\(terminalID.rawValue, privacy: .public) rows=\(snapshot.visibleRows.count, privacy: .public)")
    }

    private static func isTerminalSurfaceNotReady(_ error: Error) -> Bool {
        guard case let MobileShellConnectionError.rpcError(message) = error else {
            return false
        }
        return message.localizedCaseInsensitiveContains("surface is not ready")
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

private enum MobileShellConnectionError: LocalizedError {
    case invalidResponse
    case connectionClosed
    case rpcError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid mobile sync response"
        case .connectionClosed:
            return "Mobile sync connection closed"
        case let .rpcError(message):
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

    init(runtime: CMUXMobileRuntime, route: CmxAttachRoute) {
        self.runtime = runtime
        self.route = route
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
            try await transport.connect()
            let frame = try MobileSyncFrameCodec.encodeFrame(requestData)
            try await transport.send(frame)
            let responseFrame = try await receiveFrame(from: transport)
            await transport.close()
            return try decodeResultEnvelope(responseFrame)
        } catch {
            await transport.close()
            throw error
        }
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
            throw MobileShellConnectionError.rpcError(message)
        }
        throw MobileShellConnectionError.invalidResponse
    }
}

private extension CmxAttachEndpoint {
    var logDescription: String {
        switch self {
        case let .hostPort(host, port):
            "\(host):\(port)"
        case let .peer(id, relayHint):
            "peer:\(id):\(relayHint ?? "no-relay")"
        case let .url(url):
            url
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

        private enum CodingKeys: String, CodingKey {
            case id
            case title
            case currentDirectory = "current_directory"
            case isFocused = "is_focused"
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

    private enum CodingKeys: String, CodingKey {
        case snapshot
        case surfaceID = "surface_id"
    }

    static func decode(_ data: Data) throws -> MobileSyncTerminalSnapshotResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: data)
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
            ]
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
