import Foundation
import OSLog

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "terminal.pool")

/// Process-wide registry of TerminalDaemonConnection actors, keyed by host
/// stableID. Workspace subscription and terminal sessions for the same daemon
/// share one ws + one TerminalRemoteDaemonClient.
final class TerminalDaemonConnectionPool: @unchecked Sendable {
    static let shared = TerminalDaemonConnectionPool()

    private let lock = NSLock()
    private var connections: [String: TerminalDaemonConnection] = [:]
    private var pushConfigObserver: NSObjectProtocol?

    init() {
        // Phase 4.3: forward push configuration changes (new device token,
        // new endpoint, new bearer) to every live daemon connection so they
        // can re-send daemon.configure_notifications.
        pushConfigObserver = NotificationCenter.default.addObserver(
            forName: PushNotificationConfigurator.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.reprovisionAllRemotePush()
        }
    }

    deinit {
        if let observer = pushConfigObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func connection(
        stableID: String,
        hostname: String,
        port: Int,
        secret: String
    ) -> TerminalDaemonConnection {
        lock.lock()
        defer { lock.unlock() }
        // Invalidate and recreate when the host/port/secret changes for a
        // given stableID. Local dev daemons move ports between restarts
        // (tag-derived hash, CMUX_MOBILE_WS_PORT override, etc.). Without
        // this check a cached pool entry keeps pointing at a dead port
        // and every workspace tap hangs on "Could not connect to the
        // server." because acquireClient keeps retrying the stale URL.
        if let existing = connections[stableID] {
            if existing.matches(hostname: hostname, port: port, secret: secret) {
                return existing
            }
            log.info("pool invalidating stableID=\(stableID, privacy: .public) (endpoint changed -> \(hostname, privacy: .public):\(port, privacy: .public))")
            connections.removeValue(forKey: stableID)
        }
        let connection = TerminalDaemonConnection(
            hostname: hostname,
            port: port,
            secret: secret
        )
        connections[stableID] = connection
        return connection
    }

    func remove(stableID: String) -> TerminalDaemonConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connections.removeValue(forKey: stableID)
    }

    /// Kick every pooled connection to tear down + reconnect immediately,
    /// returning only after each one's next workspace.subscribe round
    /// completes (or the connect fails and the waiter is released). Backs
    /// the workspace-list pull-to-refresh.
    func refreshAll() async {
        let snapshot: [TerminalDaemonConnection] = {
            lock.lock()
            defer { lock.unlock() }
            return Array(connections.values)
        }()
        await withTaskGroup(of: Void.self) { group in
            for connection in snapshot {
                group.addTask { await connection.kickAndAwaitFirstSync() }
            }
        }
    }

    private func reprovisionAllRemotePush() {
        let snapshot: [TerminalDaemonConnection] = {
            lock.lock()
            defer { lock.unlock() }
            return Array(connections.values)
        }()
        for connection in snapshot {
            Task { await connection.reprovisionRemotePush() }
        }
    }
}
