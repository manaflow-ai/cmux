import CNCore
import CNTransport
import Foundation
import Synchronization

public enum SignalingError: Error, Sendable, Hashable, LocalizedError {
    case notConnected
    case server(code: String, message: String?)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to the signaling service."
        case .server(let code, let message):
            message ?? (code == "host_offline" ? "Your Mac is offline." : "Signaling error: \(code)")
        }
    }
}

/// The `/v1/signal` WebSocket (PROTOCOL §5 Signaling). Keeps one socket
/// open, reconnecting with backoff, and fans incoming frames out to
/// subscribers. Platform independent.
public actor SignalingClient {
    /// Returns the WebSocket URL; called for every connect so a fresh access
    /// token is used. A `token` query item is moved into the
    /// `Authorization: Bearer` header (see `request(for:)`).
    public typealias URLProvider = @Sendable () async throws -> URL
    /// Returns the full upgrade request, including `Authorization`.
    public typealias RequestProvider = @Sendable () async throws -> URLRequest
    /// Forces a fresh access token; called when the server closes the socket
    /// with `tokenExpiredCloseCode`.
    public typealias TokenRefresher = @Sendable () async throws -> Void

    /// Close code the signaling room uses when the access token expired.
    public static let tokenExpiredCloseCode = 4002
    /// Close code for a revoked sign-in session: do not reconnect.
    public static let sessionRevokedCloseCode = 4005
    /// How long to wait for the close frame's code after `receive()` fails.
    public static let closeCodeWait: Duration = .milliseconds(500)

    public private(set) var peerId: String?
    public private(set) var isConnected = false
    /// Online state per host id, from `welcome` and `presence`.
    public private(set) var presenceByHost: [String: Bool] = [:]

    private let requestProvider: RequestProvider
    private let tokenRefresher: TokenRefresher?
    private let urlSession: URLSession
    private let clock: any Clock<Duration>
    private let backoff: ReconnectBackoff
    private let keepAliveInterval: Duration
    private var socket: URLSessionWebSocketTask?
    private var runTask: Task<Void, Never>?
    private var connectWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private nonisolated let messageHub = Broadcaster<SignalMessage>()
    private nonisolated let presenceHub = Broadcaster<HostPresence>()
    private nonisolated let connectionHub = Broadcaster<Bool>()
    private nonisolated let revokedHub = Broadcaster<Void>()

    public init(
        requestProvider: @escaping RequestProvider,
        tokenRefresher: TokenRefresher? = nil,
        urlSession: URLSession = .shared,
        backoff: ReconnectBackoff = ReconnectBackoff(initial: .seconds(1), maximum: .seconds(30), maxAttempts: nil),
        keepAliveInterval: Duration = .seconds(20),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.requestProvider = requestProvider
        self.tokenRefresher = tokenRefresher
        self.urlSession = urlSession
        self.backoff = backoff
        self.keepAliveInterval = keepAliveInterval
        self.clock = clock
    }

    /// Convenience for a provider that returns a URL carrying `?token=`.
    public init(
        urlProvider: @escaping URLProvider,
        tokenRefresher: TokenRefresher? = nil,
        urlSession: URLSession = .shared,
        backoff: ReconnectBackoff = ReconnectBackoff(initial: .seconds(1), maximum: .seconds(30), maxAttempts: nil),
        keepAliveInterval: Duration = .seconds(20),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.init(requestProvider: { Self.request(for: try await urlProvider()) }, tokenRefresher: tokenRefresher, urlSession: urlSession,
                  backoff: backoff, keepAliveInterval: keepAliveInterval, clock: clock)
    }

    /// Moves a `token` query item into an `Authorization: Bearer` header so
    /// the token does not appear in URLs (server and proxy logs).
    public static func request(for url: URL) -> URLRequest {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value else {
            return URLRequest(url: url)
        }
        components.queryItems = components.queryItems?.filter { $0.name != "token" }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        var request = URLRequest(url: components.url ?? url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Every incoming frame.
    public nonisolated func messages() -> AsyncStream<SignalMessage> { messageHub.subscribe() }

    /// Host online changes (each `welcome` entry and each `presence`).
    public nonisolated func presence() -> AsyncStream<HostPresence> { presenceHub.subscribe() }

    /// The server closed the socket with `sessionRevokedCloseCode`. The
    /// client has stopped; the app should sign the user out.
    public nonisolated func sessionRevocations() -> AsyncStream<Void> { revokedHub.subscribe() }

    /// Socket connected (after `welcome`) / disconnected.
    public nonisolated func connectionChanges() -> AsyncStream<Bool> { connectionHub.subscribe() }

    /// Starts the connect loop. Idempotent.
    public func start() {
        guard runTask == nil else { return }
        runTask = Task { await self.run() }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        setConnected(false)
        failWaiters(CancellationError())
    }

    /// Starts if needed and waits for `welcome`, up to `timeout`.
    public func waitUntilConnected(timeout: Duration = .seconds(10)) async throws {
        start()
        if isConnected { return }
        let id = UUID()
        let clock = self.clock
        let timer = Task {
            do { try await clock.sleep(for: timeout) } catch { return }
            self.failWaiter(id, SignalingError.notConnected)
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                if isConnected { c.resume() } else { connectWaiters[id] = c }
            }
        } onCancel: {
            Task { await self.failWaiter(id, CancellationError()) }
        }
    }

    public func send(_ message: SignalMessage) async throws {
        guard let socket, isConnected else { throw SignalingError.notConnected }
        let data = try JSONEncoder().encode(message)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    // MARK: Loop

    private func run() async {
        var attempt = 0
        var refreshedForExpiry = false
        while !Task.isCancelled {
            var closeCode: Int?
            do {
                let request = try await requestProvider()
                let task = urlSession.webSocketTask(with: request)
                let recorder = WebSocketCloseRecorder()
                task.delegate = recorder
                socket = task
                task.resume()
                let keepAlive = startKeepAlive(task)
                defer { keepAlive.cancel() }
                while !Task.isCancelled {
                    let frame = try await task.receive()
                    let data: Data
                    switch frame {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d): data = d
                    @unknown default: continue
                    }
                    guard let message = try? JSONDecoder().decode(SignalMessage.self, from: data) else { continue }
                    if case .welcome = message { attempt = 0; refreshedForExpiry = false }
                    handle(message)
                }
            } catch {
                // Fall through to reconnect; first find out why it closed.
                if !Task.isCancelled, let task = socket {
                    closeCode = await Self.closeCode(of: task, clock: clock)
                }
            }
            socket?.cancel(with: .goingAway, reason: nil)
            socket = nil
            setConnected(false)
            if Task.isCancelled { return }
            // Only the signaling socket reconnects here; established WebRTC
            // links keep running and pick up the new socket for later frames.
            if closeCode == Self.sessionRevokedCloseCode {
                // Signed out elsewhere (or revoked): never reconnect.
                runTask = nil
                failWaiters(SignalingError.server(code: "session_revoked", message: "This device was signed out."))
                revokedHub.yield(())
                return
            }
            if closeCode == Self.tokenExpiredCloseCode, !refreshedForExpiry, let tokenRefresher {
                // Expired access token: refresh and reconnect immediately
                // (once in a row; a repeat falls back to the backoff).
                refreshedForExpiry = true
                if (try? await tokenRefresher()) != nil { attempt = 0; continue }
            }
            refreshedForExpiry = false
            attempt += 1
            do { try await clock.sleep(for: backoff.delay(forAttempt: attempt)) } catch { return }
        }
    }

    /// The server's close code: `task.closeCode`, else the delegate's
    /// `didCloseWith`, which can arrive just after `receive()` fails.
    static func closeCode(of task: URLSessionWebSocketTask, clock: any Clock<Duration>) async -> Int? {
        if task.closeCode != .invalid { return task.closeCode.rawValue }
        guard let recorder = task.delegate as? WebSocketCloseRecorder else { return nil }
        return await recorder.code(waitingUpTo: closeCodeWait, clock: clock)
    }

    private func startKeepAlive(_ task: URLSessionWebSocketTask) -> Task<Void, Never> {
        let clock = self.clock
        let interval = keepAliveInterval
        return Task {
            while !Task.isCancelled {
                do { try await clock.sleep(for: interval) } catch { return }
                task.sendPing { error in
                    if error != nil { task.cancel(with: .abnormalClosure, reason: nil) }
                }
            }
        }
    }

    private func handle(_ message: SignalMessage) {
        switch message {
        case .welcome(let peerId, let hosts):
            self.peerId = peerId
            for h in hosts {
                presenceByHost[h.hostId] = h.online
                presenceHub.yield(h)
            }
            setConnected(true)
        case .presence(let p):
            presenceByHost[p.hostId] = p.online
            presenceHub.yield(p)
        default:
            break
        }
        messageHub.yield(message)
    }

    private func setConnected(_ connected: Bool) {
        guard connected != isConnected else { return }
        isConnected = connected
        connectionHub.yield(connected)
        if connected {
            let waiters = connectWaiters
            connectWaiters.removeAll()
            for (_, c) in waiters { c.resume() }
        }
    }

    private func failWaiter(_ id: UUID, _ error: any Error) {
        connectWaiters.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failWaiters(_ error: any Error) {
        let waiters = connectWaiters
        connectWaiters.removeAll()
        for (_, c) in waiters { c.resume(throwing: error) }
    }
}

/// Records the close code from `urlSession(_:webSocketTask:didCloseWith:reason:)`.
final class WebSocketCloseRecorder: NSObject, URLSessionWebSocketDelegate, Sendable {
    private struct State {
        var recorded: Int?
        var waiters: [CheckedContinuation<Int?, Never>] = []
    }
    private let state = Mutex(State())

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        record(closeCode.rawValue)
    }

    func record(_ code: Int) {
        let pending = state.withLock { s -> [CheckedContinuation<Int?, Never>] in
            s.recorded = code
            defer { s.waiters.removeAll() }
            return s.waiters
        }
        for waiter in pending { waiter.resume(returning: code) }
    }

    /// The recorded code, waiting at most `timeout` for the callback.
    func code(waitingUpTo timeout: Duration, clock: any Clock<Duration>) async -> Int? {
        if let code = state.withLock({ $0.recorded }) { return code }
        let timer = Task { [weak self] in
            do { try await clock.sleep(for: timeout) } catch { return }
            self?.expireWaiters()
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { (c: CheckedContinuation<Int?, Never>) in
            let code = state.withLock { s -> Int? in
                if let recorded = s.recorded { return recorded }
                s.waiters.append(c)
                return nil
            }
            if let code { c.resume(returning: code) }
        }
    }

    private func expireWaiters() {
        let pending = state.withLock { s -> [CheckedContinuation<Int?, Never>] in
            defer { s.waiters.removeAll() }
            return s.waiters
        }
        for waiter in pending { waiter.resume(returning: nil) }
    }
}
