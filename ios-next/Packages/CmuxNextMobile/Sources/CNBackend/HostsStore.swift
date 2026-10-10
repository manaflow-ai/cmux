import CNCore
import Foundation
import Observation

/// The user's paired Macs with live presence.
@MainActor
@Observable
public final class HostsStore {
    public private(set) var hosts: [HostRecord] = []
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public var lastError: String?

    @ObservationIgnored public let backend: BackendClient
    @ObservationIgnored private var presenceTask: Task<Void, Never>?
    /// Presence received before the host list loaded.
    @ObservationIgnored private var knownPresence: [String: Bool] = [:]

    public init(backend: BackendClient) {
        self.backend = backend
    }

    public var onlineHosts: [HostRecord] { hosts.filter(\.online) }

    public func host(id: String) -> HostRecord? { hosts.first { $0.id == id } }

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            var list = try await backend.hosts()
            for i in list.indices { if let online = knownPresence[list[i].id] { list[i].online = online } }
            hosts = list.sorted { ($0.online ? 0 : 1, $0.name) < ($1.online ? 0 : 1, $1.name) }
            hasLoaded = true
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Approves the code shown by `cmux-next-host pair` and adds the host.
    @discardableResult
    public func approvePairing(userCode: String) async throws -> HostRecord {
        let normalized = userCode.uppercased().filter { !$0.isWhitespace }
        let host = try await backend.approvePairing(userCode: normalized)
        hosts.removeAll { $0.id == host.id }
        hosts.insert(host, at: 0)
        return host
    }

    public func delete(hostId: String) async throws {
        try await backend.deleteHost(id: hostId)
        hosts.removeAll { $0.id == hostId }
    }

    public func apply(_ presence: HostPresence) {
        knownPresence[presence.hostId] = presence.online
        guard let i = hosts.firstIndex(where: { $0.id == presence.hostId }) else { return }
        hosts[i].online = presence.online
        if !presence.online { hosts[i].lastSeenAt = Date().epochMillis }
    }

    /// Applies presence updates (for example `SignalingClient.presence()`)
    /// until the stream ends or another stream replaces it.
    public func observePresence(_ updates: AsyncStream<HostPresence>) {
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            for await p in updates { self?.apply(p) }
        }
    }

    public func clear() {
        hosts = []
        hasLoaded = false
        knownPresence = [:]
    }
}
