import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `claude_account.switch` refuses what can never succeed before it asks for `force`, so the
/// `--force` hint only appears for a switch that would really stop a running response.
struct ClaudeAccountSwitchSocketPreflightTests {
    private let home = "/Users/cmux-test"
    private let defaultAccount = ClaudeAccount(name: "default", configDirectory: nil, isRegistered: true)
    private let work = ClaudeAccount(name: "work", configDirectory: "/Users/cmux-test/.claude-work", isRegistered: true)

    @Test
    func anUnknownAccountIsRefusedFirst() {
        let preflight = makePreflight(target: nil, current: work, remote: true, running: true)

        #expect(preflight.refusal == .finished(.refused(.unknownAccount("work"))))
    }

    @Test
    func aRemotePaneIsRefusedBeforeAskingForForce() {
        let preflight = makePreflight(target: work, current: defaultAccount, remote: true, running: true)

        #expect(preflight.refusal == .finished(.remoteUnsupported))
    }

    @Test
    func thePanesOwnAccountIsRefusedBeforeAskingForForce() {
        let preflight = makePreflight(target: work, current: work, remote: false, running: true)

        #expect(preflight.refusal == .finished(.refused(.sameAccount("work"))))
    }

    @Test
    func aRunningResponseNeedsForce() {
        #expect(makePreflight(target: work, current: defaultAccount, remote: false, running: true).refusal
            == .agentRunning)
        #expect(makePreflight(target: work, current: defaultAccount, remote: false, running: true, force: true)
            .refusal == nil)
    }

    @Test
    func anIdleSwitchOrOneWithNoCachedClaudeGoesAhead() {
        #expect(makePreflight(target: work, current: defaultAccount, remote: false, running: false).refusal == nil)
        // No cached Claude session: the shared switch decides (not_claude, no_claude_session, ...).
        #expect(makePreflight(target: work, current: nil, remote: false, running: false).refusal == nil)
    }

    private func makePreflight(
        target: ClaudeAccount?,
        current: ClaudeAccount?,
        remote: Bool,
        running: Bool,
        force: Bool = false
    ) -> ClaudeAccountSwitchSocketPreflight {
        ClaudeAccountSwitchSocketPreflight(
            accountName: "work",
            target: target,
            current: current,
            runsOnAnotherMachine: remote,
            responseRunning: running,
            force: force,
            homeDirectory: home
        )
    }
}
