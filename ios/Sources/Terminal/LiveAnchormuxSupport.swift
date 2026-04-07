import Foundation
import Network
import SwiftUI
import Darwin

func liveAnchormuxLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    let line = "LIVE_ANCHORMUX \(message())"
    print(line)
    LiveAnchormuxFileLogger.append(line)
    #endif
}

#if DEBUG
private enum LiveAnchormuxFileLogger {
    private static let queue = DispatchQueue(label: "LiveAnchormuxFileLogger")

    static func append(_ line: String) {
        guard ProcessInfo.processInfo.environment["CMUX_LIVE_ANCHORMUX_ENABLED"] == "1" else {
            return
        }

        queue.async {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let timestamp = formatter.string(from: Date())
            let payload = "\(timestamp) pid=\(ProcessInfo.processInfo.processIdentifier) \(line)\n"
            let path = logPath()
            let data = Data(payload.utf8)

            if FileManager.default.fileExists(atPath: path) {
                if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
                return
            }

            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private static func logPath() -> String {
        if let configPath = ProcessInfo.processInfo.environment["CMUX_LIVE_ANCHORMUX_CONFIG_PATH"],
           !configPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let base = URL(fileURLWithPath: configPath).deletingPathExtension().path
            return "\(base)-ios-debug.log"
        }
        return "/tmp/cmux-live-anchormux-ios-debug.log"
    }
}
#endif

struct LiveAnchormuxWorkspaceItem: Equatable, Sendable {
    let workspaceID: String
    let sessionID: String
    let machineID: String
    let title: String
    let preview: String
    let accessoryLabel: String?
    let unreadCount: Int
    let sortDate: Date
    let tailscaleHostname: String?
    let tailscaleIPs: [String]

    fileprivate struct StoredItem: Decodable {
        let workspaceID: String?
        let sessionID: String?
        let machineID: String?
        let title: String?
        let preview: String?
        let accessoryLabel: String?
        let unreadCount: Int?
        let sortDateMs: Int64?
        let tailscaleHostname: String?
        let tailscaleIPs: [String]?

        enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case sessionID = "session_id"
            case machineID = "machine_id"
            case title
            case preview
            case accessoryLabel = "accessory_label"
            case unreadCount = "unread_count"
            case sortDateMs = "sort_date_ms"
            case tailscaleHostname = "tailscale_hostname"
            case tailscaleIPs = "tailscale_ips"
        }
    }

    init(
        workspaceID: String,
        sessionID: String,
        machineID: String,
        title: String,
        preview: String,
        accessoryLabel: String?,
        unreadCount: Int,
        sortDate: Date,
        tailscaleHostname: String?,
        tailscaleIPs: [String]
    ) {
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.machineID = machineID
        self.title = title
        self.preview = preview
        self.accessoryLabel = accessoryLabel
        self.unreadCount = unreadCount
        self.sortDate = sortDate
        self.tailscaleHostname = tailscaleHostname
        self.tailscaleIPs = tailscaleIPs
    }

    fileprivate init?(
        stored: StoredItem,
        defaultMachineID: String
    ) {
        guard let sessionID = stored.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return nil
        }

        let workspaceID = stored.workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? sessionID
        let machineID = stored.machineID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultMachineID
        let title = stored.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = stored.preview?.trimmingCharacters(in: .whitespacesAndNewlines)

        self.init(
            workspaceID: workspaceID.isEmpty ? sessionID : workspaceID,
            sessionID: sessionID,
            machineID: machineID.isEmpty ? defaultMachineID : machineID,
            title: title?.isEmpty == false ? title! : sessionID,
            preview: preview?.isEmpty == false ? preview! : "No recent activity",
            accessoryLabel: stored.accessoryLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
            unreadCount: max(0, stored.unreadCount ?? 0),
            sortDate: Date(timeIntervalSince1970: Double(stored.sortDateMs ?? Int64(Date().timeIntervalSince1970 * 1000)) / 1000),
            tailscaleHostname: stored.tailscaleHostname?.trimmingCharacters(in: .whitespacesAndNewlines),
            tailscaleIPs: stored.tailscaleIPs ?? []
        )
    }

    func inboxItem(teamID: String) -> UnifiedInboxItem {
        UnifiedInboxItem(
            kind: .workspace,
            workspaceID: workspaceID,
            machineID: machineID,
            teamID: teamID,
            title: title,
            preview: preview,
            unreadCount: unreadCount,
            sortDate: sortDate,
            accessoryLabel: accessoryLabel,
            symbolName: "terminal",
            tmuxSessionName: sessionID,
            tailscaleHostname: tailscaleHostname,
            tailscaleIPs: tailscaleIPs
        )
    }
}

struct LiveAnchormuxConfig: Equatable, Sendable {
    let host: String
    let port: UInt16
    let sessionID: String
    let readyToken: String?
    let desktopToken: String?
    let workspaceItems: [LiveAnchormuxWorkspaceItem]
    let autoOpenSessionID: String?
    let configPath: String?

    static let teamID = "live-anchormux"

    private struct StoredConfig: Decodable {
        let host: String?
        let port: UInt16
        let sessionID: String
        let readyToken: String?
        let desktopToken: String?
        let workspaceItems: [LiveAnchormuxWorkspaceItem.StoredItem]?
        let autoOpenSessionID: String?

        enum CodingKeys: String, CodingKey {
            case host
            case port
            case sessionID = "session_id"
            case readyToken = "ready_token"
            case desktopToken = "desktop_token"
            case workspaceItems = "workspace_items"
            case autoOpenSessionID = "auto_open_session_id"
        }
    }

    static func resolveForApp(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Self? {
        #if DEBUG
        guard isEnabled(in: env) else { return nil }
        return resolve(
            env: env,
            fileManager: fileManager,
            requireTokens: false
        )
        #else
        return nil
        #endif
    }

    static func resolveForLiveTest(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Self? {
        resolve(
            env: env,
            fileManager: fileManager,
            requireTokens: true
        )
    }

    static func debugDescription(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String {
        let interestingKeys = env.keys
            .filter { $0.contains("ANCHORMUX") || $0.contains("SIMCTL_CHILD_CMUX_LIVE") }
            .sorted()
        let tempDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let tmpNames = ((try? fileManager.contentsOfDirectory(
            atPath: tempDirectory.path
        )) ?? [])
            .filter { $0.hasPrefix("cmux-live-anchormux-") && $0.hasSuffix(".json") }
            .sorted()
        return "envKeys=\(interestingKeys) tmpFiles=\(tmpNames)"
    }

    private static func resolve(
        env: [String: String],
        fileManager: FileManager,
        requireTokens: Bool
    ) -> Self? {
        if configPath(env: env, fileManager: fileManager) != nil {
            return fromConfigFile(env: env, fileManager: fileManager, requireTokens: requireTokens) ??
                fromEnvironment(env: env, requireTokens: requireTokens)
        }

        return fromEnvironment(env: env, requireTokens: requireTokens) ??
            fromConfigFile(env: env, fileManager: fileManager, requireTokens: requireTokens)
    }

    private static func isEnabled(in env: [String: String]) -> Bool {
        lookup("CMUX_LIVE_ANCHORMUX_ENABLED", in: env) == "1"
    }

    private static func fromEnvironment(
        env: [String: String],
        requireTokens: Bool
    ) -> Self? {
        guard let rawPort = lookup("CMUX_LIVE_ANCHORMUX_PORT", in: env),
              let port = UInt16(rawPort),
              let sessionID = lookup("CMUX_LIVE_ANCHORMUX_SESSION_ID", in: env),
              !sessionID.isEmpty else {
            return nil
        }

        let readyToken = lookup("CMUX_LIVE_ANCHORMUX_READY_TOKEN", in: env)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let desktopToken = lookup("CMUX_LIVE_ANCHORMUX_DESKTOP_TOKEN", in: env)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let autoOpenSessionID = lookup("CMUX_LIVE_ANCHORMUX_AUTO_OPEN_SESSION_ID", in: env)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if requireTokens, (readyToken?.isEmpty != false || desktopToken?.isEmpty != false) {
            return nil
        }

        let host = lookup("CMUX_LIVE_ANCHORMUX_HOST", in: env)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let machineID = lookup("CMUX_LIVE_ANCHORMUX_MACHINE_ID", in: env)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "anchormux-live-desktop"
        let workspaceItems = defaultWorkspaceItems(
            sessionID: sessionID,
            machineID: machineID
        )

        return Self(
            host: host?.isEmpty == false ? host! : "127.0.0.1",
            port: port,
            sessionID: sessionID,
            readyToken: readyToken?.isEmpty == false ? readyToken : nil,
            desktopToken: desktopToken?.isEmpty == false ? desktopToken : nil,
            workspaceItems: workspaceItems,
            autoOpenSessionID: autoOpenSessionID?.isEmpty == false ? autoOpenSessionID : nil,
            configPath: nil
        )
    }

    private static func fromConfigFile(
        env: [String: String],
        fileManager: FileManager,
        requireTokens: Bool
    ) -> Self? {
        guard let path = configPath(env: env, fileManager: fileManager),
              let data = fileManager.contents(atPath: path),
              let stored = try? JSONDecoder().decode(StoredConfig.self, from: data),
              !stored.sessionID.isEmpty else {
            return nil
        }

        if requireTokens, (stored.readyToken?.isEmpty != false || stored.desktopToken?.isEmpty != false) {
            return nil
        }

        let host = stored.host?.trimmingCharacters(in: .whitespacesAndNewlines)
        let machineID = "anchormux-live-desktop"
        let workspaceItems = parsedWorkspaceItems(
            stored.workspaceItems,
            sessionID: stored.sessionID,
            defaultMachineID: machineID
        )
        return Self(
            host: host?.isEmpty == false ? host! : "127.0.0.1",
            port: stored.port,
            sessionID: stored.sessionID,
            readyToken: stored.readyToken?.isEmpty == false ? stored.readyToken : nil,
            desktopToken: stored.desktopToken?.isEmpty == false ? stored.desktopToken : nil,
            workspaceItems: workspaceItems,
            autoOpenSessionID: stored.autoOpenSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
            configPath: path
        )
    }

    private static func configPath(
        env: [String: String],
        fileManager: FileManager
    ) -> String? {
        if let explicitPath = lookup("CMUX_LIVE_ANCHORMUX_CONFIG_PATH", in: env),
           !explicitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicitPath
        }

        let tempDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return urls
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix("cmux-live-anchormux-") && name.hasSuffix(".json")
            }
            .max { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate < rhsDate
            }?
            .path
    }

    private static func lookup(_ key: String, in env: [String: String]) -> String? {
        if let value = env[key] {
            return value
        }
        return env["SIMCTL_CHILD_\(key)"]
    }

    private static func defaultWorkspaceItems(
        sessionID: String,
        machineID: String
    ) -> [LiveAnchormuxWorkspaceItem] {
        [
            LiveAnchormuxWorkspaceItem(
                workspaceID: sessionID,
                sessionID: sessionID,
                machineID: machineID,
                title: sessionID,
                preview: "No recent activity",
                accessoryLabel: String(
                    localized: "terminal.live_anchormux.desktop_label",
                    defaultValue: "Desktop"
                ),
                unreadCount: 0,
                sortDate: .now,
                tailscaleHostname: nil,
                tailscaleIPs: []
            )
        ]
    }

    private static func parsedWorkspaceItems(
        _ storedItems: [LiveAnchormuxWorkspaceItem.StoredItem]?,
        sessionID: String,
        defaultMachineID: String
    ) -> [LiveAnchormuxWorkspaceItem] {
        let parsedItems = (storedItems ?? []).compactMap {
            LiveAnchormuxWorkspaceItem(stored: $0, defaultMachineID: defaultMachineID)
        }
        if !parsedItems.isEmpty {
            return parsedItems.sorted(by: { $0.sortDate > $1.sortDate })
        }
        return defaultWorkspaceItems(
            sessionID: sessionID,
            machineID: defaultMachineID
        )
    }

    func inboxItems() -> [UnifiedInboxItem] {
        workspaceItems
            .map { $0.inboxItem(teamID: Self.teamID) }
            .sorted(by: { $0.sortDate > $1.sortDate })
    }

    func autoOpenInboxItem() -> UnifiedInboxItem? {
        guard let autoOpenSessionID,
              let matchingItem = workspaceItems.first(where: { $0.sessionID == autoOpenSessionID }) else {
            return nil
        }
        return matchingItem.inboxItem(teamID: Self.teamID)
    }
}

final class LiveAnchormuxConfigStore: ObservableObject {
    private static let watcherQueue = DispatchQueue(label: "LiveAnchormuxConfigStore.watcher")

    @Published private(set) var config: LiveAnchormuxConfig

    private let fileManager: FileManager
    private var watchedPath: String?
    private var watchedDescriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?

    init(
        config: LiveAnchormuxConfig,
        fileManager: FileManager = .default
    ) {
        self.config = config
        self.fileManager = fileManager
        installWatcherIfNeeded()
    }

    deinit {
        if let source {
            watchedDescriptor = -1
            source.cancel()
            self.source = nil
        } else if watchedDescriptor >= 0 {
            close(watchedDescriptor)
            watchedDescriptor = -1
        }
    }

    var inboxItems: [UnifiedInboxItem] {
        config.inboxItems()
    }

    func autoOpenInboxItem() -> UnifiedInboxItem? {
        config.autoOpenInboxItem()
    }

    private func installWatcherIfNeeded() {
        guard let configPath = config.configPath,
              configPath != watchedPath else { return }

        if let source {
            watchedDescriptor = -1
            source.cancel()
            self.source = nil
        } else if watchedDescriptor >= 0 {
            close(watchedDescriptor)
            watchedDescriptor = -1
        }

        watchedPath = configPath
        watchedDescriptor = open(configPath, O_EVTONLY)
        guard watchedDescriptor >= 0 else { return }

        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchedDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: Self.watcherQueue
        )
        watcher.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.reloadFromDisk()
            }
        }
        watcher.setCancelHandler { [watchedDescriptor] in
            if watchedDescriptor >= 0 {
                close(watchedDescriptor)
            }
        }
        source = watcher
        watcher.resume()
    }

    private func reloadFromDisk() {
        let reloaded: LiveAnchormuxConfig?
        if let watchedPath {
            reloaded = LiveAnchormuxConfig.resolveForApp(
                env: [
                    "CMUX_LIVE_ANCHORMUX_ENABLED": "1",
                    "CMUX_LIVE_ANCHORMUX_CONFIG_PATH": watchedPath,
                ],
                fileManager: fileManager
            )
        } else {
            reloaded = LiveAnchormuxConfig.resolveForApp(
                fileManager: fileManager
            )
        }
        guard let reloaded else { return }
        if reloaded != config {
            config = reloaded
        }
        installWatcherIfNeeded()
    }

    #if DEBUG
    func reloadFromDiskForTesting() {
        reloadFromDisk()
    }
    #endif
}

private enum LiveTCPDaemonTransportError: LocalizedError {
    case invalidPort(UInt16)
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Invalid live daemon relay port \(port)"
        case .connectionClosed:
            return "Live daemon relay connection closed"
        }
    }
}

protocol LiveTCPDaemonConnection: AnyObject {
    var stateUpdateHandler: ((NWConnection.State) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
    func send(content: Data?, completion: @escaping (NWError?) -> Void)
    func receive(
        minimumIncompleteLength: Int,
        maximumLength: Int,
        completion: @escaping (Data?, Bool, NWError?) -> Void
    )
}

final class NWConnectionLiveTCPDaemonConnection: LiveTCPDaemonConnection {
    var stateUpdateHandler: ((NWConnection.State) -> Void)? {
        get { connection.stateUpdateHandler }
        set { connection.stateUpdateHandler = newValue }
    }

    private let connection: NWConnection

    init(host: String, port: NWEndpoint.Port) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    }

    func start(queue: DispatchQueue) {
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    func send(content: Data?, completion: @escaping (NWError?) -> Void) {
        connection.send(content: content, completion: .contentProcessed(completion))
    }

    func receive(
        minimumIncompleteLength: Int,
        maximumLength: Int,
        completion: @escaping (Data?, Bool, NWError?) -> Void
    ) {
        connection.receive(
            minimumIncompleteLength: minimumIncompleteLength,
            maximumLength: maximumLength
        ) { data, _, isComplete, error in
            completion(data, isComplete, error)
        }
    }
}

actor LiveTCPDaemonTransport: TerminalRemoteDaemonTransport {
    private let connection: any LiveTCPDaemonConnection
    private let queue: DispatchQueue

    private var waitingReadyContinuations: [CheckedContinuation<Void, Error>] = []
    private var waitingLineContinuations: [CheckedContinuation<String, Error>] = []
    private var bufferedData = Data()
    private var bufferedLines: [String] = []
    private var terminalError: Error?
    private var ready = false

    static func connect(host: String, port: UInt16) async throws -> LiveTCPDaemonTransport {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw LiveTCPDaemonTransportError.invalidPort(port)
        }

        let transport = LiveTCPDaemonTransport(
            connection: NWConnectionLiveTCPDaemonConnection(host: host, port: endpointPort)
        )
        try await transport.waitUntilReady()
        return transport
    }

    init(
        connection: any LiveTCPDaemonConnection,
        queue: DispatchQueue = DispatchQueue(label: "LiveAnchormuxSupport.LiveTCPDaemonTransport")
    ) {
        self.connection = connection
        self.queue = queue
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task {
                await self.handle(state: state)
            }
        }
        connection.start(queue: queue)
        Task { [weak self] in
            await self?.receive()
        }
    }

    deinit {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    func writeLine(_ line: String) async throws {
        if let terminalError {
            throw terminalError
        }

        let payload = Data((line + "\n").utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func readLine() async throws -> String {
        if !bufferedLines.isEmpty {
            return bufferedLines.removeFirst()
        }
        if let terminalError {
            throw terminalError
        }

        return try await withCheckedThrowingContinuation { continuation in
            waitingLineContinuations.append(continuation)
        }
    }

    private func waitUntilReady() async throws {
        if ready {
            return
        }
        if let terminalError {
            throw terminalError
        }

        try await withCheckedThrowingContinuation { continuation in
            waitingReadyContinuations.append(continuation)
        }
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            ready = true
            let continuations = waitingReadyContinuations
            waitingReadyContinuations.removeAll()
            continuations.forEach { $0.resume() }
        case .failed(let error):
            finish(with: error)
        case .cancelled:
            finish(with: LiveTCPDaemonTransportError.connectionClosed)
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, isComplete, error in
            guard let self else { return }
            Task {
                await self.handleReceive(data: data, isComplete: isComplete, error: error)
            }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let error {
            finish(with: error)
            return
        }

        if let data, !data.isEmpty {
            bufferedData.append(data)
            while let newlineIndex = bufferedData.firstIndex(of: 0x0A) {
                var lineData = bufferedData.prefix(upTo: newlineIndex)
                bufferedData.removeSubrange(...newlineIndex)
                if lineData.last == 0x0D {
                    lineData.removeLast()
                }
                enqueue(line: String(decoding: lineData, as: UTF8.self))
            }
        }

        if isComplete {
            finish(with: LiveTCPDaemonTransportError.connectionClosed)
            return
        }

        receive()
    }

    private func enqueue(line: String) {
        if !waitingLineContinuations.isEmpty {
            let continuation = waitingLineContinuations.removeFirst()
            continuation.resume(returning: line)
            return
        }
        bufferedLines.append(line)
    }

    private func finish(with error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        let readyContinuations = waitingReadyContinuations
        waitingReadyContinuations.removeAll()
        readyContinuations.forEach { $0.resume(throwing: error) }

        let lineContinuations = waitingLineContinuations
        waitingLineContinuations.removeAll()
        lineContinuations.forEach { $0.resume(throwing: error) }
    }
}

private struct LiveAnchormuxTransportFactory: TerminalTransportFactory {
    let config: LiveAnchormuxConfig

    func makeTransport(
        host: TerminalHost,
        credentials: TerminalSSHCredentials,
        sessionName: String,
        resumeState: TerminalRemoteDaemonResumeState?
    ) -> TerminalTransport {
        LiveAnchormuxFixtureTransport(
            config: config,
            sessionID: sessionName,
            resumeState: resumeState
        )
    }
}

private final class LiveAnchormuxFixtureTransport: @unchecked Sendable, TerminalTransport, TerminalRemoteDaemonResumeStateSnapshotting, TerminalSessionParking {
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)?

    private let config: LiveAnchormuxConfig
    private let sessionID: String
    private let resumeState: TerminalRemoteDaemonResumeState?
    private let readTimeoutMilliseconds: Int
    private let stateQueue = DispatchQueue(label: "LiveAnchormuxSupport.LiveAnchormuxFixtureTransport.state")

    private var activeTransport: TerminalRemoteDaemonSessionTransport?
    private var lastKnownResumeState: TerminalRemoteDaemonResumeState?

    init(
        config: LiveAnchormuxConfig,
        sessionID: String,
        resumeState: TerminalRemoteDaemonResumeState?,
        readTimeoutMilliseconds: Int = 100
    ) {
        self.config = config
        self.sessionID = sessionID
        self.resumeState = resumeState
        self.readTimeoutMilliseconds = readTimeoutMilliseconds
        self.lastKnownResumeState = resumeState
    }

    func connect(initialSize: TerminalGridSize) async throws {
        liveAnchormuxLog(
            "transport.connect host=\(config.host) port=\(config.port) session=\(sessionID) cols=\(initialSize.columns) rows=\(initialSize.rows)"
        )
        let daemonTransport = try await LiveTCPDaemonTransport.connect(
            host: config.host,
            port: config.port
        )
        let sessionTransport = TerminalRemoteDaemonSessionTransport(
            client: TerminalRemoteDaemonClient(transport: daemonTransport),
            command: "true",
            resumeState: resumeStateSnapshot(),

            readTimeoutMilliseconds: readTimeoutMilliseconds
        )

        sessionTransport.eventHandler = { [weak self, weak sessionTransport] event in
            self?.handle(event: event, transport: sessionTransport)
        }

        setActiveTransport(sessionTransport)

        do {
            try await sessionTransport.connect(initialSize: initialSize)
            liveAnchormuxLog("transport.connected session=\(sessionID)")
        } catch {
            _ = clearActiveTransport(matching: sessionTransport)
            liveAnchormuxLog("transport.connect_failed session=\(sessionID) error=\(error)")
            throw error
        }
    }

    func send(_ data: Data) async throws {
        guard let transport = activeTransportSnapshot() else { return }
        liveAnchormuxLog("transport.send session=\(sessionID) bytes=\(data.count)")
        try await transport.send(data)
    }

    func resize(_ size: TerminalGridSize) async {
        guard let transport = activeTransportSnapshot() else { return }
        liveAnchormuxLog("transport.resize session=\(sessionID) cols=\(size.columns) rows=\(size.rows)")
        await transport.resize(size)
    }

    func disconnect() async {
        liveAnchormuxLog("transport.disconnect session=\(sessionID)")
        let transport = clearActiveTransport()
        if let parkingTransport = transport as? TerminalSessionParking {
            await parkingTransport.suspendPreservingSession()
        } else {
            await transport?.disconnect()
        }
        updateResumeState(nil)
    }

    func suspendPreservingSession() async {
        liveAnchormuxLog("transport.suspend session=\(sessionID)")
        let transport = clearActiveTransport()
        if let parkingTransport = transport as? TerminalSessionParking {
            await parkingTransport.suspendPreservingSession()
        } else {
            await transport?.disconnect()
            updateResumeState(nil)
        }
    }

    func remoteDaemonResumeStateSnapshot() -> TerminalRemoteDaemonResumeState? {
        stateQueue.sync { lastKnownResumeState }
    }

    private func handle(
        event: TerminalTransportEvent,
        transport: TerminalRemoteDaemonSessionTransport?
    ) {
        switch event {
        case .connected:
            liveAnchormuxLog("transport.event connected session=\(sessionID)")
        case .output(let data):
            liveAnchormuxLog("transport.event output session=\(sessionID) bytes=\(data.count)")
        case .disconnected(let error):
            liveAnchormuxLog("transport.event disconnected session=\(sessionID) error=\(error ?? "nil")")
        case .notice(let message):
            liveAnchormuxLog("transport.event notice session=\(sessionID) message=\(message)")
        case .trustedHostKey(let hostKey):
            liveAnchormuxLog("transport.event trusted_host_key session=\(sessionID) key=\(hostKey)")
        case .remotePlatform(let platform):
            liveAnchormuxLog("transport.event remote_platform session=\(sessionID) os=\(platform.goOS) arch=\(platform.goArch)")
        }
        if let snapshotting = transport as? TerminalRemoteDaemonResumeStateSnapshotting {
            updateResumeState(snapshotting.remoteDaemonResumeStateSnapshot())
        }

        if case .disconnected = event {
            _ = clearActiveTransport(matching: transport)
        }

        eventHandler?(event)
    }

    private func resumeStateSnapshot() -> TerminalRemoteDaemonResumeState? {
        stateQueue.sync { lastKnownResumeState }
    }

    private func updateResumeState(_ state: TerminalRemoteDaemonResumeState?) {
        stateQueue.sync {
            lastKnownResumeState = state
        }
    }

    private func setActiveTransport(_ transport: TerminalRemoteDaemonSessionTransport) {
        stateQueue.sync {
            activeTransport = transport
        }
    }

    private func activeTransportSnapshot() -> TerminalRemoteDaemonSessionTransport? {
        stateQueue.sync { activeTransport }
    }

    private func clearActiveTransport(
        matching expectedTransport: TerminalRemoteDaemonSessionTransport? = nil
    ) -> TerminalRemoteDaemonSessionTransport? {
        stateQueue.sync {
            if let expectedTransport,
               let activeTransport,
               ObjectIdentifier(activeTransport) != ObjectIdentifier(expectedTransport) {
                return nil
            }

            let snapshot = activeTransport
            activeTransport = nil
            return snapshot
        }
    }
}

struct LiveAnchormuxFixtureView: View {
    private static let navigationTitle = String(
        localized: "terminal.live_anchormux.navigation_title",
        defaultValue: "Workspaces"
    )
    private static let emptyTitle = String(
        localized: "terminal.live_anchormux.empty_title",
        defaultValue: "No desktop workspaces"
    )
    private static let emptyDescription = String(
        localized: "terminal.live_anchormux.empty_description",
        defaultValue: "Open a desktop workspace first."
    )

    @StateObject private var configStore: LiveAnchormuxConfigStore
    @StateObject private var terminalStore: TerminalSidebarStore
    @State private var navigationPath = NavigationPath()
    @State private var didAutoOpen = false

    init(config: LiveAnchormuxConfig) {
        _configStore = StateObject(
            wrappedValue: LiveAnchormuxConfigStore(config: config)
        )
        let snapshot = TerminalStoreSnapshot.empty()
        _terminalStore = StateObject(
            wrappedValue: TerminalSidebarStore(
                snapshotStore: InMemoryTerminalSnapshotStore(snapshot: snapshot),
                credentialsStore: InMemoryTerminalCredentialsStore(),
                transportFactory: LiveAnchormuxTransportFactory(config: config),
                workspaceIdentityService: nil,
                workspaceMetadataService: nil,
                serverDiscovery: nil,
                networkPathMonitor: nil,
                remoteWorkspaceReadMarker: LiveAnchormuxNoOpReadMarker(),
                analyticsTracker: nil
            )
        )
    }

    private var workspaceSections: [UnifiedInboxWorkspaceDeviceSection] {
        UnifiedInboxWorkspaceDeviceSectionBuilder.makeSections(
            items: configStore.inboxItems
        )
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if configStore.inboxItems.isEmpty {
                    ContentUnavailableView(
                        Self.emptyTitle,
                        systemImage: "terminal",
                        description: Text(Self.emptyDescription)
                    )
                } else {
                    List {
                        ForEach(workspaceSections) { section in
                            Section {
                                ForEach(section.items) { item in
                                    Button {
                                        openWorkspace(item)
                                    } label: {
                                        UnifiedInboxRow(
                                            item: item,
                                            dotLeadingPadding: 12,
                                            dotOffset: -5
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                Text(
                                    section.title)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(Self.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: TerminalWorkspace.ID.self) { workspaceID in
                TerminalWorkspaceDestinationView(
                    store: terminalStore,
                    workspaceID: workspaceID
                )
            }
            .task {
                autoOpenIfNeeded()
            }
        }
    }

    private func openWorkspace(_ item: UnifiedInboxItem) {
        liveAnchormuxLog("view.openWorkspace title=\(item.title) session=\(item.tmuxSessionName ?? "nil") workspace=\(item.workspaceID ?? "nil")")
        guard let workspaceID = terminalStore.openInboxWorkspace(item, source: .inbox) else {
            liveAnchormuxLog("view.openWorkspace_failed title=\(item.title)")
            return
        }
        liveAnchormuxLog("view.openWorkspace_navigation workspaceID=\(workspaceID)")
        navigationPath.append(workspaceID)
    }

    private func autoOpenIfNeeded() {
        guard !didAutoOpen, let item = configStore.autoOpenInboxItem() else {
            return
        }
        liveAnchormuxLog("view.autoOpen session=\(item.tmuxSessionName ?? "nil") title=\(item.title)")
        didAutoOpen = true
        openWorkspace(item)
    }
}

@MainActor
private struct LiveAnchormuxNoOpReadMarker: TerminalRemoteWorkspaceReadMarking {
    func markRead(item _: UnifiedInboxItem) async throws {}
}
