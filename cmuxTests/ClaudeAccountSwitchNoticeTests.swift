import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Every switch result the menu and the palette can get maps to one notice. A resumed switch
/// needs none; a switch whose resume was never typed must hand the user the session to resume.
struct ClaudeAccountSwitchNoticeTests {
    private let home = "/Users/cmux-test"
    private let sessionID = "a22293b7-bcef-4707-8439-2f538c8517a4"

    @Test
    func resumedSwitchNeedsNoNotice() throws {
        let result = ClaudeAccountSwitchResult.switched(try makePlan(to: "work"), .copied)

        #expect(ClaudeAccountSwitchNotice(result: result, requestedAccountName: "work") == nil)
    }

    @Test
    func switchWithoutResumeTellsTheUserToResumeTheSessionByHand() throws {
        let result = ClaudeAccountSwitchResult.switchedWithoutResume(try makePlan(to: "work"), .copied)

        let notice = try #require(ClaudeAccountSwitchNotice(result: result, requestedAccountName: "work"))

        #expect(notice == .resumeManually(accountName: "work", sessionID: sessionID))
        #expect(!notice.reportsFailure)
        #expect(notice.title.contains("work"))
        #expect(notice.message.contains("--resume \(sessionID)"))
    }

    @Test
    func everyFailureMapsToItsOwnMessage() {
        let results: [ClaudeAccountSwitchResult] = [
            .refused(.noClaudeSession),
            .refused(.missingWorkingDirectory),
            .refused(.unknownAccount("ghost")),
            .refused(.sameAccount("work")),
            .notClaude,
            .remoteUnsupported,
            .alreadySwitching,
            .transcriptUnavailable,
            .respawnFailed,
        ]

        let notices = results.compactMap { ClaudeAccountSwitchNotice(result: $0, requestedAccountName: "work") }

        #expect(notices == [
            .noClaudeSession,
            .missingWorkingDirectory,
            .unknownAccount("ghost"),
            .alreadyOnAccount("work"),
            .notClaude,
            .remoteUnsupported,
            .alreadySwitching,
            .transcriptUnavailable(accountName: "work"),
            .respawnFailed,
        ])
        #expect(notices.allSatisfy { $0.reportsFailure })
        #expect(notices.allSatisfy { !$0.title.isEmpty && !$0.message.isEmpty })
        #expect(Set(notices.map(\.message)).count == results.count)
        #expect(ClaudeAccountSwitchNotice.unknownAccount("ghost").message.contains("ghost"))
        #expect(ClaudeAccountSwitchNotice.alreadyOnAccount("work").message.contains("work"))
        #expect(ClaudeAccountSwitchNotice.transcriptUnavailable(accountName: "work").message.contains("work"))
    }

    private func makePlan(to target: String) throws -> ClaudeAccountSwitchPlan {
        let registry = ClaudeAccountRegistry(
            declarations: [ClaudeAccountDeclaration(name: "work", configDir: "~/.claude-work")],
            homeDirectory: home
        )
        return try ClaudeAccountSwitchPlanner.plan(
            sessionID: sessionID,
            workingDirectory: "\(home)/project",
            launchEnvironment: nil,
            targetName: target,
            registry: registry,
            homeDirectory: home
        ).get()
    }
}
