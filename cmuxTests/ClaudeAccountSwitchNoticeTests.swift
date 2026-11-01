import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Every switch result the menu and the palette can get maps to one notice. A resumed switch
/// needs none. A switch whose resume was never typed hands the user the command cmux built,
/// which unsets the account keys the shell may re-export, never a bare `claude --resume`.
struct ClaudeAccountSwitchNoticeTests {
    private let home = "/Users/cmux-test"
    private let sessionID = "a22293b7-bcef-4707-8439-2f538c8517a4"
    private let project = "/Users/cmux-test/project"

    @Test
    func resumedSwitchNeedsNoNotice() throws {
        let result = ClaudeAccountSwitchResult.switched(try makePlan(to: "work"), .copied)

        #expect(ClaudeAccountSwitchNotice(result: result, requestedAccountName: "work") == nil)
    }

    @Test
    func switchWithoutResumeShowsTheBuiltCommandAndOffersToTypeIt() throws {
        let manualResume = try makeManualResume(paneWasReplaced: false)
        // Switching to the default account must not resume under a re-exported CLAUDE_CONFIG_DIR.
        #expect(manualResume.command.contains("env -u CLAUDE_CONFIG_DIR"))
        let result = ClaudeAccountSwitchResult.switchedWithoutResume(
            try makePlan(to: ClaudeAccountRegistry.defaultAccountName, from: "\(home)/.claude-work"),
            .copied,
            manualResume
        )

        let notice = try #require(ClaudeAccountSwitchNotice(
            result: result,
            requestedAccountName: ClaudeAccountRegistry.defaultAccountName
        ))

        #expect(notice == .resumeManually(
            accountName: ClaudeAccountRegistry.defaultAccountName,
            command: manualResume.command,
            paneClosed: false
        ))
        #expect(notice.message.contains(manualResume.command))
        #expect(notice.offersTypingResumeCommand)
        #expect(!notice.reportsFailure)
        #expect(notice.title.contains(ClaudeAccountRegistry.defaultAccountName))
    }

    @Test
    func switchWhosePaneWasReplacedShowsTheCommandWithoutTheTypeAction() throws {
        let manualResume = try makeManualResume(paneWasReplaced: true)
        let plan = try makePlan(to: ClaudeAccountRegistry.defaultAccountName, from: "\(home)/.claude-work")

        let notice = try #require(ClaudeAccountSwitchNotice(
            result: .switchedWithoutResume(plan, .copied, manualResume),
            requestedAccountName: ClaudeAccountRegistry.defaultAccountName
        ))
        let openPaneNotice = ClaudeAccountSwitchNotice.resumeManually(
            accountName: ClaudeAccountRegistry.defaultAccountName,
            command: manualResume.command,
            paneClosed: false
        )

        #expect(notice == .resumeManually(
            accountName: ClaudeAccountRegistry.defaultAccountName,
            command: manualResume.command,
            paneClosed: true
        ))
        #expect(notice.message.contains(manualResume.command))
        #expect(!notice.offersTypingResumeCommand)
        #expect(notice.message != openPaneNotice.message)
    }

    /// The old Claude outlived the exit wait, so cmux typed nothing. The notice names it and
    /// hands over the command, but never offers to type it: that could run the session twice.
    @Test
    func switchWhilePreviousClaudeStillRunsNeverOffersToTypeTheResume() throws {
        let built = try makeManualResume(paneWasReplaced: false)
        let manualResume = ClaudeAccountSwitchManualResume(
            command: built.command,
            typedInput: built.typedInput,
            reason: .previousClaudeStillRunning(processIDs: [48_213])
        )
        let plan = try makePlan(to: ClaudeAccountRegistry.defaultAccountName, from: "\(home)/.claude-work")

        let notice = try #require(ClaudeAccountSwitchNotice(
            result: .switchedWithoutResume(plan, .refreshed, manualResume),
            requestedAccountName: ClaudeAccountRegistry.defaultAccountName
        ))

        #expect(notice == .previousClaudeStillRunning(
            accountName: ClaudeAccountRegistry.defaultAccountName,
            command: built.command,
            processIDs: [48_213]
        ))
        #expect(!manualResume.paneWasReplaced)
        #expect(!notice.offersTypingResumeCommand)
        #expect(!notice.reportsFailure)
        #expect(notice.message.contains(built.command))
        #expect(notice.message.contains("48213"))
        #expect(notice.notificationMessage == notice.message)
        #expect(notice.title.contains(ClaudeAccountRegistry.defaultAccountName))
    }

    @Test
    func everyFailureMapsToItsOwnMessage() {
        let results: [ClaudeAccountSwitchResult] = [
            .refused(.noClaudeSession),
            .refused(.missingWorkingDirectory),
            .refused(.noConversationYet),
            .refused(.transcriptDiverged(newerAccount: "work")),
            .refused(.unknownAccount("ghost")),
            .refused(.sameAccount("work")),
            .notClaude,
            .remoteUnsupported,
            .agentNotOwnedByPane,
            .alreadySwitching,
            .transcriptUnavailable,
            .respawnFailed,
            .paneInUse,
        ]

        let notices = results.compactMap { ClaudeAccountSwitchNotice(result: $0, requestedAccountName: "work") }

        #expect(notices == [
            .noClaudeSession,
            .missingWorkingDirectory,
            .noConversationYet,
            .transcriptDiverged(newerAccount: "work"),
            .unknownAccount("ghost"),
            .alreadyOnAccount("work"),
            .notClaude,
            .remoteUnsupported,
            .agentNotOwnedByPane,
            .alreadySwitching,
            .transcriptUnavailable(accountName: "work"),
            .respawnFailed,
            .paneInUse,
        ])
        #expect(notices.allSatisfy { $0.reportsFailure && !$0.offersTypingResumeCommand })
        #expect(notices.allSatisfy { !$0.title.isEmpty && !$0.message.isEmpty })
        #expect(Set(notices.map(\.message)).count == results.count)
        #expect(ClaudeAccountSwitchNotice.unknownAccount("ghost").message.contains("ghost"))
        #expect(ClaudeAccountSwitchNotice.alreadyOnAccount("work").message.contains("work"))
        #expect(ClaudeAccountSwitchNotice.transcriptUnavailable(accountName: "work").message.contains("work"))
        #expect(ClaudeAccountSwitchNotice.transcriptDiverged(newerAccount: "qa").message.contains("qa"))
    }

    /// The resume a switch from `work` to the default account builds, as
    /// ``Workspace/switchClaudeAccount(panelId:toAccountNamed:trigger:)`` builds it.
    private func makeManualResume(paneWasReplaced: Bool) throws -> ClaudeAccountSwitchManualResume {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionID,
            workingDirectory: project,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "claude",
                arguments: ["claude", "--model", "sonnet"],
                workingDirectory: project,
                environment: ["CLAUDE_CONFIG_DIR": "\(home)/.claude-work"],
                capturedAt: 123,
                source: "environment"
            )
        )
        let resume = ClaudeAccountSwitchResumeInput(
            snapshot: snapshot,
            plan: try makePlan(to: ClaudeAccountRegistry.defaultAccountName, from: "\(home)/.claude-work")
        )
        return ClaudeAccountSwitchManualResume(
            command: try #require(resume.posixCommand()),
            typedInput: try #require(resume.typedInput(dialect: .posix)),
            paneWasReplaced: paneWasReplaced
        )
    }

    private func makePlan(to target: String, from sourceConfigDirectory: String? = nil) throws -> ClaudeAccountSwitchPlan {
        let registry = ClaudeAccountRegistry(
            declarations: [ClaudeAccountDeclaration(name: "work", configDir: "~/.claude-work")],
            homeDirectory: home
        )
        return try ClaudeAccountSwitchPlanner.plan(
            sessionID: sessionID,
            workingDirectory: project,
            launchEnvironment: sourceConfigDirectory.map { ["CLAUDE_CONFIG_DIR": $0] },
            targetName: target,
            registry: registry,
            homeDirectory: home
        ).get()
    }
}
