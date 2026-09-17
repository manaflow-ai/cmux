import Darwin
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct AgentQuitProcessCleanupTests {
    private let app: pid_t = 100
    private let child = AgentPIDProcessIdentity(pid: 102, startSeconds: 20, startMicroseconds: 0)

    @Test func quitCanOnlySignalTheSameGenerationUnderThisApp() {
        let shell = AgentPIDProcessIdentity(pid: 101, startSeconds: 19, startMicroseconds: 0)
        #expect(AgentQuitProcessCleanup.isDescendant(child, of: app) { pid in
            switch pid {
            case 102: return (child, shell.pid)
            case 101: return (shell, app)
            default: return nil
            }
        })
        #expect(!AgentQuitProcessCleanup.isDescendant(child, of: app) { _ in
            (AgentPIDProcessIdentity(pid: child.pid, startSeconds: 21, startMicroseconds: 0), app)
        })
    }

    @Test(arguments: [pid_t(1), pid_t(999), pid_t(102)])
    func externalOrOrphanedWritersAreNotQuitTargets(parent: pid_t) {
        #expect(!AgentQuitProcessCleanup.isDescendant(child, of: app) { pid in
            pid == child.pid ? (child, parent) : nil
        })
    }

    @Test func unreadableAncestryFailsClosed() {
        #expect(!AgentQuitProcessCleanup.isDescendant(child, of: app) { _ in nil })
    }

    @Test func signalPhaseTimeoutKeepsThePreSignalSnapshot() {
        #expect(AppDelegate.terminateCleanupDeadlineDisposition(
            phase: .agentProcesses, hasOwnedRuntimeCleanup: false
        ) == .terminateWithSavedSnapshot)
        #expect(AppDelegate.terminateCleanupDeadlineDisposition(
            phase: .agentProcesses, hasOwnedRuntimeCleanup: true
        ) == .terminateWithSavedSnapshot)
        #expect(AppDelegate.terminateCleanupDeadlineDisposition(
            phase: .freshSnapshot, hasOwnedRuntimeCleanup: true
        ) == .persistCachedSnapshotAndTerminate)
        #expect(AppDelegate.terminateCleanupDeadlineDisposition(
            phase: .ownedRuntimeCleanup, hasOwnedRuntimeCleanup: true
        ) == .cancelTerminationAfterRuntimeCleanupFailure)
    }
}
