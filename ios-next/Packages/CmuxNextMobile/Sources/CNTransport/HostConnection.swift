import CNCore
import Foundation
import Observation
import os

let hostConnectionLog = Logger(subsystem: "dev.cmux.next", category: "connection")

public enum HostConnectionState: Sendable, Hashable {
    case idle
    case connecting
    case connected(PathInfo)
    /// Waiting before reconnect attempt `attempt` (1-based).
    case reconnecting(attempt: Int, lastError: String?)
    case failed(String)

    public var isConnected: Bool { if case .connected = self { true } else { false } }

    public var pathInfo: PathInfo? { if case .connected(let p) = self { p } else { nil } }
}

/// Exponential reconnect delays.
public struct ReconnectBackoff: Sendable, Hashable {
    public var initial: Duration
    public var multiplier: Double
    public var maximum: Duration
    /// Attempts before giving up with `.failed`. Nil retries forever.
    public var maxAttempts: Int?

    public init(initial: Duration = .milliseconds(500), multiplier: Double = 2, maximum: Duration = .seconds(15), maxAttempts: Int? = 10) {
        self.initial = initial; self.multiplier = multiplier; self.maximum = maximum; self.maxAttempts = maxAttempts
    }

    public func delay(forAttempt attempt: Int) -> Duration {
        let factor = pow(multiplier, Double(max(0, attempt - 1)))
        let d = initial * factor
        return d > maximum ? maximum : d
    }
}

/// Counts consecutive unanswered `host.ping`s. One late ping is not a dead
/// link: relayed paths and a busy device stall for several seconds, and SCTP
/// delivers the backlog once the path recovers.
public struct PingLiveness: Sendable, Hashable {
    public let maxMisses: Int
    public private(set) var misses = 0

    public init(maxMisses: Int = 3) { self.maxMisses = max(1, maxMisses) }

    /// Records one ping result; returns true when the link should be closed.
    public mutating func record(answered: Bool) -> Bool {
        misses = answered ? 0 : misses + 1
        return misses >= maxMisses
    }
}

/// The app's connection to one host: connects through a `Connector`, says
/// hello, keeps RTT fresh with `host.ping`, and reconnects with backoff.
/// Event subscriptions made here survive reconnects.
@MainActor
@Observable
public final class HostConnection {
    public private(set) var state: HostConnectionState = .idle
    public private(set) var hostId: String?
    public private(set) var hostInfo: HostInfo?
    /// The live client, nil while not connected.
    public private(set) var client: HostClient?
    /// Increments on every successful (re)connect. Views reload their data
    /// when it changes.
    public private(set) var generation = 0

    @ObservationIgnored public let connector: any Connector
    @ObservationIgnored public let clientInfo: ClientInfo
    @ObservationIgnored public let backoff: ReconnectBackoff
    @ObservationIgnored public let pingInterval: Duration
    /// Consecutive unanswered pings before the link is treated as dead.
    @ObservationIgnored public let maxMissedPings: Int
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let hub = EventHub(persistent: true)
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var currentRunId: UUID?
    @ObservationIgnored private var sessionTasks: [Task<Void, Never>] = []

    public init(
        connector: any Connector,
        clientInfo: ClientInfo,
        backoff: ReconnectBackoff = ReconnectBackoff(),
        pingInterval: Duration = .seconds(10),
        maxMissedPings: Int = 3,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.maxMissedPings = maxMissedPings
        self.connector = connector
        self.clientInfo = clientInfo
        self.backoff = backoff
        self.pingInterval = pingInterval
        self.clock = clock
    }

    public var pathInfo: PathInfo? { state.pathInfo }

    /// Connects to `hostId`, replacing any current connection.
    public func connect(hostId: String) {
        stop()
        self.hostId = hostId
        let runId = UUID()
        currentRunId = runId
        runTask = Task { [weak self] in await self?.run(hostId: hostId, runId: runId) }
    }

    /// Reconnects now (for example from `.failed` or when the app returns to
    /// the foreground while `.reconnecting`).
    public func retry() {
        guard let hostId else { return }
        connect(hostId: hostId)
    }

    public func disconnect() {
        stop()
        state = .idle
    }

    private func stop() {
        currentRunId = nil
        runTask?.cancel()
        runTask = nil
        client?.close()
        tearDownSession()
    }

    private func tearDownSession() {
        for t in sessionTasks { t.cancel() }
        sessionTasks.removeAll()
        client = nil
    }

    // MARK: Calls

    /// The live client or `HostClientError.notConnected`.
    public func requireClient() throws -> HostClient {
        guard let client else { throw HostClientError.notConnected }
        return client
    }

    public func request<R: Decodable & Sendable, P: Encodable & Sendable>(_ method: String, _ params: P, as type: R.Type = R.self) async throws -> R {
        try await requireClient().request(method, params, as: R.self)
    }

    /// Events for `topic` from every connection generation.
    public nonisolated func events(topic: String? = nil) -> AsyncStream<HostEvent> {
        hub.subscribe(topic: topic)
    }

    /// Decoded pushes from every connection generation.
    public nonisolated func pushes() -> AsyncStream<HostPush> {
        hub.subscribe(topic: nil).pushes()
    }

    // MARK: Loop

    /// One run per `connect`. A superseded run (cancelled, or replaced by a
    /// newer `connect`) never touches shared state after an await.
    private func run(hostId: String, runId: UUID) async {
        func isCurrent() -> Bool { !Task.isCancelled && currentRunId == runId }
        var attempt = 0
        var lastError: String?
        while isCurrent() {
            state = attempt == 0 ? .connecting : .reconnecting(attempt: attempt, lastError: lastError)
            var transport: (any LinkTransport)?
            var client: HostClient?
            do {
                let t = try await connector.connect(hostId: hostId)
                transport = t
                guard isCurrent() else { t.close(); return }
                let c = HostClient(transport: t, clock: clock)
                client = c
                let info = try await c.hello(clientInfo)
                guard isCurrent() else { c.close(); return }
                self.client = c
                self.hostInfo = info
                generation += 1
                attempt = 0
                var path = await t.pathInfo()
                path.rttMs = await measureRTT(c)
                guard isCurrent(), self.client === c else { c.close(); return }
                state = .connected(path)
                startSession(client: c, transport: t)
                let reason = await c.waitUntilClosed()
                guard isCurrent() else { return }
                if self.client === c { tearDownSession() }
                lastError = reason ?? "Connection closed"
                hostConnectionLog.notice("link to \(hostId, privacy: .public) closed: \(lastError ?? "", privacy: .public)")
            } catch {
                // A failed hello (or anything after connect) must not leak
                // the transport or its client.
                client?.close()
                transport?.close()
                lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            guard isCurrent() else { return }
            attempt += 1
            if let max = backoff.maxAttempts, attempt > max {
                state = .failed(lastError ?? "Could not connect")
                return
            }
            state = .reconnecting(attempt: attempt, lastError: lastError)
            do { try await clock.sleep(for: backoff.delay(forAttempt: attempt)) } catch { return }
        }
    }

    private func startSession(client: HostClient, transport: any LinkTransport) {
        let hub = self.hub
        let forward = Task {
            for await event in client.events() { hub.publish(event) }
        }
        let interval = pingInterval
        let clock = self.clock
        let maxMisses = maxMissedPings
        let ping = Task { [weak self] in
            var liveness = PingLiveness(maxMisses: maxMisses)
            while !Task.isCancelled {
                do { try await clock.sleep(for: interval) } catch { return }
                guard let self else { return }
                let rtt = await self.measureRTT(client)
                if liveness.record(answered: rtt != nil) {
                    // Several unanswered pings in a row: the path is dead.
                    hostConnectionLog.notice("\(liveness.misses) pings unanswered; closing the link")
                    client.close()
                    return
                }
                guard let rtt else {
                    hostConnectionLog.notice("ping unanswered (\(liveness.misses)/\(liveness.maxMisses))")
                    continue
                }
                var path = await transport.pathInfo()
                path.rttMs = rtt
                if case .connected = self.state, self.client === client { self.state = .connected(path) }
            }
        }
        sessionTasks = [forward, ping]
    }

    private func measureRTT(_ client: HostClient) async -> Double? {
        let start = ContinuousClock.now
        do {
            _ = try await client.request(HostMethod.ping.rawValue, as: PingResult.self, timeout: .seconds(8))
        } catch {
            return nil
        }
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }
}
