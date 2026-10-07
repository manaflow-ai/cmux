public import CmuxiOSFeatureKit
public import CmuxiOSSSHCore
import Foundation

/// What the last discovery run found on each SSH host, and the only place
/// an attach takes its target from: a terminal opens a session that was
/// listed, never one named by free text.
public actor SSHSessionCatalog {
    private var targets: [HostID: [String: SSHSessionTarget]] = [:]
    private var listeners: [UUID: AsyncStream<HostID>.Continuation] = [:]

    public init() {}

    /// Replaces `host`'s targets with a discovery result.
    public func record(_ sessions: [SSHDiscoveredSession], for host: HostID) {
        var map: [String: SSHSessionTarget] = [:]
        for session in sessions {
            map[session.target.surfaceID] = session.target
            for window in session.windows { map[window.target.surfaceID] = window.target }
        }
        targets[host] = map
    }

    public func forget(_ host: HostID) { targets[host] = nil }

    /// The listed target behind surface `id` on `host`, if any.
    public func target(host: HostID, surfaceID id: String) -> SSHSessionTarget? {
        targets[host]?[id]
    }

    /// An attached terminal of `host` ended: listeners rediscover.
    public func sessionEnded(on host: HostID) {
        for continuation in listeners.values { continuation.yield(host) }
    }

    /// Hosts whose attached terminal ended, as they end.
    public func endings() -> AsyncStream<HostID> {
        let (stream, continuation) = AsyncStream.makeStream(of: HostID.self, bufferingPolicy: .bufferingNewest(8))
        let id = UUID()
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        return stream
    }

    private func removeListener(_ id: UUID) { listeners[id] = nil }
}
