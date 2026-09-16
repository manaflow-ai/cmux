#if os(iOS) && DEBUG
import CmuxMobileShellReleaseGateSupport
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
        let planVersion = 1
        let profile: Profile
        let requestedDurationSeconds: Int
        var elapsedSeconds: Double = 0
        var completedCycles = 0
        var operationCounts: [String: Int] = [:]
        var currentOperation = "starting"
        var maximumCycleSeconds: Double = 0
    }

    enum Failure: String, Error {
        case connectionChanged = "soak_connection_changed"
        case connectionUnavailable = "soak_connection_unavailable"
        case cycleTooSlow = "soak_cycle_exceeded_30_seconds"
        case insufficientCoverage = "soak_insufficient_coverage"
    }

    let profile: Profile
    private(set) var evidence: Evidence
    private let durationSeconds: Int
    private let minimumCycles: Int
    private let interval: Duration

    init(profile: Profile, durationSeconds: Int? = nil, minimumCycles: Int? = nil, interval: Duration? = nil) {
        self.profile = profile
        self.durationSeconds = durationSeconds ?? profile.seconds
        self.minimumCycles = minimumCycles ?? profile.minimumCycles
        self.interval = interval ?? profile.interval
        evidence = Evidence(profile: profile, requestedDurationSeconds: durationSeconds ?? profile.seconds)
    }

    func run(
        clock: some Clock<Duration> = ContinuousClock(),
        marker: String,
        connection: () async -> UInt64?,
        probe: (String) async throws -> MobileIrohReleaseGateProbeResult,
        stress: (Int, String) async throws -> [String]
    ) async throws -> MobileIrohReleaseGateProbeResult {
        let started = clock.now
        let deadline = started.advanced(by: .seconds(durationSeconds))
        var expectedConnection = await connection()
        guard expectedConnection != nil else { throw Failure.connectionUnavailable }
        var last: MobileIrohReleaseGateProbeResult?
        repeat {
            try Task.checkCancellation()
            let cycleStarted = clock.now
            evidence.currentOperation = "connection_continuity"
            guard await connection() == expectedConnection else { throw Failure.connectionChanged }
            let cycle = evidence.completedCycles
            let cycleMarker = "\(marker)_\(cycle)"
            evidence.currentOperation = "app_rpc_and_terminal_round_trip"
            last = try await probe(cycleMarker)
            for operation in ["host_status", "rpc_inventory", "terminal_round_trip", "workspace_rename_restore",
                              "independent_events", "notification_reconcile", "chat_sessions", "artifact_scan"] {
                evidence.operationCounts[operation, default: 0] += 1
            }
            guard await connection() == expectedConnection else { throw Failure.connectionChanged }
            if profile == .stress {
                evidence.currentOperation = "usage_step_\(cycle % 4)"
                for operation in try await stress(cycle, cycleMarker) {
                    evidence.operationCounts[operation, default: 0] += 1
                }
                if cycle % 120 == 119 {
                    expectedConnection = await connection()
                    guard expectedConnection != nil else { throw Failure.connectionUnavailable }
                } else if await connection() != expectedConnection {
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
        guard await connection() == expectedConnection else { throw Failure.connectionChanged }
        last = try await probe("\(marker)_FINAL")
        guard await connection() == expectedConnection else { throw Failure.connectionChanged }
        evidence.elapsedSeconds = Self.seconds(started.duration(to: clock.now))
        guard evidence.completedCycles >= minimumCycles, let last else {
            throw Failure.insufficientCoverage
        }
        evidence.currentOperation = "complete"
        return last
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
#endif
