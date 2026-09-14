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
        let link = CloudMachineLink(
            machineID: "fixture", clientURL: URL(fileURLWithPath: "/bin/sleep"), paths: CloudTuiClientPaths()
        )
        do {
            _ = try await recorder.perform(.workspace, foreground: false) {
                try await link.run(arguments: ["30"], timeout: .milliseconds(30))
            }
            Issue.record("a command deadline must fail the operation")
        } catch CloudMachineLink.LinkError.commandTimedOut {}
        let failed = try #require(recorder.operations.first)
        #expect(!failed.isRunning)
        #expect(failed.outcome == .timeout)
        #expect(failed.failure == .timeout)
        #expect(failed.steps.first?.failure == .timeout)
        #expect(failed.isVisibleInMachinesPanel)
        #expect(CloudTuiDaemonAnswer(error: CloudMachineLink.LinkError.commandTimedOut).isRetryable)

        let success = recorder.begin(.workspace)
        await recorder.finish(success)
        #expect(recorder.operations.first?.id == failed.id)
        #expect(recorder.operations.first?.isVisibleInMachinesPanel == true)
        recorder.dismiss(failed.id)
        #expect(recorder.operations.allSatisfy { !$0.isVisibleInMachinesPanel })
    }
}
