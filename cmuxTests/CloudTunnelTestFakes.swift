import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Test doubles for ``CloudTunnelCoordinator``: a NetworkExtension controller
/// that records calls and emits link status on demand, an enroller with a fixed
/// config, and a consumer source with a settable count.
/// Records the coordinator's NetworkExtension requests and lets the test
/// drive link status. Lock-protected because the coordinator calls it from
/// its own actor and tests read it from the test's task.
final class FakeTunnelController: CloudTunnelControlling, @unchecked Sendable {
    enum Failure: Error { case refused }

    private let lock = NSLock()
    private var recorded: [String] = []
    private var configurations: [CloudTunnelProviderConfiguration] = []
    private var continuations: [AsyncStream<CloudTunnelLinkStatus>.Continuation] = []
    private var approvalContinuations: [CheckedContinuation<Void, any Error>] = []
    private var _startError: (any Error)?
    private var _connectsOnStart = true
    private var _holdInstallForApproval = false
    private var _currentStatusValue: CloudTunnelLinkStatus = .disconnected
    private var _holdStop = false
    private var stopContinuations: [CheckedContinuation<Void, Never>] = []

    var calls: [String] { lock.withLock { recorded } }
    var installedConfigurations: [CloudTunnelProviderConfiguration] { lock.withLock { configurations } }
    var startError: (any Error)? {
        get { lock.withLock { _startError } }
        set { lock.withLock { _startError = newValue } }
    }
    /// Emit `.connecting` then `.connected` right after `start()` (the normal
    /// NetworkExtension sequence). Off to hold the link in `.connecting`.
    var connectsOnStart: Bool {
        get { lock.withLock { _connectsOnStart } }
        set { lock.withLock { _connectsOnStart = newValue } }
    }
    /// `install` reports "needs user approval" and blocks until `approve()`.
    var holdInstallForApproval: Bool {
        get { lock.withLock { _holdInstallForApproval } }
        set { lock.withLock { _holdInstallForApproval = newValue } }
    }
    /// What `currentStatus()` answers: the link a previous app instance left behind.
    var currentStatusValue: CloudTunnelLinkStatus {
        get { lock.withLock { _currentStatusValue } }
        set { lock.withLock { _currentStatusValue = newValue } }
    }
    /// `stop()` blocks (link stays `.disconnecting`) until `releaseStop()`.
    var holdStop: Bool {
        get { lock.withLock { _holdStop } }
        set { lock.withLock { _holdStop = newValue } }
    }

    /// Let a held `stop()` finish: the link reports `.disconnected`.
    func releaseStop() {
        let waiting = lock.withLock {
            let pending = stopContinuations
            stopContinuations.removeAll()
            return pending
        }
        for continuation in waiting { continuation.resume() }
    }

    var statusUpdates: AsyncStream<CloudTunnelLinkStatus> {
        AsyncStream { continuation in
            lock.withLock { continuations.append(continuation) }
        }
    }

    func emit(_ status: CloudTunnelLinkStatus) {
        for continuation in lock.withLock({ continuations }) {
            continuation.yield(status)
        }
    }

    /// Resolve every pending approval: the user allowed the extension, or
    /// (with `error`) macOS refused it.
    func approve(with error: (any Error)? = nil) {
        let waiting = lock.withLock {
            let pending = approvalContinuations
            approvalContinuations.removeAll()
            return pending
        }
        for continuation in waiting {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    func currentStatus() async -> CloudTunnelLinkStatus { currentStatusValue }

    func install(
        _ configuration: CloudTunnelProviderConfiguration,
        onNeedsUserApproval: @escaping @Sendable () -> Void
    ) async throws {
        lock.withLock {
            recorded.append("install")
            configurations.append(configuration)
        }
        if holdInstallForApproval {
            onNeedsUserApproval()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock { approvalContinuations.append(continuation) }
            }
        }
    }

    func start() async throws {
        lock.withLock { recorded.append("start") }
        if let error = startError { throw error }
        if connectsOnStart {
            emit(.connecting)
            emit(.connected)
        }
    }

    func stop() async throws {
        lock.withLock { recorded.append("stop") }
        emit(.disconnecting)
        if holdStop {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock { stopContinuations.append(continuation) }
            }
        }
        emit(.disconnected)
    }

    func remove() async throws {
        lock.withLock { recorded.append("remove") }
    }

    nonisolated func stopForTermination() {
        lock.withLock { recorded.append("stopForTermination") }
    }
}

final class FakeTunnelEnroller: CloudTunnelEnrolling, @unchecked Sendable {
    static let config = """
    [Interface]
    PrivateKey = test
    Address = 100.64.0.9/32

    [Peer]
    PublicKey = peer
    Endpoint = vpn.example.com:51820
    AllowedIPs = 10.0.0.0/8
    """

    private let lock = NSLock()
    private var count = 0
    var enrollCount: Int { lock.withLock { count } }

    func enroll() async throws -> CloudTunnelEnrollment {
        lock.withLock { count += 1 }
        return CloudTunnelEnrollment(wgQuickConfig: Self.config, serverAddress: "vpn.example.com:51820")
    }
}

final class FakeTunnelConsumers: CloudTunnelConsumerSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _queries = 0

    var count: Int {
        get { lock.withLock { _count } }
        set { lock.withLock { _count = newValue } }
    }
    var queries: Int { lock.withLock { _queries } }

    func liveConsumerCount() async -> Int {
        lock.withLock {
            _queries += 1
            return _count
        }
    }
}
