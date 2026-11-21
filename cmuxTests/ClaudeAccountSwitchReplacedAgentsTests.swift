import CmuxFoundation
import Darwin
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A Claude account switch stops the pane's Claude by closing the pane's terminal. A Claude that
/// would survive that (inside tmux or screen, or detached) is refused before anything changes, and
/// one still running after the exit wait gets no resume typed, so one session never runs twice.
struct ClaudeAccountSwitchReplacedAgentsTests {
    private let paneTTY: Int64 = 0x1000_0003
    private let tmuxTTY: Int64 = 0x1000_0009
    private let claude = AgentPIDProcessIdentity(pid: 4101, startSeconds: 100, startMicroseconds: 1)
    private let helper = AgentPIDProcessIdentity(pid: 4102, startSeconds: 100, startMicroseconds: 2)

    /// Processes that are all running, with the given controlling terminals.
    private func agents(
        _ ttyByPID: [pid_t: Int64?],
        running: [AgentPIDProcessIdentity]? = nil
    ) -> ClaudeAccountSwitchReplacedAgents {
        let processes = [claude, helper].filter { ttyByPID.keys.contains($0.pid) }
        let alive = running ?? processes
        return ClaudeAccountSwitchReplacedAgents(
            processes: processes,
            currentIdentity: { pid in alive.first { $0.pid == pid } },
            controllingTTYDevice: { pid in ttyByPID[pid] ?? nil }
        )
    }

    @Test
    func claudeOnThePaneTerminalIsOwnedByThePane() {
        #expect(agents([claude.pid: paneTTY]).ownership(paneTTYDevice: paneTTY) == .ownedByPane)
        #expect(agents([claude.pid: paneTTY, helper.pid: paneTTY]).ownership(paneTTYDevice: paneTTY) == .ownedByPane)
    }

    @Test
    func claudeInsideTmuxIsNotOwnedByThePane() {
        // tmux gives the Claude its own PTY; closing the pane leaves it running.
        #expect(agents([claude.pid: tmuxTTY]).ownership(paneTTYDevice: paneTTY) == .notOwnedByPane)
    }

    @Test
    func detachedClaudeIsNotOwnedByThePane() {
        #expect(agents([claude.pid: nil]).ownership(paneTTYDevice: paneTTY) == .notOwnedByPane)
    }

    @Test
    func oneForeignProcessIsEnoughToRefuse() {
        #expect(agents([claude.pid: paneTTY, helper.pid: tmuxTTY]).ownership(paneTTYDevice: paneTTY) == .notOwnedByPane)
    }

    @Test
    func anUnknownPaneTerminalFailsClosed() {
        #expect(agents([claude.pid: paneTTY]).ownership(paneTTYDevice: nil) == .notOwnedByPane)
    }

    @Test
    func exitedProcessesNeedNoOwnership() {
        // The recorded Claude already exited (a reused pid is a different generation): nothing
        // outlives the switch, whatever terminal the pid's new owner has.
        let reused = AgentPIDProcessIdentity(pid: claude.pid, startSeconds: 200, startMicroseconds: 0)
        #expect(agents([claude.pid: tmuxTTY], running: []).ownership(paneTTYDevice: paneTTY) == .noLiveAgent)
        #expect(agents([claude.pid: tmuxTTY], running: [reused]).ownership(paneTTYDevice: nil) == .noLiveAgent)
        #expect(agents([:]).ownership(paneTTYDevice: paneTTY) == .noLiveAgent)
        // A gone helper does not hide a foreign Claude, and does not count against an owned one.
        #expect(agents([claude.pid: paneTTY, helper.pid: tmuxTTY], running: [claude])
            .ownership(paneTTYDevice: paneTTY) == .ownedByPane)
    }

    // MARK: A Claude the pane's record does not name

    private let sessionOwner = AgentPIDProcessIdentity(pid: 4201, startSeconds: 120, startMicroseconds: 7)

    /// No recorded process: only `owner` runs, on `ownerTTY`.
    private func unrecordedPane(owner ownerTTY: Int64?) -> ClaudeAccountSwitchReplacedAgents {
        let owner = sessionOwner
        return ClaudeAccountSwitchReplacedAgents(
            processes: [],
            currentIdentity: { pid in pid == owner.pid ? owner : nil },
            controllingTTYDevice: { pid in pid == owner.pid ? ownerTTY : nil }
        )
    }

    /// Hooks that never reported a pid leave the pane's record empty. The session's live owners
    /// from the agent index are checked too, so "can't tell" never becomes "nothing to stop".
    @Test
    func aLiveSessionOwnerOnAnotherTerminalIsNotOwnedByThePane() {
        let agents = unrecordedPane(owner: tmuxTTY).including(liveSessionOwners: [sessionOwner])

        #expect(agents.ownership(paneTTYDevice: paneTTY) == .notOwnedByPane)
        #expect(unrecordedPane(owner: nil).including(liveSessionOwners: [sessionOwner])
            .ownership(paneTTYDevice: paneTTY) == .notOwnedByPane)
    }

    @Test
    func aLiveSessionOwnerOnThePaneTerminalIsWaitedForLikeARecordedOne() {
        let agents = unrecordedPane(owner: paneTTY).including(liveSessionOwners: [sessionOwner])

        #expect(agents.ownership(paneTTYDevice: paneTTY) == .ownedByPane)
        #expect(agents.processes == [sessionOwner])
        #expect(agents.stillRunning == [sessionOwner])
    }

    @Test
    func aPaneWhoseSessionRunsNowhereStillSwitches() {
        // A restored pane whose session has not started again: nothing to stop, nothing to refuse.
        let agents = unrecordedPane(owner: tmuxTTY).including(liveSessionOwners: [])

        #expect(agents.ownership(paneTTYDevice: paneTTY) == .noLiveAgent)
        #expect(agents.processes.isEmpty)
    }

    /// The pane's own Claude is running, and a second Claude runs the same session in another
    /// terminal. Restarting the pane stops only the first, so the resumed one would be a second
    /// writer: the switch refuses.
    @Test
    func aSecondClaudeOnTheSessionInAnotherTerminalIsNotOwnedByThePane() {
        let owner = sessionOwner
        let recorded = ClaudeAccountSwitchReplacedAgents(
            processes: [claude],
            currentIdentity: { pid in [claude, owner].first { $0.pid == pid } },
            controllingTTYDevice: { pid in pid == owner.pid ? tmuxTTY : paneTTY }
        )
        let checked = recorded.including(liveSessionOwners: [owner])

        #expect(checked.ownership(paneTTYDevice: paneTTY) == .notOwnedByPane)
    }

    /// The index names the pane's own Claude as the session's owner: nothing is added.
    @Test
    func theRecordedClaudeAsTheSessionOwnerIsCountedOnce() {
        let checked = agents([claude.pid: paneTTY]).including(liveSessionOwners: [claude])

        #expect(checked.processes == [claude])
        #expect(checked.ownership(paneTTYDevice: paneTTY) == .ownedByPane)
    }

    // MARK: A Claude that started during the switch

    /// The transcript copy is awaited, and a Claude can start in the pane meanwhile. Restarting
    /// the pane would kill it and resume the old session in its place, so it is reported.
    @Test
    func aClaudeThatStartedSinceTheFirstCheckIsReported() {
        let restarted = AgentPIDProcessIdentity(pid: 4103, startSeconds: 150, startMicroseconds: 0)
        let reusedPID = AgentPIDProcessIdentity(pid: claude.pid, startSeconds: 200, startMicroseconds: 0)
        let before = agents([claude.pid: paneTTY])
        func now(_ running: [AgentPIDProcessIdentity]) -> ClaudeAccountSwitchReplacedAgents {
            ClaudeAccountSwitchReplacedAgents(
                processes: running,
                currentIdentity: { pid in running.first { $0.pid == pid } },
                controllingTTYDevice: { _ in paneTTY }
            )
        }

        #expect(now([restarted]).startedProcesses(since: before) == [restarted])
        // A pid the old Claude had, but a new process generation, is a new Claude too.
        #expect(now([reusedPID]).startedProcesses(since: before) == [reusedPID])
        #expect(now([claude, restarted]).startedProcesses(since: before) == [restarted])
    }

    @Test
    func theSameOrNoClaudeIsNotANewOne() {
        let before = agents([claude.pid: paneTTY, helper.pid: paneTTY])

        #expect(agents([claude.pid: paneTTY]).startedProcesses(since: before).isEmpty)
        #expect(agents([:]).startedProcesses(since: before).isEmpty)
        // A recorded process that has exited since is gone, not new.
        #expect(agents([claude.pid: paneTTY, helper.pid: paneTTY], running: [claude])
            .startedProcesses(since: before).isEmpty)
    }

    @Test
    func stillRunningListsOnlyTheRecordedGenerations() {
        let reusedHelper = AgentPIDProcessIdentity(pid: helper.pid, startSeconds: 300, startMicroseconds: 0)
        #expect(agents([claude.pid: paneTTY, helper.pid: paneTTY]).stillRunning == [claude, helper])
        #expect(agents([claude.pid: paneTTY, helper.pid: paneTTY], running: [claude, reusedHelper]).stillRunning == [claude])
        #expect(agents([claude.pid: paneTTY, helper.pid: paneTTY], running: []).stillRunning.isEmpty)
    }
}
