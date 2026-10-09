import CNCore
import CNTransport
import Foundation

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
    /// Returns the WebSocket URL including `?token=`; called for every
    /// connect so a fresh access token is used.
    public typealias URLProvider = @Sendable () async throws -> URL

    public private(set) var peerId: String?
    public private(set) var isConnected = false
    /// Online state per host id, from `welcome` and `presence`.
    public private(set) var presenceByHost: [String: Bool] = [:]

    private let urlProvider: URLProvider
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

    public init(
        urlProvider: @escaping URLProvider,
        urlSession: URLSession = .shared,
        backoff: ReconnectBackoff = ReconnectBackoff(initial: .seconds(1), maximum: .seconds(30), maxAttempts: nil),
        keepAliveInterval: Duration = .seconds(20),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.urlProvider = urlProvider
        self.urlSession = urlSession
        self.backoff = backoff
        self.keepAliveInterval = keepAliveInterval
        self.clock = clock
    }

    /// Every incoming frame.
    public nonisolated func messages() -> AsyncStream<SignalMessage> { messageHub.subscribe() }

    /// Host online changes (each `welcome` entry and each `presence`).
    public nonisolated func presence() -> AsyncStream<HostPresence> { presenceHub.subscribe() }

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
        while !Task.isCancelled {
            do {
                let url = try await urlProvider()
                let task = urlSession.webSocketTask(with: url)
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
                    if case .welcome = message { attempt = 0 }
                    handle(message)
                }
            } catch {
                // Fall through to reconnect.
            }
            socket?.cancel(with: .goingAway, reason: nil)
            socket = nil
            setConnected(false)
            if Task.isCancelled { return }
            attempt += 1
            do { try await clock.sleep(for: backoff.delay(forAttempt: attempt)) } catch { return }
        }
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
