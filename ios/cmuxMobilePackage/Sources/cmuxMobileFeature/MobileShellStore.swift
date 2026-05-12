import Foundation
import CMUXMobileSyncCore
import Network
import Observation

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

@MainActor
@Observable
public final class CMUXMobileShellStore {
    public private(set) var isSignedIn: Bool
    public private(set) var connectionState: MobileConnectionState
    public private(set) var connectedHostName: String
    public var pairingCode: String
    public var workspaces: [MobileWorkspacePreview]
    public var terminalInputText: String
    public private(set) var connectionError: String?
    public var selectedWorkspaceID: MobileWorkspacePreview.ID? {
        didSet {
            syncSelectedTerminalForWorkspace()
            scheduleSelectedTerminalSnapshotRefresh()
        }
    }
    public var selectedTerminalID: MobileTerminalPreview.ID?
    private var remoteClient: MobileSyncNetworkClient?

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
        isSignedIn: Bool = false,
        connectionState: MobileConnectionState = .disconnected,
        connectedHostName: String = "",
        pairingCode: String = "",
        workspaces: [MobileWorkspacePreview] = []
    ) {
        self.isSignedIn = isSignedIn
        self.connectionState = connectionState
        self.connectedHostName = connectedHostName
        self.pairingCode = pairingCode
        self.workspaces = workspaces
        self.terminalInputText = ""
        self.connectionError = nil
        self.selectedWorkspaceID = workspaces.first?.id
        self.selectedTerminalID = workspaces.first?.terminals.first?.id
        self.remoteClient = nil
    }

    public static func preview() -> CMUXMobileShellStore {
        CMUXMobileShellStore(workspaces: PreviewMobileHost.workspaces)
    }

    public func signIn() {
        isSignedIn = true
    }

    public func signOut() {
        isSignedIn = false
        connectionState = .disconnected
        connectedHostName = ""
        pairingCode = ""
        terminalInputText = ""
        connectionError = nil
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
        connectedHostName = PreviewMobileHost.hostName
        connectionState = .connected
        if selectedWorkspaceID == nil {
            selectedWorkspaceID = workspaces.first?.id
        }
        syncSelectedTerminalForWorkspace()
    }

    public func connectPairingURL(_ rawValue: String? = nil) async {
        let rawURL = (rawValue ?? pairingCode).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL) else {
            connectionError = MobileShellConnectionError.invalidPairingURL.localizedDescription
            connectionState = .disconnected
            return
        }

        do {
            let payload = try MobileSyncPairingPayload.decodeURL(url)
            let client = MobileSyncNetworkClient(pairingPayload: payload)
            let request = try MobileSyncNetworkClient.requestData(method: "workspace.list")
            let resultData = try await client.sendRequest(request)
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            remoteClient = client
            connectionError = nil
            connectedHostName = payload.macDisplayName ?? payload.host
            workspaces = response.workspaces.map(MobileWorkspacePreview.init(remote:))
            selectedWorkspaceID = response.workspaces.first(where: \.isSelected)
                .map { MobileWorkspacePreview.ID(rawValue: $0.id) }
                ?? workspaces.first?.id
            syncSelectedTerminalForWorkspace()
            connectionState = .connected
            await refreshSelectedTerminalSnapshot()
        } catch {
            connectionError = error.localizedDescription
            connectionState = .disconnected
            remoteClient = nil
        }
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
                MobileSyncNetworkClient.requestData(method: "workspace.create")
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            applyRemoteWorkspaceList(response)
            if let createdID = response.createdWorkspaceID {
                selectedWorkspaceID = MobileWorkspacePreview.ID(rawValue: createdID)
            }
            syncSelectedTerminalForWorkspace()
            await refreshSelectedTerminalSnapshot()
        } catch {
            connectionError = error.localizedDescription
        }
    }

    private func createRemoteTerminal() async {
        guard let client = remoteClient,
              let workspaceID = selectedWorkspace?.id.rawValue else { return }
        do {
            let resultData = try await client.sendRequest(
                MobileSyncNetworkClient.requestData(
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
            connectionError = error.localizedDescription
        }
    }

    private func refreshSelectedTerminalSnapshot() async {
        guard let client = remoteClient,
              let workspace = selectedWorkspace,
              let terminalID = selectedTerminalID?.rawValue else { return }
        do {
            let resultData = try await client.sendRequest(
                MobileSyncNetworkClient.requestData(
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
            connectionError = error.localizedDescription
        }
    }

    private func sendRemoteTerminalInput(_ text: String) async {
        guard let client = remoteClient,
              let workspace = selectedWorkspace,
              let terminalID = selectedTerminalID?.rawValue else { return }
        do {
            _ = try await client.sendRequest(
                MobileSyncNetworkClient.requestData(
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
            connectionError = error.localizedDescription
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
        workspaces[workspaceIndex].terminals[terminalIndex].snapshot = snapshot
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
}

enum MobileShellConnectionError: LocalizedError {
    case invalidPairingURL
    case invalidResponse
    case connectionClosed
    case rpcError(String)

    var errorDescription: String? {
        switch self {
        case .invalidPairingURL:
            return "Invalid pairing URL"
        case .invalidResponse:
            return "Invalid mobile sync response"
        case .connectionClosed:
            return "Mobile sync connection closed"
        case .rpcError(let message):
            return message
        }
    }
}

final class MobileSyncNetworkClient: @unchecked Sendable {
    private let pairingPayload: MobileSyncPairingPayload
    private let queue = DispatchQueue(label: "dev.cmux.mobile-sync.client")

    init(pairingPayload: MobileSyncPairingPayload) {
        self.pairingPayload = pairingPayload
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
        let port = NWEndpoint.Port(rawValue: UInt16(pairingPayload.port))!
        let connection = NWConnection(
            host: NWEndpoint.Host(pairingPayload.host),
            port: port,
            using: .tcp
        )
        try await waitUntilReady(connection)
        defer { connection.cancel() }

        let frame = try MobileSyncFrameCodec.encodeFrame(requestData)
        try await send(frame, on: connection)
        let responseFrame = try await receiveFrame(on: connection)
        return try decodeResultEnvelope(responseFrame)
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: MobileShellConnectionError.connectionClosed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveFrame(on connection: NWConnection) async throws -> Data {
        var buffer = Data()
        while true {
            let chunk = try await receiveChunk(on: connection)
            buffer.append(chunk)
            let frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
            if let frame = frames.first {
                return frame
            }
        }
    }

    private func receiveChunk(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(throwing: MobileShellConnectionError.connectionClosed)
                    return
                }
                continuation.resume(returning: Data())
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

private struct MobileSyncWorkspaceListResponse: Decodable, Sendable {
    struct Workspace: Decodable, Sendable {
        let id: String
        let title: String
        let currentDirectory: String?
        let isSelected: Bool
        let terminals: [Terminal]
    }

    struct Terminal: Decodable, Sendable {
        let id: String
        let title: String
        let currentDirectory: String?
        let isFocused: Bool
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
                        "Mobile Sync: enabled",
                        "Listener: stopped",
                        "Tailscale: available",
                    ]
                ),
                MobileTerminalPreview(
                    id: "terminal-agent",
                    name: "Agent",
                    lines: [
                        "$ git status --short",
                        "## feat-ios-minimal-shell",
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
                        "$ rg \"Tailscale\" docs",
                        "docs/mobile-sync.md:Pairing uses Tailscale only.",
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
