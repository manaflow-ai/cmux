public import CmuxiOSFeatureKit
import CmuxMobileWire
public import Foundation

/// `CloudMachineSource` over `CloudDO` (plans/cmux-next/ios-next/c12-cloud.md
/// section 2): events from `GET /v1/wire/cloud`, rows from `cloud.machine.list`,
/// the plan from `cloud.plan.get`, intents through `POST /v1/ops`.
///
/// The snapshot carries the head only, so every snapshot (first connect,
/// reconnect, after a gap) starts one list read. Live events apply their
/// `cloud.machine.upsert` / `removed` record in seq order; a skipped seq sends
/// `snapshot.request` and drops events until the snapshot arrives. The plan
/// is read after the list and after a machine change, one read in flight.
/// The socket is open while someone subscribes; nothing polls.
public actor WireCloudMachineSource: CloudMachineSource {
    private typealias Subscriber = AsyncStream<SourceSnapshot<CloudState>>.Continuation

    private let wireURL: URL
    private let api: any CloudAPIClient
    private let credentials: any CloudCredentials
    private let transport: any CloudWireTransport
    private let clock: any Clock<Duration>
    private let clientVersion: String?
    private let decoder = CloudWireDecoder()
    private let initialBackoff: Duration
    private let maximumBackoff: Duration
    /// `mutation.indeterminate` retries with the same key before giving up.
    private let indeterminateRetries = 3

    private var mirror = CloudMachineMirror()
    private var log = CloudIntentLog()
    private var plan: CloudPlan?
    private var connection: SourceConnection = .connecting
    private var revision: UInt64 = 0
    private var subscribers: [UUID: Subscriber] = [:]
    private var runner: Task<Void, Never>?
    private var generation = 0
    private var socket: (any CloudWireConnection)?
    private var outbox: AsyncStream<String>.Continuation?
    private var lastSeq: UInt64?
    private var awaitingSnapshot = true
    private var backoff: Duration
    private var listGeneration = 0
    private var listTask: Task<Void, Never>?
    private var planTask: Task<Void, Never>?
    private var planDirty = false
    /// Set when a list read ends the session, so the offline state names it.
    private var listFailure: String?

    public init(
        apiBaseURL: URL, api: any CloudAPIClient, credentials: any CloudCredentials,
        transport: any CloudWireTransport = URLSessionCloudWireTransport(),
        clock: any Clock<Duration> = ContinuousClock(),
        backoff: (initial: Duration, maximum: Duration) = (.milliseconds(500), .seconds(30)),
        clientVersion: String? = nil
    ) {
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/v1/wire/cloud"
        wireURL = components.url ?? apiBaseURL
        self.api = api
        self.credentials = credentials
        self.transport = transport
        self.clock = clock
        self.clientVersion = clientVersion
        initialBackoff = backoff.initial
        maximumBackoff = backoff.maximum
        self.backoff = backoff.initial
    }

    // MARK: - CloudMachineSource

    public func updates() -> AsyncStream<SourceSnapshot<CloudState>> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SourceSnapshot<CloudState>.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        continuation.yield(current)
        if runner == nil { start() }
        return stream
    }

    public func perform(_ intent: CloudIntent, key: IntentKey) async throws -> IntentReceipt {
        guard connection.isLive else { throw FeatureSourceError.offline }
        log.add(intent, key: key)
        broadcast()
        defer {
            log.settle(key)
            broadcast()
        }
        for _ in 0..<indeterminateRetries {
            let reply: CloudOpReply
            do {
                // Every Cloud mutation goes as the signed-in person: CloudDO
                // refuses create, start, pause and delete from an install.
                reply = try await api.mutate(intent.op, params: intent.params, key: key.rawValue, as: .session)
            } catch CloudAPIError.unauthenticated {
                return .refused(key: key, reason: "auth.unauthenticated")
            } catch {
                // Outcome unknown: the next tap is a new intent; a retry of this
                // one with the same key would replay the owner's answer.
                throw FeatureSourceError.offline
            }
            switch reply {
            case .committed(let value, let revision):
                if let record = value["machine"], let machine = try? decoder.machine(record), mirror.upsert(machine) {
                    readPlan()
                }
                return .committed(key: key, revision: revision)
            case .rejected(let code, _) where code == "mutation.indeterminate":
                continue
            case .rejected(let code, _):
                return .refused(key: key, reason: code)
            }
        }
        return .refused(key: key, reason: "mutation.indeterminate")
    }

    /// Screens currently subscribed (tests).
    var subscriberCount: Int { subscribers.count }

    // MARK: - Snapshot

    private var current: SourceSnapshot<CloudState> {
        SourceSnapshot(
            revision: revision,
            value: CloudState(machines: log.overlay(mirror.sorted), creating: log.creating, plan: plan, isLoaded: mirror.isLoaded),
            connection: connection)
    }

    private func broadcast() {
        revision += 1
        let snapshot = current
        for subscriber in subscribers.values { subscriber.yield(snapshot) }
    }

    private func setConnection(_ next: SourceConnection) {
        guard next != connection else { return }
        connection = next
        broadcast()
    }

    // MARK: - Connection

    private func start() {
        generation += 1
        let generation = generation
        runner = Task { await self.run(generation) }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
        guard subscribers.isEmpty, runner != nil else { return }
        generation += 1
        runner?.cancel()
        runner = nil
        socket?.close()
        socket = nil
        outbox?.finish()
        outbox = nil
        listTask?.cancel()
        listTask = nil
        planTask?.cancel()
        planTask = nil
        planDirty = false
        mirror = CloudMachineMirror()
        plan = nil
        lastSeq = nil
        connection = .connecting
    }

    private func run(_ generation: Int) async {
        while !Task.isCancelled, generation == self.generation {
            setConnection(.connecting)
            var reason: String?
            do {
                try await session(generation)
            } catch is CancellationError {
                return
            } catch let error as CloudWireError {
                switch error {
                case .owner(let code), .listFailed(let code): reason = code
                }
            } catch {
                reason = listFailure
            }
            listFailure = nil
            guard generation == self.generation else { return }
            outbox?.finish()
            outbox = nil
            lastSeq = nil
            setConnection(.offline(reason: reason))
            let delay = backoff
            backoff = min(backoff * 2, maximumBackoff)
            do { try await clock.sleep(for: delay) } catch { return }
        }
    }

    private func session(_ generation: Int) async throws {
        var request = URLRequest(url: wireURL)
        request.setValue("cmux.wire.v1, bearer.\(try await credentials.token(for: .install))",
                         forHTTPHeaderField: "Sec-WebSocket-Protocol")
        if let clientVersion { request.setValue(clientVersion, forHTTPHeaderField: "x-cmux-client-version") }
        let socket = try await transport.connect(request)
        defer { socket.close() }
        guard generation == self.generation else { throw CancellationError() }
        self.socket = socket
        defer { if generation == self.generation { self.socket = nil } }
        let (frames, outbox) = AsyncStream.makeStream(of: String.self)
        self.outbox = outbox
        let sender = Task {
            for await text in frames { try? await socket.send(text) }
        }
        defer { sender.cancel() }
        awaitingSnapshot = true
        lastSeq = nil
        write(#"{"t":"subscribe"}"#)
        while !Task.isCancelled, generation == self.generation {
            let data = try await socket.receive()
            guard generation == self.generation else { break }
            try handle(CloudWireFrame.decode(data, decoder: decoder))
        }
        throw CancellationError()
    }

    private func write(_ text: String) { outbox?.yield(text) }

    // MARK: - Frames

    private func handle(_ frame: CloudWireFrame) throws {
        switch frame {
        case .snapshot(let seq):
            lastSeq = seq
            awaitingSnapshot = false
            backoff = initialBackoff
            connection = .live(path: "cloud")
            broadcast()
            relist()
        case .event(let seq, let change):
            guard !awaitingSnapshot, let last = lastSeq, seq > last else { return }
            guard seq == last + 1 else {
                awaitingSnapshot = true
                write(#"{"t":"snapshot.request"}"#)
                return
            }
            lastSeq = seq
            switch change {
            case .upsert(let machine)?:
                if mirror.upsert(machine) {
                    broadcast()
                    readPlan()
                }
            case .removed(let id, let revision)?:
                mirror.remove(id, at: revision)
                broadcast()
                readPlan()
            case .unreadable?:
                relist()
            case .other?, nil:
                break
            }
        case .error(let code):
            if awaitingSnapshot { throw CloudWireError.owner(code: code) }
        case .ignored:
            break
        }
    }

    // MARK: - Reads

    /// Reads every page of the machine list; a newer list read supersedes it.
    private func relist() {
        listGeneration += 1
        let generation = listGeneration
        listTask?.cancel()
        listTask = Task { await self.loadList(generation) }
    }

    private func loadList(_ generation: Int) async {
        var machines: [CloudMachine] = []
        var cursor: String?
        var revision: UInt64?
        do {
            for _ in 0..<100 {
                var params: [String: JSONValue] = ["limit": .int(100)]
                if let cursor { params["cursor"] = .string(cursor) }
                let page = try decoder.page(try await api.read("cloud.machine.list", params: params))
                revision = revision ?? page.revision
                machines += page.machines
                cursor = page.nextCursor
                if cursor == nil { break }
            }
        } catch {
            guard generation == listGeneration, !Task.isCancelled else { return }
            // Restart the session (backoff, fresh snapshot, fresh read).
            let code = (error as? CloudAPIError).flatMap { if case .refused(let code) = $0 { code } else { nil } } ?? "list"
            listFailure = code
            socket?.close()
            return
        }
        guard generation == listGeneration, !Task.isCancelled else { return }
        mirror.replace(with: machines, at: revision ?? 0)
        broadcast()
        readPlan()
    }

    /// One plan read in flight; a change during it reads once more after.
    private func readPlan() {
        guard mirror.isLoaded else { return }
        guard planTask == nil else {
            planDirty = true
            return
        }
        planTask = Task { await self.loadPlan() }
    }

    private func loadPlan() async {
        repeat {
            planDirty = false
            if let value = try? await api.read("cloud.plan.get", params: [:]), let next = try? decoder.plan(value) {
                guard !Task.isCancelled else { return }
                if next != plan {
                    plan = next
                    broadcast()
                }
            }
        } while planDirty && !Task.isCancelled
        if !Task.isCancelled { planTask = nil }
    }
}
