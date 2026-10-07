public import CmuxiOSFeatureKit
import CmuxPairing
public import Foundation

/// The real `DeviceRegistry` (b6-pairing.md sections 3 to 5): a projection of
/// the account's `trust:<user>` mirror and each Mac's `host:` presence, with
/// intents sent to the owners. No optimistic copy: a successful intent shows
/// up only when the owner's event reaches the mirror.
public actor ControlPlaneDeviceRegistry: DeviceRegistry {
    private let bootstrap: @Sendable () async throws -> PairingRuntime
    private let team: String?
    private let now: @Sendable () -> Date
    private var runtime: Task<PairingRuntime, any Error>?
    private var revision: UInt64 = 0
    private var subscribers: [UUID: AsyncStream<SourceSnapshot<[DeviceRecord]>>.Continuation] = [:]
    private var latest: SourceSnapshot<[DeviceRecord]>?
    private var pipeline: Task<Void, Never>?

    /// - Parameters:
    ///   - bootstrap: resolves the account and builds the mirror, owner calls and presence (once).
    ///   - team: the account's team, for own Macs' presence sockets.
    public init(team: String? = nil, now: @escaping @Sendable () -> Date = { Date() },
                bootstrap: @escaping @Sendable () async throws -> PairingRuntime) {
        self.bootstrap = bootstrap
        self.team = team
        self.now = now
    }

    /// One shared pipeline feeds every subscriber (the Mac presence sockets
    /// are per install: two pipelines would replace each other's sockets).
    public func updates() async -> AsyncStream<SourceSnapshot<[DeviceRecord]>> {
        let (stream, sink) = AsyncStream.makeStream(of: SourceSnapshot<[DeviceRecord]>.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = sink
        sink.yield(latest ?? SourceSnapshot(revision: revision, value: [], connection: .connecting))
        sink.onTermination = { _ in Task { await self.unsubscribe(id) } }
        if pipeline == nil { pipeline = Task { await self.follow() } }
        return stream
    }

    public func pair(_ ticket: PairingTicket, key: IntentKey) async throws -> IntentReceipt {
        guard let payload = PairingTicketPayload(ticket: ticket) else { return .refused(key: key, reason: PairingText.notPairingLink) }
        let rt = try await ready()
        return try await receipt(key) {
            switch payload {
            case .device(.install):
                // Same account: Connect means this install publishes its direct key; own Macs trust it then.
                try await rt.ops.ensureDirectKeyPublished()
                return nil
            case .device(.request(let offerID)):
                try await rt.ops.acceptRequest(offerID: offerID)
                return nil
            case .device:
                return nil
            case .link(let url):
                return try await self.claim(url, rt)
            }
        }
    }

    public func revoke(_ deviceID: DeviceRecord.ID, key: IntentKey) async throws -> IntentReceipt {
        let rt = try await ready()
        switch DeviceRecordID(rawValue: deviceID) {
        case .install(let install)?:
            return try await receipt(key) { try await rt.ops.revokeInstall(install); return nil }
        case .remote(let host, let install)?, .guest(let host, let install)?:
            return try await receipt(key) { try await rt.ops.revokePairing(host: host, install: install); return nil }
        case .request, nil:
            return .refused(key: key, reason: PairingText.unknownDevice)
        }
    }

    public func rename(_ deviceID: DeviceRecord.ID, to name: String, key: IntentKey) async throws -> IntentReceipt {
        let rt = try await ready()
        guard case .install(let install)? = DeviceRecordID(rawValue: deviceID) else { return .refused(key: key, reason: PairingText.cannotRename) }
        return try await receipt(key) { try await rt.ops.renameInstall(install, to: name); return nil }
    }

    // MARK: - Private

    private func ready() async throws -> PairingRuntime {
        if let runtime { return try await runtime.value }
        let made = Task { try await bootstrap() }
        runtime = made
        do {
            return try await made.value
        } catch {
            runtime = nil
            throw error
        }
    }

    /// Runs one intent: an owner refusal becomes a refused receipt, an
    /// unreachable owner throws `.offline` (nothing queued).
    private func receipt(_ key: IntentKey, _ body: () async throws -> String?) async throws -> IntentReceipt {
        do {
            if let refusal = try await body() { return .refused(key: key, reason: refusal) }
            revision += 1
            return .committed(key: key, revision: revision)
        } catch let error as PairingClientError {
            return .refused(key: key, reason: PairingText.reason(code: error.code, message: error.message))
        }
    }

    /// Parses, publishes this device's key, claims, and checks the host cert
    /// against the key the QR code carried. Returns a refusal reason or nil.
    private func claim(_ url: URL, _ rt: PairingRuntime) async throws -> String? {
        let link: PairingLink
        do {
            link = try PairingLink(url: url, now: now())
        } catch {
            return PairingLinkHandler.reason(for: error)
        }
        guard case .pair(let offer) = link.kind else { return PairingText.notPairingLink }
        try await rt.ops.ensureDirectKeyPublished()
        let result = try await rt.ops.claim(offer)
        do {
            try result.verify(offer: offer, environment: rt.account.environment, now: Int64(now().timeIntervalSince1970 * 1000))
        } catch {
            return PairingText.keyMismatch
        }
        return nil
    }

    /// The last subscriber leaving stops the pipeline (and its presence sockets).
    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
        guard subscribers.isEmpty else { return }
        pipeline?.cancel()
        pipeline = nil
    }

    private func emit(_ snapshot: SourceSnapshot<[DeviceRecord]>) {
        latest = snapshot
        for sink in subscribers.values { sink.yield(snapshot) }
    }

    private func follow() async {
        let rt: PairingRuntime
        do {
            rt = try await ready()
        } catch {
            emit(SourceSnapshot(revision: revision, value: [], connection: .offline(reason: nil)))
            pipeline = nil
            return
        }
        let projection = DeviceProjection(account: rt.account)
        let merged = PairingRegistryInputs()
        let team = self.team
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await state in await rt.mirror.updates() { await merged.set(state: state) }
            }
            group.addTask {
                for await connection in await rt.ops.connectionStates() { await merged.set(connection: connection) }
            }
            group.addTask {
                var followed: [String: String] = [:]
                var presenceTask: Task<Void, Never>?
                for await state in await merged.states() {
                    let hosts = projection.hosts(state: state, team: team)
                    guard hosts != followed else { continue }
                    followed = hosts
                    presenceTask?.cancel()
                    presenceTask = Task {
                        for await map in await rt.presence.presence(of: hosts) { await merged.set(presence: map) }
                    }
                }
                presenceTask?.cancel()
            }
            group.addTask {
                for await inputs in await merged.changes() {
                    let records = projection.records(state: inputs.state, presence: inputs.presence, now: self.now())
                    await self.emit(records: records, connection: inputs.connection)
                }
            }
            await group.waitForAll()
        }
    }

    private func emit(records: [DeviceRecord], connection: SourceConnection) {
        revision += 1
        emit(SourceSnapshot(revision: revision, value: records, connection: connection))
    }

    deinit {
        // The owner sockets live as long as the registry (one per account).
        pipeline?.cancel()
        if let runtime { Task { try? await runtime.value.stop() } }
    }
}
