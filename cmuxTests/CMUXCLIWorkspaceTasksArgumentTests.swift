import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized) struct CMUXCLIWorkspaceTasksArgumentTests {
    @Test func listAndOpenRejectConflictingWorkspaceTargets() throws {
        let helper = CMUXCLIErrorOutputRegressionTests()
        let cliPath = try helper.bundledCLIPath()
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "0.1"

        let listResult = helper.runProcess(
            executablePath: cliPath,
            arguments: [
                "workspace", "tasks", "list",
                "--workspace", "workspace:1",
                "workspace:2",
            ],
            environment: environment,
            timeout: 5
        )

        #expect(!listResult.timedOut)
        #expect(listResult.status == 1)
        #expect(listResult.stdout.contains("workspace tasks list accepts at most one workspace handle"))

        let openResult = helper.runProcess(
            executablePath: cliPath,
            arguments: [
                "workspace", "tasks", "open",
                "--workspace", "workspace:1",
                "workspace:2",
            ],
            environment: environment,
            timeout: 5
        )

        #expect(!openResult.timedOut)
        #expect(openResult.status == 1)
        #expect(openResult.stdout.contains("workspace tasks open accepts at most one workspace handle"))
    }
}
