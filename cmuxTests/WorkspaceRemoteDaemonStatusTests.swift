import CmuxCore
import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Workspace remote daemon status")
struct WorkspaceRemoteDaemonStatusTests {
    @Test(
        "Ready retracts the recovered daemon error from the sidebar",
        arguments: [
            "Remote daemon transport needs re-bootstrap after proxy failure (retry 1 in 2s)",
            "Remote daemon bootstrap failed: incompatible daemon",
            "Remote reverse relay unavailable; retrying",
        ]
    )
    func readyRetractsRecoveredDaemonError(errorDetail: String) {
        let workspace = Workspace()
        let unrelatedLog = SidebarLogEntry(
            message: "Unrelated workspace log",
            level: .info,
            source: "test",
            timestamp: Date(timeIntervalSince1970: 1)
        )
        workspace.logEntries = [unrelatedLog]

        workspace.applyRemoteDaemonStatusUpdate(
            WorkspaceRemoteDaemonStatus(state: .error, detail: errorDetail),
            target: "example-host"
        )

        #expect(workspace.remoteDaemonStatus.state == .error)
        #expect(workspace.logEntries.last?.source == "remote-daemon")
        #expect(
            workspace.sessionSnapshot(includeScrollback: false).logEntries
                .contains(where: { $0.source == "remote-daemon" })
        )

        workspace.applyRemoteDaemonStatusUpdate(
            WorkspaceRemoteDaemonStatus(state: .ready, detail: "Remote daemon ready"),
            target: "example-host"
        )

        #expect(workspace.remoteDaemonStatus.state == .ready)
        #expect(workspace.logEntries == [unrelatedLog])
        #expect(
            !workspace.sessionSnapshot(includeScrollback: false).logEntries
                .contains(where: { $0.source == "remote-daemon" })
        )
    }
}
