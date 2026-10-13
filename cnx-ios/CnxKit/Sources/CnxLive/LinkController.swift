import CnxTransport
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "dev.cmux.cnx", category: "link")

/// Runs `LinkMachine` against a real dialer: dials, watches the link's state
/// stream, schedules retries on an injected clock, and hands the live link
/// to `onLink` (nil when it goes away).
@MainActor
@Observable
public final class LinkController {
    public private(set) var phase: LinkMachine.Phase = .idle
    public private(set) var link: (any MacLink)?
    /// The last failure, kept while reconnecting (Settings shows it).
    public private(set) var lastFailure: String?

    @ObservationIgnored private var machine: LinkMachine
    @ObservationIgnored private let dialer: any MacLinkDialer
    /// Resolves a Mac id to a dial endpoint (nil until the phone is registered).
    @ObservationIgnored public var endpoint: @MainActor (String) -> LinkEndpoint? = { _ in nil }
    @ObservationIgnored private let accessToken: @Sendable (_ forceRefresh: Bool) async throws -> String
    /// The last dial was refused with 401: the next dial mints a fresh token.
    @ObservationIgnored private var refreshTokenNextDial = false
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var dialTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    /// How often a live link is pinged, and how long a ping may take.
    nonisolated static let heartbeat: Duration = .seconds(15)
    nonisolated static let probeTimeout: Duration = .seconds(8)
    @ObservationIgnored public var onLink: (@MainActor ((any MacLink)?) -> Void)?

    public init(
        transport: TransportKind,
        relayOnly: Bool = false,
        dialer: any MacLinkDialer,
        clock: any Clock<Duration> = ContinuousClock(),
        accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String
    ) {
        machine = LinkMachine(transport: transport, relayOnly: relayOnly)
        self.dialer = dialer
        self.clock = clock
        self.accessToken = accessToken
    }

    public var target: LinkMachine.Target? { machine.target }
    public var transport: TransportKind { machine.transport }
    public var relayOnly: Bool { machine.relayOnly }

    public func send(_ event: LinkMachine.Event) {
        let effects = machine.handle(event)
        if phase != machine.phase {
            log.info("link \(String(describing: self.machine.phase), privacy: .public)")
            phase = machine.phase
        }
        if case .waiting(_, _, let reason, _) = machine.phase { lastFailure = reason }
        if machine.phase.isConnected { lastFailure = nil }
        for effect in effects { run(effect) }
    }

    private func run(_ effect: LinkMachine.Effect) {
        switch effect {
        case .close:
            dialTask?.cancel()
            watchTask?.cancel()
            heartbeatTask?.cancel()
            retryTask?.cancel()
            if let link {
                self.link = nil
                onLink?(nil)
                Task { await link.close() }
            }
        case .dial(let generation, let macID, let transport):
            dialTask?.cancel()
            retryTask?.cancel()
            guard var endpoint = endpoint(macID) else {
                send(.dialFailed(generation: generation, reason: "not registered yet"))
                return
            }
            endpoint.relayOnly = machine.relayOnly
            log.info("dial \(transport.rawValue, privacy: .public) relayOnly=\(endpoint.relayOnly, privacy: .public)")
            let dialer = dialer
            let accessToken = accessToken
            let forceRefresh = refreshTokenNextDial
            refreshTokenNextDial = false
            dialTask = Task { [weak self] in
                do {
                    let token = try await accessToken(forceRefresh)
                    let link = try await dialer.dial(endpoint, transport: transport, accessToken: token)
                    guard let self, !Task.isCancelled, generation == self.machine.generation else {
                        await link.close()
                        return
                    }
                    self.adopt(link, generation: generation)
                } catch {
                    if "\(error)".contains("401") { self?.refreshTokenNextDial = true }
                    self?.send(.dialFailed(generation: generation, reason: Self.reason(error)))
                }
            }
        case .scheduleRetry(let generation, let delay):
            retryTask?.cancel()
            let clock = clock
            retryTask = Task { [weak self] in
                do { try await clock.sleep(for: delay) } catch { return }
                self?.send(.retryDue(generation: generation))
            }
        case .probe(let generation):
            guard let link else { return }
            let clock = clock
            Task { [weak self] in
                // The ping races a timeout: a frozen Mac never answers.
                let result = await Self.race(timeout: Self.probeTimeout, clock: clock) { try await link.ping() }
                guard let self else { return }
                switch result {
                case .success(let rtt):
                    guard case .connected(_, let path, _) = self.phase else { return }
                    self.send(.linkUpdated(generation: generation, path: path, rttMillis: rtt))
                case .failure(let error):
                    self.send(.probeFailed(generation: generation, reason: Self.reason(error)))
                }
            }
        }
    }

    private func adopt(_ link: any MacLink, generation: Int) {
        self.link = link
        watchTask?.cancel()
        let states = link.states
        var initialPath = LinkPathKind.direct
        watchTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                switch state {
                case .connected(_, let path, let rtt):
                    if case .connecting = self.machine.phase {
                        initialPath = path
                        self.send(.dialSucceeded(generation: generation, path: path))
                        self.onLink?(link)
                    }
                    self.send(.linkUpdated(generation: generation, path: path, rttMillis: rtt))
                case .disconnected(let reason):
                    self.send(.linkDropped(generation: generation, reason: reason))
                case .idle, .connecting:
                    break
                }
            }
            _ = initialPath
        }
        // Measure RTT once up front so the status line has a number quickly,
        // then keep probing so a silent Mac is noticed.
        send(.foreground)
        heartbeatTask?.cancel()
        let clock = clock
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: Self.heartbeat) } catch { return }
                guard let self, generation == self.machine.generation else { return }
                self.run(.probe(generation: generation))
            }
        }
    }

    /// `operation`'s result, or a timeout failure after `timeout`, whichever
    /// comes first. Not a task group: a group waits for every child before it
    /// returns, and the FFI ping ignores cancellation, so a ping on a link the
    /// Mac had already dropped (the app was suspended) held the probe until
    /// the link's own keepalive gave up 20 s later; input typed meanwhile was
    /// lost.
    nonisolated static func race(
        timeout: Duration, clock: any Clock<Duration>, _ operation: @escaping @Sendable () async throws -> UInt32
    ) async -> Result<UInt32, any Error> {
        let once = RaceOnce()
        return await withCheckedContinuation { continuation in
            let work = Task {
                let result: Result<UInt32, any Error>
                do { result = .success(try await operation()) } catch { result = .failure(error) }
                if once.claim() { continuation.resume(returning: result) }
            }
            Task {
                try? await clock.sleep(for: timeout)
                if once.claim() {
                    work.cancel()
                    continuation.resume(returning: .failure(LinkError(code: "timeout", message: "")))
                }
            }
        }
    }

    /// A short, display-safe reason for a dial or link error.
    nonisolated static func reason(_ error: any Error) -> String {
        if let error = error as? LinkError {
            switch error.code {
            case "timeout": return "the Mac didn't answer in time"
            case "not_admitted": return "the Mac refused this phone"
            case "offline": return "the Mac is offline"
            default:
                let message = error.message.trimmingCharacters(in: .whitespacesAndNewlines)
                return message.isEmpty ? error.code : String(message.prefix(80))
            }
        }
        if error is LiveAPI.Failure { return "the cmux service refused the request" }
        return String(error.localizedDescription.prefix(80))
    }
}

/// One winner for ``LinkController/race(timeout:clock:_:)``.
private final class RaceOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
