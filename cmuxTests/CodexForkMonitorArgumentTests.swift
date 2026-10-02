import Foundation
import Testing
import CMUXAgentLaunch

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct CodexForkMonitorArgumentTests {
    @Test
    func forwardsForkParentClaimToDetachedMonitor() {
        let arguments = CodexForkMonitorArguments().make(environment: [
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
        #expect(CodexForkMonitorArguments().make(environment: [:]).isEmpty)
    }
}
