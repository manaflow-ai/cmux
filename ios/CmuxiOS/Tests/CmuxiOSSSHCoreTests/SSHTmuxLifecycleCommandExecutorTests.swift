@testable import CmuxiOSSSHCore
import CmuxMobileWire
import Foundation
import Testing

@Suite struct SSHTmuxLifecycleCommandExecutorTests {
    private let epoch = SSHTmuxServerEpoch(serverPID: 42, serverStart: 1_793_331_200)!

    private actor Runner: SSHCommandRunning {
        var inputs: [String] = []
        let output: String
        init(output: String) { self.output = output }
        func run(_ command: String, input: String?) async throws -> String {
            inputs.append(input ?? "")
            return output
        }
    }

    @Test func createParsesHostIssuedIDsAndChecksEpochInScript() async throws {
        let runner = Runner(output: "CMUX_WINDOW\t@12\t$7\n")
        let executor = SSHTmuxLifecycleCommandExecutor(runner: runner)
        let mutation = SSHTmuxLifecycleMutation.createWindow(server: epoch, sessionID: "$7", name: "editor")
        let result = try await executor.execute(mutation)
        #expect(result.value == .object(["window_id": .string("@12"), "session_id": .string("$7")]))
        #expect(result.revision == "tmux:42:1793331200:@12")
        let script = await runner.inputs.first ?? ""
        #expect(script.contains("expected_pid='42'"))
        #expect(script.contains("expected_start='1793331200'"))
        #expect(script.contains("new-window"))
        #expect(script.contains("-t '$7'"))
    }

    @Test func renameAndKillRequireAcknowledgement() async throws {
        let renameRunner = Runner(output: "CMUX_OK\n")
        let rename = SSHTmuxLifecycleCommandExecutor(runner: renameRunner)
        let renamed = try await rename.execute(.renameWindow(server: epoch, windowID: "@12", name: "new"))
        #expect(renamed.value == .null)

        let killRunner = Runner(output: "CMUX_OK\n")
        let kill = SSHTmuxLifecycleCommandExecutor(runner: killRunner)
        let killed = try await kill.execute(.killWindow(server: epoch, windowID: "@12"))
        #expect(killed.value == .null)
        #expect(killed.revision == "tmux:42:1793331200:@12")
    }

    @Test func malformedHostOutputIsRefused() async {
        let runner = Runner(output: "CMUX_WINDOW\tbad\t$7\n")
        let executor = SSHTmuxLifecycleCommandExecutor(runner: runner)
        await #expect(throws: SSHTmuxLifecycleCommandExecutor.Error.malformedResult) {
            try await executor.execute(.createWindow(server: epoch, sessionID: "$7", name: nil))
        }
    }
}
