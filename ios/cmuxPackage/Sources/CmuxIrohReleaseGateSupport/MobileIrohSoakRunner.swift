#if os(iOS) && DEBUG
import CmuxMobileShellReleaseGateSupport
import CMUXMobileCore
import Foundation

/// Runs a fixed workload against the real mobile shell for a full observation window.
@MainActor
final class MobileIrohSoakRunner {
    enum Profile: String, Codable, Sendable {
        case basic
        case stress

        var seconds: Int { self == .basic ? 600 : 3_600 }
        var interval: Duration { self == .basic ? .seconds(10) : .seconds(5) }
        var minimumCycles: Int { self == .basic ? 50 : 300 }
    }

    struct Evidence: Codable, Equatable, Sendable {
        struct OperationTiming: Codable, Equatable, Sendable {
            var count = 0
            var totalSeconds = 0.0
            var minimumSeconds = 0.0
            var maximumSeconds = 0.0
            var lastSeconds = 0.0

            mutating func record(_ seconds: Double) {
                guard seconds.isFinite, seconds >= 0 else { return }
                count += 1
                totalSeconds += seconds
                minimumSeconds = count == 1 ? seconds : min(minimumSeconds, seconds)
                maximumSeconds = max(maximumSeconds, seconds)
                lastSeconds = seconds
            }
        }

        let planVersion = 1
        let profile: Profile
        let requestedDurationSeconds: Int
        var elapsedSeconds: Double = 0
        var completedCycles = 0
        var operationCounts: [String: Int] = [:]
        var operationLatencies: [String: OperationTiming] = [:]
        var currentOperation = "starting"
        var maximumCycleSeconds: Double = 0
        var selectedPath: String?
    }

    enum Failure: String, Error {
        case connectionChanged = "soak_connection_changed"
        case connectionUnavailable = "soak_connection_unavailable"
        case cycleTooSlow = "soak_cycle_exceeded_30_seconds"
        case insufficientCoverage = "soak_insufficient_coverage"
        case pathPolicyMismatch = "soak_native_path_policy_mismatch"
    }

    let profile: Profile
    private(set) var evidence: Evidence
    private let durationSeconds: Int
    private let minimumCycles: Int
    private let interval: Duration
    private let operationTimeout: Duration
    private let requiresRelay: Bool
    private var operationDeadline = ContinuousClock.now

    init(
        profile: Profile, durationSeconds: Int? = nil, minimumCycles: Int? = nil,
        interval: Duration? = nil, operationTimeout: Duration = .seconds(30), requiresRelay: Bool = true
    ) {
        self.profile = profile
        self.durationSeconds = durationSeconds ?? profile.seconds
        self.minimumCycles = minimumCycles ?? profile.minimumCycles
        self.interval = interval ?? profile.interval
        self.operationTimeout = operationTimeout
        self.requiresRelay = requiresRelay
        evidence = Evidence(profile: profile, requestedDurationSeconds: durationSeconds ?? profile.seconds)
    }

    func run(
        clock: some Clock<Duration> = ContinuousClock(),
        marker: String,
        connection: @escaping @MainActor () async -> CmxTransportConnectionObservation?,
        probe: @escaping @MainActor (String) async throws -> MobileIrohReleaseGateProbeResult,
        stress: @escaping @MainActor (Int, String) async throws -> [String: Double]
    ) async throws -> MobileIrohReleaseGateProbeResult {
        let started = ContinuousClock.now
        operationDeadline = started.advanced(by: operationTimeout)
        // A task group would wait for an uncooperative terminal stream to finish.
        // Own both tasks explicitly, as the outer release gate does, so the report
        // can be written and the isolated app terminated even when a stream hangs.
        let results = AsyncStream<Result<MobileIrohReleaseGateProbeResult, Error>> { continuation in
            let work = Task { @MainActor in
                do {
                    continuation.yield(.success(try await self.runWorkload(
                        clock: clock, marker: marker, connection: connection, probe: probe, stress: stress
                    )))
                } catch {
                    continuation.yield(.failure(error))
                }
                continuation.finish()
            }
            let deadline = Task { @MainActor in
                do {
                    while !Task.isCancelled {
                        let observed = self.operationDeadline
                        try await Task.sleep(until: observed, clock: .continuous)
                        guard observed == self.operationDeadline else { continue }
                        self.evidence.elapsedSeconds = Self.seconds(started.duration(to: .now))
                        self.evidence.maximumCycleSeconds = max(
                            self.evidence.maximumCycleSeconds, Self.seconds(self.operationTimeout)
                        )
                        continuation.yield(.failure(Failure.cycleTooSlow))
                        continuation.finish()
                        return
                    }
                } catch { /* The operation completed or the parent was cancelled. */ }
            }
            continuation.onTermination = { _ in
                work.cancel()
                deadline.cancel()
            }
        }
        for await result in results { return try result.get() }
        throw CancellationError()
    }

    private func runWorkload(
        clock: some Clock<Duration>,
        marker: String,
        connection: () async -> CmxTransportConnectionObservation?,
        probe: (String) async throws -> MobileIrohReleaseGateProbeResult,
        stress: (Int, String) async throws -> [String: Double]
    ) async throws -> MobileIrohReleaseGateProbeResult {
        let started = clock.now
        let deadline = started.advanced(by: .seconds(durationSeconds))
        var expectedConnection = try observe(await connection())
        var last: MobileIrohReleaseGateProbeResult?
        repeat {
            try Task.checkCancellation()
            let cycleStarted = clock.now
            operationDeadline = ContinuousClock.now.advanced(by: operationTimeout)
            evidence.currentOperation = "connection_continuity"
            guard try observe(await connection()) == expectedConnection else { throw Failure.connectionChanged }
            let cycle = evidence.completedCycles
            let cycleMarker = "\(marker)_\(cycle)"
            evidence.currentOperation = "app_rpc_and_terminal_round_trip"
            last = try await probe(cycleMarker)
            try Task.checkCancellation()
            for (operation, seconds) in last?.operationLatencies ?? [:] {
                evidence.operationLatencies[operation, default: .init()].record(seconds)
            }
            for operation in ["host_status", "rpc_inventory", "terminal_round_trip", "workspace_rename_restore",
                              "independent_events", "notification_reconcile", "chat_sessions", "artifact_scan"] {
                evidence.operationCounts[operation, default: 0] += 1
            }
            guard try observe(await connection()) == expectedConnection else { throw Failure.connectionChanged }
            if profile == .stress {
                evidence.currentOperation = cycle % 120 == 119 ? "forced_reconnect" : [
                    "workspace_navigation", "unicode_output_burst", "workspace_create_close", "terminal_after_refresh",
                ][cycle % 4]
                for (operation, seconds) in try await stress(cycle, cycleMarker) {
                    try Task.checkCancellation()
                    evidence.operationCounts[operation, default: 0] += 1
                    evidence.operationLatencies[operation, default: .init()].record(seconds)
                }
                if cycle % 120 == 119 {
                    expectedConnection = try observe(await connection())
                } else if try observe(await connection()) != expectedConnection {
                    throw Failure.connectionChanged
                }
            }
            let duration = Self.seconds(cycleStarted.duration(to: clock.now))
            evidence.maximumCycleSeconds = max(evidence.maximumCycleSeconds, duration)
            guard duration <= 30 else { throw Failure.cycleTooSlow }
            evidence.completedCycles += 1
            evidence.elapsedSeconds = Self.seconds(started.duration(to: clock.now))
            evidence.currentOperation = "interval"
            // This delay defines workload cadence, not readiness synchronization.
            try await clock.sleep(until: min(deadline, cycleStarted.advanced(by: interval)), tolerance: nil)
        } while clock.now < deadline
        // A final transaction proves the terminal is still live at the end of the window.
        evidence.currentOperation = "final_terminal_round_trip"
        operationDeadline = ContinuousClock.now.advanced(by: operationTimeout)
        guard try observe(await connection()) == expectedConnection else { throw Failure.connectionChanged }
        last = try await probe("\(marker)_FINAL")
        try Task.checkCancellation()
        for (operation, seconds) in last?.operationLatencies ?? [:] {
            evidence.operationLatencies[operation, default: .init()].record(seconds)
        }
        guard try observe(await connection()) == expectedConnection else { throw Failure.connectionChanged }
        evidence.elapsedSeconds = Self.seconds(started.duration(to: clock.now))
        guard evidence.completedCycles >= minimumCycles, let last else {
            throw Failure.insufficientCoverage
        }
        evidence.currentOperation = "complete"
        return last
    }

    private func observe(_ connection: CmxTransportConnectionObservation?) throws -> UInt64 {
        guard let connection else { throw Failure.connectionUnavailable }
        switch connection.pathKind {
        case .relay:
            evidence.selectedPath = "relay"
        case .direct where !requiresRelay:
            evidence.selectedPath = "direct"
        default:
            throw Failure.pathPolicyMismatch
        }
        return connection.continuityID
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
#endif
