import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct CodexForkMonitorArgumentTests {
    @Test
    func forwardsForkParentClaimToDetachedMonitor() {
        let arguments = CMUXCLI.codexForkMonitorArguments(environment: [
            "CMUX_AGENT_FORK_PARENT_SESSION_ID": "parent-session",
            "CMUX_AGENT_FORK_LAUNCH_ID": "launch-id",
            "CMUX_CODEX_PID": "1234",
        ])

        #expect(arguments == [
            "--fork-parent", "parent-session",
            "--fork-launch-id", "launch-id",
            "--fork-owner-pid", "1234",
        ])
    }

    @Test
    func omitsForkArgumentsForNormalCodexMonitor() {
        #expect(CmuxTuiRemoteRouting.codexForkMonitorArguments(environment: [:]).isEmpty)
    }
    @Test
    func omitsForkArgumentsWithoutValidParent() {
        for parent in [String?.none, ""] {
            var environment = ["CMUX_AGENT_FORK_LAUNCH_ID": "launch-id", "CMUX_CODEX_PID": "1234"]
            environment["CMUX_AGENT_FORK_PARENT_SESSION_ID"] = parent
            #expect(CmuxTuiRemoteRouting.codexForkMonitorArguments(environment: environment).isEmpty)
        }
    }

    @Test
    func omitsEmptyOptionalForkMetadata() {
        #expect(CmuxTuiRemoteRouting.codexForkMonitorArguments(environment: [
            "CMUX_AGENT_FORK_PARENT_SESSION_ID": "parent-session",
            "CMUX_AGENT_FORK_LAUNCH_ID": "",
            "CMUX_CODEX_PID": "",
        ]) == ["--fork-parent", "parent-session"])
    }

}
