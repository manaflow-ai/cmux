#if os(iOS) && DEBUG
import CmuxMobileShellReleaseGateSupport
import Foundation
import Testing
@testable import CmuxIrohReleaseGateSupport

@MainActor
struct MobileIrohSoakRunnerTests {
    private let probe = MobileIrohReleaseGateProbeResult(
        hostStatusVerified: true, rpcMethodInventoryVerified: true, terminalRoundTripVerified: true,
        workspaceMutationVerified: true, independentEventsVerified: true,
        notificationReconcileVerified: true, chatSessionsVerified: true, artifactScanCountVerified: true
    )

    @Test func completionRequiresFinalTransaction() async throws {
        let runner = MobileIrohSoakRunner(profile: .basic, durationSeconds: 0, minimumCycles: 1)
        var markers: [String] = []
        _ = try await runner.run(marker: "test", connection: { 1 }, probe: { marker in
            markers.append(marker)
            return probe
        }, stress: { _, _ in Issue.record("basic must not reconnect"); return [] })
        #expect(markers == ["test_0", "test_FINAL"])
        #expect(runner.evidence.completedCycles == 1)
        #expect(runner.evidence.currentOperation == "complete")
        #expect(runner.evidence.operationCounts["terminal_round_trip"] == 1)
    }

    @Test func redialCannotHideDroppedConnection() async {
        let runner = MobileIrohSoakRunner(profile: .basic, durationSeconds: 0, minimumCycles: 1)
        var connectionID: UInt64 = 1
        await #expect(throws: MobileIrohSoakRunner.Failure.connectionChanged) {
            try await runner.run(marker: "test", connection: { connectionID }, probe: { _ in
                connectionID = 2
                return probe
            }, stress: { _, _ in [] })
        }
        #expect(runner.evidence.completedCycles == 0)
    }

    @Test func insufficientWorkCannotPass() async {
        let runner = MobileIrohSoakRunner(profile: .basic, durationSeconds: 0, minimumCycles: 2)
        await #expect(throws: MobileIrohSoakRunner.Failure.insufficientCoverage) {
            try await runner.run(marker: "test", connection: { 1 }, probe: { _ in probe }, stress: { _, _ in [] })
        }
        #expect(runner.evidence.currentOperation != "complete")
    }

    @Test func failedTerminalIsNotCounted() async {
        let runner = MobileIrohSoakRunner(profile: .stress, durationSeconds: 0, minimumCycles: 1)
        await #expect(throws: MobileIrohReleaseGateProbeFailure.terminalRoundTripFailed) {
            try await runner.run(marker: "test", connection: { 1 }, probe: { _ in
                throw MobileIrohReleaseGateProbeFailure.terminalRoundTripFailed
            }, stress: { _, _ in Issue.record("usage continued after failure"); return [] })
        }
        #expect(runner.evidence.completedCycles == 0)
        #expect(runner.evidence.operationCounts.isEmpty)
    }

    @Test func stalledOperationReportsWithoutWaitingForCooperation() async throws {
        let runner = MobileIrohSoakRunner(
            profile: .stress, durationSeconds: 0, minimumCycles: 1,
            operationTimeout: .milliseconds(20)
        )
        var suspended: CheckedContinuation<MobileIrohReleaseGateProbeResult, Never>?
        await #expect(throws: MobileIrohSoakRunner.Failure.cycleTooSlow) {
            try await runner.run(marker: "test", connection: { 1 }, probe: { _ in
                await withCheckedContinuation { suspended = $0 }
            }, stress: { _, _ in [] })
        }
        #expect(runner.evidence.completedCycles == 0)
        #expect(runner.evidence.currentOperation == "app_rpc_and_terminal_round_trip")
        // Release the deliberately uncooperative operation after the deadline wins.
        suspended?.resume(returning: probe)
    }

    @Test func finalTransactionAlsoHasADeadline() async {
        let runner = MobileIrohSoakRunner(
            profile: .basic, durationSeconds: 0, minimumCycles: 1,
            operationTimeout: .milliseconds(20)
        )
        var suspended: CheckedContinuation<MobileIrohReleaseGateProbeResult, Never>?
        await #expect(throws: MobileIrohSoakRunner.Failure.cycleTooSlow) {
            try await runner.run(marker: "test", connection: { 1 }, probe: { marker in
                if marker.hasSuffix("FINAL") {
                    return await withCheckedContinuation { suspended = $0 }
                }
                return probe
            }, stress: { _, _ in [] })
        }
        #expect(runner.evidence.completedCycles == 1)
        #expect(runner.evidence.currentOperation == "final_terminal_round_trip")
        suspended?.resume(returning: probe)
    }
}
#endif
