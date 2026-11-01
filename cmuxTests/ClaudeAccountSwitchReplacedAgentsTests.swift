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

    @Test
    func stillRunningListsOnlyTheRecordedGenerations() {
        let reusedHelper = AgentPIDProcessIdentity(pid: helper.pid, startSeconds: 300, startMicroseconds: 0)
        #expect(agents([claude.pid: paneTTY, helper.pid: paneTTY]).stillRunning == [claude, helper])
        #expect(agents([claude.pid: paneTTY, helper.pid: paneTTY], running: [claude, reusedHelper]).stillRunning == [claude])
        #expect(agents([claude.pid: paneTTY, helper.pid: paneTTY], running: []).stillRunning.isEmpty)
    }
}
