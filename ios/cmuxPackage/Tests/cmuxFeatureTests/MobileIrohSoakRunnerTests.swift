#if os(iOS) && DEBUG
import CmuxMobileShellReleaseGateSupport
import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohReleaseGateSupport

@MainActor
struct MobileIrohSoakRunnerTests {
    private let relay = CmxTransportConnectionObservation(continuityID: 1, pathKind: .relay)
    private let probe = MobileIrohReleaseGateProbeResult(
        hostStatusVerified: true, rpcMethodInventoryVerified: true, terminalRoundTripVerified: true,
        workspaceMutationVerified: true, independentEventsVerified: true,
        notificationReconcileVerified: true, chatSessionsVerified: true, artifactScanCountVerified: true
    )

    @Test func recordsProbeAndUsageLatencies() async throws {
        let timedProbe = MobileIrohReleaseGateProbeResult(
            hostStatusVerified: true, rpcMethodInventoryVerified: true, terminalRoundTripVerified: true,
            workspaceMutationVerified: true, independentEventsVerified: true,
            notificationReconcileVerified: true, chatSessionsVerified: true, artifactScanCountVerified: true,
            operationLatencies: ["host_status": 0.1]
        )
        let runner = MobileIrohSoakRunner(profile: .stress, durationSeconds: 0, minimumCycles: 1)
        _ = try await runner.run(marker: "test", connection: { relay }, probe: { _ in timedProbe },
                                 stress: { _, _ in ["workspace_refresh": 0.2] })
        let host = runner.evidence.operationLatencies["host_status"]
        #expect(host?.count == 2)
        #expect(host?.totalSeconds == 0.2)
        let refresh = runner.evidence.operationLatencies["workspace_refresh"]
        #expect(refresh?.count == 1)
        #expect(refresh?.lastSeconds == 0.2)
    }

    @Test func completionRequiresFinalTransaction() async throws {
        let runner = MobileIrohSoakRunner(profile: .basic, durationSeconds: 0, minimumCycles: 1)
        var markers: [String] = []
        _ = try await runner.run(marker: "test", connection: { relay }, probe: { marker in
            markers.append(marker)
            return probe
        }, stress: { _, _ in Issue.record("basic must not reconnect"); return [:] })
        #expect(markers == ["test_0", "test_FINAL"])
        #expect(runner.evidence.completedCycles == 1)
        #expect(runner.evidence.currentOperation == "complete")
        #expect(runner.evidence.operationCounts["terminal_round_trip"] == 1)
    }

    @Test func redialCannotHideDroppedConnection() async {
        let runner = MobileIrohSoakRunner(profile: .basic, durationSeconds: 0, minimumCycles: 1)
        var connectionID: UInt64 = 1
        await #expect(throws: MobileIrohSoakRunner.Failure.connectionChanged) {
            try await runner.run(marker: "test", connection: {
                .init(continuityID: connectionID, pathKind: .relay)
            }, probe: { _ in
                connectionID = 2
                return probe
            }, stress: { _, _ in [:] })
        }
        #expect(runner.evidence.completedCycles == 0)
    }

    @Test func insufficientWorkCannotPass() async {
        let runner = MobileIrohSoakRunner(profile: .basic, durationSeconds: 0, minimumCycles: 2)
        await #expect(throws: MobileIrohSoakRunner.Failure.insufficientCoverage) {
            try await runner.run(marker: "test", connection: { relay }, probe: { _ in probe }, stress: { _, _ in [:] })
        }
        #expect(runner.evidence.currentOperation != "complete")
    }

    @Test func failedTerminalIsNotCounted() async {
        let runner = MobileIrohSoakRunner(profile: .stress, durationSeconds: 0, minimumCycles: 1)
        await #expect(throws: MobileIrohReleaseGateProbeFailure.terminalRoundTripFailed) {
            try await runner.run(marker: "test", connection: { relay }, probe: { _ in
                throw MobileIrohReleaseGateProbeFailure.terminalRoundTripFailed
            }, stress: { _, _ in Issue.record("usage continued after failure"); return [:] })
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
            try await runner.run(marker: "test", connection: { relay }, probe: { _ in
                await withCheckedContinuation { suspended = $0 }
            }, stress: { _, _ in [:] })
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
            try await runner.run(marker: "test", connection: { relay }, probe: { marker in
                if marker.hasSuffix("FINAL") {
                    return await withCheckedContinuation { suspended = $0 }
                }
                return probe
            }, stress: { _, _ in [:] })
        }
        #expect(runner.evidence.completedCycles == 1)
        #expect(runner.evidence.currentOperation == "final_terminal_round_trip")
        suspended?.resume(returning: probe)
    }

    @Test(arguments: [DiagnosticPathKind.unknown, .direct])
    func relayCheckRejectsMissingOrDirectNativePath(path: DiagnosticPathKind) async {
        let runner = MobileIrohSoakRunner(profile: .basic, durationSeconds: 0, minimumCycles: 1)
        await #expect(throws: MobileIrohSoakRunner.Failure.pathPolicyMismatch) {
            try await runner.run(marker: "test", connection: {
                .init(continuityID: 1, pathKind: path)
            }, probe: { _ in Issue.record("probe ran without relay evidence"); return probe }, stress: { _, _ in [:] })
        }
        #expect(runner.evidence.completedCycles == 0)
    }

    @Test func relayPathMustRemainSelectedAfterTransaction() async {
        let runner = MobileIrohSoakRunner(profile: .basic, durationSeconds: 0, minimumCycles: 1)
        var path = DiagnosticPathKind.relay
        await #expect(throws: MobileIrohSoakRunner.Failure.pathPolicyMismatch) {
            try await runner.run(marker: "test", connection: {
                .init(continuityID: 1, pathKind: path)
            }, probe: { _ in path = .direct; return probe }, stress: { _, _ in [:] })
        }
        #expect(runner.evidence.completedCycles == 0)
    }
}
#endif
