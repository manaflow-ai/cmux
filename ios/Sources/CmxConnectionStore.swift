import Foundation
import Network
import UIKit

@MainActor
final class CmxConnectionStore: ObservableObject {
    private static let placeholderTerminalID = UInt64.max

    @Published var ticketText = ""
    @Published private(set) var ticket: CmxBridgeTicket?
    @Published private(set) var errorText: String?
    @Published private(set) var isConnecting = false
    @Published private(set) var isConnected = false
    @Published private(set) var stackAuthSession: CmxStackAuthSession?
    @Published private(set) var terminalAppearanceRevision = 0
    @Published var nodes = CmxDemoState.nodes
    @Published var workspaces = CmxDemoState.workspaces
    @Published private(set) var nativeSnapshot: CmxNativeSnapshot?
    @Published var selectedWorkspaceID: UInt64 = CmxDemoState.workspaces[0].id
    @Published var selectedSpaceID: UInt64 = CmxDemoState.workspaces[0].spaces[0].id
    @Published var selectedTerminalID: UInt64 = CmxDemoState.workspaces[0].spaces[0].terminals[0].id
    @Published private var outputChunksByTerminalID: [UInt64: [CmxTerminalOutputChunk]] = [:]
    @Published private var nextOutputChunkID = 1
    private let authSessionStore: CmxStackAuthSessionStore
    private let pairingSecretClient: CmxRivetPairingSecretFetching
    private let terminalSessionFactory: any CmxTerminalSessionMaking
    private var terminalSession: (any CmxTerminalSession)?
    private var connectTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "dev.cmux.ios.connection.path")
    private var hasUsableNetworkPath = true
    private var appIsActive = true
    private var reconnectAllowed = false
    private var reconnectPending = false
    private var didUseImmediateReconnectForCurrentLoss = false

    init(
        authSessionStore: CmxStackAuthSessionStore = CmxKeychainStackAuthSessionStore(),
        pairingSecretClient: CmxRivetPairingSecretFetching = CmxRivetPairingSecretClient(),
        terminalSessionFactory: any CmxTerminalSessionMaking = CmxDefaultTerminalSessionFactory()
    ) {
        self.authSessionStore = authSessionStore
        self.pairingSecretClient = pairingSecretClient
        self.terminalSessionFactory = terminalSessionFactory
        stackAuthSession = try? authSessionStore.load()
        if let ticket = CmxLaunchConfiguration.ticket() {
            ticketText = ticket
        }
        seedTerminalOutput()
        startLifecycleObservers()
        if CmxLaunchConfiguration.shouldAutoconnect() {
            Task { @MainActor [weak self] in
                self?.connect()
            }
        }
    }

    deinit {
        pathMonitor?.cancel()
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

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

    func connect() {
        connect(isAutomaticReconnect: false)
    }

    private func connect(isAutomaticReconnect: Bool) {
        do {
            let rawTicket = ticketText.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = try CmxBridgeTicketParser.parse(rawTicket)
            reconnectAllowed = true
            reconnectPending = false
            if !isAutomaticReconnect {
                didUseImmediateReconnectForCurrentLoss = false
            }
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
            reconnectAllowed = false
            reconnectPending = false
            terminalSession?.disconnect()
            terminalSession = nil
            ticket = nil
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
        } catch {
            errorText = error.localizedDescription
        }
    }

    func signOut() {
        do {
            try authSessionStore.clear()
            stackAuthSession = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    func disconnect() {
        reconnectAllowed = false
        reconnectPending = false
        connectTask?.cancel()
        connectTask = nil
        terminalSession?.disconnect()
        terminalSession = nil
        isConnecting = false
        isConnected = false
    }

    func select(workspace: CmxWorkspace) {
        selectedWorkspaceID = workspace.id
        if let firstSpace = workspace.spaces.first {
            selectedSpaceID = firstSpace.id
        }
        selectedTerminalID = firstTerminalID(in: workspace) ?? Self.placeholderTerminalID
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            terminalSession?.sendCommand(.selectWorkspace(index: index))
        }
        syncNativeLayoutForVisibleTerminal()
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
        syncNativeLayoutForVisibleTerminal()
    }

    func select(terminal: CmxTerminal) {
        selectedTerminalID = terminal.id
        if let selection = nativeSnapshot?.panels.selection(for: terminal.id) {
            terminalSession?.sendCommand(.selectTabInPanel(panelID: selection.panelID, index: selection.index))
        }
        syncNativeLayoutForVisibleTerminal()
    }

    func node(for workspace: CmxWorkspace) -> CmxHiveNode {
        nodes.first(where: { $0.id == workspace.nodeID }) ?? CmxHiveNode(
            id: 0,
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

    func visibleWorkspaces(matching query: String) -> [CmxWorkspace] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = workspaces.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned {
                return lhs.pinned && !rhs.pinned
            }
            return lhs.lastActivity > rhs.lastActivity
        }
        guard !trimmed.isEmpty else { return sorted }
        return sorted.filter { workspace in
            let node = node(for: workspace)
            return workspace.title.localizedCaseInsensitiveContains(trimmed)
                || workspace.preview.localizedCaseInsensitiveContains(trimmed)
                || node.name.localizedCaseInsensitiveContains(trimmed)
                || node.subtitle.localizedCaseInsensitiveContains(trimmed)
                || workspace.spaces.contains { $0.title.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    func terminalSize(for terminalID: UInt64) -> CmxTerminalSize {
        terminal(matching: terminalID)?.size ?? .phoneDefault
    }

    func outputChunks(for terminalID: UInt64) -> [CmxTerminalOutputChunk] {
        outputChunksByTerminalID[terminalID] ?? []
    }

    func updateTerminalSize(terminalID: UInt64, size: CmxTerminalSize) {
        guard size.cols > 0, size.rows > 0 else { return }
        for workspaceIndex in workspaces.indices {
            for spaceIndex in workspaces[workspaceIndex].spaces.indices {
                guard let terminalIndex = workspaces[workspaceIndex].spaces[spaceIndex].terminals
                    .firstIndex(where: { $0.id == terminalID }) else { continue }
                if workspaces[workspaceIndex].spaces[spaceIndex].terminals[terminalIndex].size != size {
                    workspaces[workspaceIndex].spaces[spaceIndex].terminals[terminalIndex].size = size
                }
                if terminalID == selectedTerminal.id {
                    terminalSession?.sendResize(wireViewport(for: terminalID), terminalID: terminalID)
                }
                return
            }
        }
    }

    func sendInput(_ data: Data, terminalID: UInt64) {
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

    private func appendOutput(_ data: Data, terminalID: UInt64) {
        let chunk = CmxTerminalOutputChunk(id: nextOutputChunkID, data: data)
        nextOutputChunkID += 1
        outputChunksByTerminalID[terminalID, default: []].append(chunk)
    }

    private func clearTerminal(_ terminalID: UInt64) {
        outputChunksByTerminalID[terminalID] = []
        appendOutput(Data("\u{001B}[2J\u{001B}[H".utf8), terminalID: terminalID)
    }

    func applyNativeSnapshot(_ snapshot: CmxNativeSnapshot) {
        nativeSnapshot = snapshot
        applyTerminalAppearance(from: snapshot, colorPreference: currentColorPreference)
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
                unread: false,
                pinned: workspace.pinned,
                spaces: spaces
            )
        }
        if workspaces.isEmpty {
            workspaces = CmxDemoState.workspaces
        }
        selectedWorkspaceID = workspaces.first(where: { $0.id == snapshot.activeWorkspaceID })?.id
            ?? workspaces.first?.id
            ?? 0
        let selectedWorkspace = selectedWorkspace
        selectedSpaceID = selectedWorkspace.spaces.first(where: { $0.id == snapshot.activeSpaceID })?.id
            ?? selectedWorkspace.spaces.first?.id
            ?? 0
        selectedTerminalID = activeTerminals.first(where: { $0.id == snapshot.focusedTabID })?.id
            ?? activeTerminals.first?.id
            ?? Self.placeholderTerminalID
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

    private func syncNativeLayoutForVisibleTerminal() {
        let terminal = selectedTerminal
        guard terminal.id != Self.placeholderTerminalID else { return }
        terminalSession?.sendNativeLayout([
            CmxWireTerminalViewport(
                tabID: terminal.id,
                cols: UInt16(clamping: terminal.size.cols),
                rows: UInt16(clamping: terminal.size.rows)
            ),
        ])
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
        terminalSession?.disconnect()
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
        clearTerminal(selectedTerminal.id)
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
        let title = "\(esc)[1;36m\(terminal.title)\(esc)[0m"
        let rows = terminal.rows.enumerated().map { index, row in
            if index == 0 {
                return "\(esc)[32m\(row)\(esc)[0m"
            }
            if row.hasPrefix("$") {
                return "\(esc)[33m\(row)\(esc)[0m"
            }
            return row
        }
        return Data(("\(esc)[2J\(esc)[H\(title)\r\n\r\n" + rows.joined(separator: "\r\n") + "\r\n\r\n\(esc)[32mios$ \(esc)[0m").utf8)
    }

    private func renderEcho(for data: Data) -> Data {
        if data == Data([0x03]) {
            return Data("^C\r\n\u{001B}[32mios$ \u{001B}[0m".utf8)
        }
        if data == Data([0x04]) {
            return Data("^D\r\n\u{001B}[32mios$ \u{001B}[0m".utf8)
        }
        if data == Data([0x0C]) {
            return Data("\u{001B}[2J\u{001B}[H\u{001B}[32mios$ \u{001B}[0m".utf8)
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
            return Data(text.replacingOccurrences(of: "\n", with: "\r\n\u{001B}[32mios$ \u{001B}[0m").utf8)
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
                    self.refreshConnectionForLifecycleSignal()
                }
            }
        }
        pathMonitor = monitor
        monitor.start(queue: pathMonitorQueue)
    }

    private func handleTransportLoss(error: Error? = nil) {
        if let error {
            errorText = error.localizedDescription
        }
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
        switch message {
        case .welcome:
            isConnecting = false
            isConnected = true
            errorText = nil
            reconnectPending = false
            didUseImmediateReconnectForCurrentLoss = false
        case .ptyBytes(let tabID, let data):
            appendOutput(data, terminalID: tabID)
        case .hostControl, .commandReply:
            break
        case .nativeSnapshot(let snapshot):
            applyNativeSnapshot(snapshot)
            syncNativeLayoutForVisibleTerminal()
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
            reconnectAllowed = false
            reconnectPending = false
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

    func terminalSession(_ session: any CmxTerminalSession, didFail error: Error) {
        guard session === terminalSession else { return }
        handleTransportLoss(error: error)
    }

    func terminalSessionDidClose(_ session: any CmxTerminalSession) {
        guard session === terminalSession else { return }
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
