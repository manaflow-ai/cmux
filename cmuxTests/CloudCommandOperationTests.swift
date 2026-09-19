import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct CloudCommandOperationTests {
    @Test func commandTimeoutLeavesRecoverableOperationVisibleAfterLaterSuccess() async throws {
        let recorder = CloudOperationRecorder()
        let clock = CloudCommandDeadlineClock()
        try await CloudTuiManualIOConnectionTests.withResourceConnection(clock: clock) { channel, peer in
            let command = Task {
                try await recorder.perform(.workspace, foreground: false) {
                    try await channel.request(CloudTuiRequest("session.ping"), timeout: .seconds(30))
                }
            }
            defer { command.cancel() }
            _ = try await CloudTuiManualIOConnectionTests.blocking {
                try CloudTuiManualIOConnectionTests.readLine(peer)
            }
            await clock.waitUntilSleeping()
            clock.advance(by: .seconds(30))
            do {
                _ = try await command.value
                Issue.record("a command deadline must fail the operation")
            } catch CloudMachineLink.LinkError.timedOut {}
        }
        let failed = try #require(recorder.operations.first)
        #expect(!failed.isRunning)
        #expect(failed.outcome == .timeout)
        #expect(failed.failure == .timeout)
        #expect(failed.isVisibleInMachinesPanel)
        #expect(CloudTuiDaemonAnswer(error: CloudMachineLink.LinkError.timedOut).isRetryable)

        let success = recorder.begin(.workspace)
        await recorder.finish(success)
        #expect(recorder.operations.first?.id == failed.id)
        #expect(recorder.operations.first?.isVisibleInMachinesPanel == true)
        recorder.dismiss(failed.id)
        #expect(recorder.operations.allSatisfy { !$0.isVisibleInMachinesPanel })
    }
}
